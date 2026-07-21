package com.nopornforever.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

/**
 * Local VPN that only steers DNS into a TUN, filters against the NSFW list,
 * and forwards everything else normally (DNS-only route pattern).
 *
 * Same product idea as desktop filterd: own DNS → match list → NXDOMAIN / sinkhole.
 */
class FilterVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null
    private val running = AtomicBoolean(false)
    private var worker: Thread? = null

    private val queries = AtomicLong(0)
    private val blocked = AtomicLong(0)
    private val allowed = AtomicLong(0)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopFilter()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> startFilter()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopFilter()
        super.onDestroy()
    }

    private fun startFilter() {
        if (running.get()) return
        try {
            engine = loadEngine(this)
            startForeground(NOTIF_ID, buildNotification(0))
            val builder = Builder()
                .setSession("NoPornForever")
                .setMtu(1500)
                .addAddress(VPN_ADDR, 32)
                .addDnsServer(DNS_ADDR)
                // Only pull DNS-server traffic into the TUN — classic DNS-filter VPN.
                .addRoute(DNS_ADDR, 32)
                .setBlocking(true)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            tun = builder.establish()
            if (tun == null) {
                Log.e(TAG, "VPN establish() returned null")
                EventBus.emitStatus("error")
                stopSelf()
                return
            }
            running.set(true)
            EventBus.emitStatus("active")
            worker = thread(name = "filterd-tun", isDaemon = true) { tunLoop() }
            Log.i(TAG, "filter VPN started; blocklist=${engine?.block?.length()}")
        } catch (e: Exception) {
            Log.e(TAG, "startFilter failed", e)
            EventBus.emitStatus("error")
            stopFilter()
            stopSelf()
        }
    }

    private fun stopFilter() {
        running.set(false)
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        worker = null
        EventBus.emitStatus("idle")
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun tunLoop() {
        val pfd = tun ?: return
        val input = FileInputStream(pfd.fileDescriptor)
        val output = FileOutputStream(pfd.fileDescriptor)
        val packet = ByteArray(32767)

        while (running.get()) {
            val len = try {
                input.read(packet)
            } catch (_: Exception) {
                break
            }
            if (len <= 0) continue
            handleIpPacket(packet, len, output)
        }
    }

    private fun handleIpPacket(packet: ByteArray, len: Int, output: FileOutputStream) {
        if (len < 20) return
        val version = (packet[0].toInt() ushr 4) and 0xF
        if (version != 4) return // IPv4 only for demo path

        val ihl = (packet[0].toInt() and 0xF) * 4
        if (len < ihl + 8) return
        val protocol = packet[9].toInt() and 0xFF
        if (protocol != 17) return // UDP only (DNS)

        val srcPort = ((packet[ihl].toInt() and 0xFF) shl 8) or (packet[ihl + 1].toInt() and 0xFF)
        val dstPort = ((packet[ihl + 2].toInt() and 0xFF) shl 8) or (packet[ihl + 3].toInt() and 0xFF)
        if (dstPort != 53) return

        val udpHeader = ihl
        val udpLen = ((packet[udpHeader + 4].toInt() and 0xFF) shl 8) or
            (packet[udpHeader + 5].toInt() and 0xFF)
        val dnsOffset = ihl + 8
        val dnsLen = udpLen - 8
        if (dnsLen <= 0 || dnsOffset + dnsLen > len) return

        val dnsPayload = packet.copyOfRange(dnsOffset, dnsOffset + dnsLen)
        val query = DnsPacket.parseQuery(dnsPayload) ?: return
        queries.incrementAndGet()

        val eng = engine ?: return
        val decision = eng.check(query.name)
        val responseDns: ByteArray
        if (decision.blocked) {
            blocked.incrementAndGet()
            EventBus.emitBlocked(decision.domain)
            // Prefer sinkhole A for A queries so browsers fail fast; else NXDOMAIN.
            responseDns = if (query.qtype == 1) {
                DnsPacket.buildSinkholeA(query)
            } else {
                DnsPacket.buildNxDomain(query)
            }
            Log.i(TAG, "BLOCK ${decision.domain} rule=${decision.matchedRule}")
        } else {
            allowed.incrementAndGet()
            responseDns = forwardUpstream(dnsPayload) ?: DnsPacket.buildNxDomain(query)
        }

        val responseIp = buildUdpIpv4Response(
            request = packet,
            requestLen = len,
            ihl = ihl,
            srcPort = srcPort,
            dnsPayload = responseDns,
        ) ?: return

        try {
            output.write(responseIp)
        } catch (e: Exception) {
            Log.w(TAG, "write response failed", e)
        }

        emitStats()
        updateNotification()
    }

    private fun forwardUpstream(query: ByteArray): ByteArray? {
        return try {
            val socket = DatagramSocket()
            protect(socket) // don't route upstream through our own VPN
            socket.soTimeout = 2500
            val server = InetAddress.getByName(UPSTREAM)
            val req = DatagramPacket(query, query.size, server, 53)
            socket.send(req)
            val buf = ByteArray(4096)
            val resp = DatagramPacket(buf, buf.size)
            socket.receive(resp)
            socket.close()
            buf.copyOf(resp.length)
        } catch (e: Exception) {
            Log.w(TAG, "upstream DNS failed", e)
            null
        }
    }

    private fun buildUdpIpv4Response(
        request: ByteArray,
        requestLen: Int,
        ihl: Int,
        srcPort: Int,
        dnsPayload: ByteArray,
    ): ByteArray? {
        val totalLen = ihl + 8 + dnsPayload.size
        val out = ByteArray(totalLen)
        // Copy original IP header then swap addrs
        System.arraycopy(request, 0, out, 0, ihl)
        // Swap src/dst IP (bytes 12-15 and 16-19)
        for (i in 0 until 4) {
            val a = out[12 + i]
            out[12 + i] = out[16 + i]
            out[16 + i] = a
        }
        // total length
        out[2] = ((totalLen ushr 8) and 0xFF).toByte()
        out[3] = (totalLen and 0xFF).toByte()
        // TTL
        out[8] = 64
        // clear checksum then recompute
        out[10] = 0
        out[11] = 0
        val ipCk = ipChecksum(out, 0, ihl)
        out[10] = ((ipCk ushr 8) and 0xFF).toByte()
        out[11] = (ipCk and 0xFF).toByte()

        // UDP header
        val udpOff = ihl
        // src port 53, dst original srcPort
        out[udpOff] = 0
        out[udpOff + 1] = 53
        out[udpOff + 2] = ((srcPort ushr 8) and 0xFF).toByte()
        out[udpOff + 3] = (srcPort and 0xFF).toByte()
        val udpLen = 8 + dnsPayload.size
        out[udpOff + 4] = ((udpLen ushr 8) and 0xFF).toByte()
        out[udpOff + 5] = (udpLen and 0xFF).toByte()
        out[udpOff + 6] = 0
        out[udpOff + 7] = 0
        System.arraycopy(dnsPayload, 0, out, udpOff + 8, dnsPayload.size)

        // UDP checksum optional for IPv4 — leave 0
        return out
    }

    private fun ipChecksum(buf: ByteArray, offset: Int, length: Int): Int {
        var sum = 0
        var i = offset
        while (i < offset + length - 1) {
            sum += ((buf[i].toInt() and 0xFF) shl 8) or (buf[i + 1].toInt() and 0xFF)
            i += 2
        }
        if (length % 2 != 0) {
            sum += (buf[offset + length - 1].toInt() and 0xFF) shl 8
        }
        while (sum ushr 16 != 0) {
            sum = (sum and 0xFFFF) + (sum ushr 16)
        }
        return sum.inv() and 0xFFFF
    }

    private fun emitStats() {
        EventBus.emitStats(queries.get(), blocked.get(), allowed.get())
    }

    private fun updateNotification() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification(blocked.get()))
    }

    private fun buildNotification(blockedCount: Long): Notification {
        ensureChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = Intent(this, FilterVpnService::class.java).setAction(ACTION_STOP)
        val stopPi = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("NoPornForever active")
            .setContentText("DNS protected · $blockedCount blocked")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .addAction(0, "Stop", stopPi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val ch = NotificationChannel(
            CHANNEL_ID,
            "DNS Protection",
            NotificationManager.IMPORTANCE_LOW,
        )
        nm.createNotificationChannel(ch)
    }

    companion object {
        private const val TAG = "FilterVpnService"
        const val ACTION_STOP = "com.nopornforever.app.STOP"
        private const val CHANNEL_ID = "NoPornForever_filter"
        private const val NOTIF_ID = 42
        private const val VPN_ADDR = "10.83.0.2"
        private const val DNS_ADDR = "10.83.0.1"
        private const val UPSTREAM = "1.1.1.1"

        @Volatile
        var engine: DomainEngine? = null
            private set

        fun isRunning(): Boolean = /* best-effort */ engine != null

        fun loadEngine(context: Context): DomainEngine {
            val eng = DomainEngine()
            val nsfwPaths = listOf(
                "nsfw.txt", // android/app/src/main/assets
                "flutter_assets/assets/nsfw.txt",
                "assets/nsfw.txt",
            )
            var loaded = false
            for (path in nsfwPaths) {
                try {
                    context.assets.open(path).bufferedReader().use {
                        val n = eng.loadBlocklist(it.readText())
                        Log.i(TAG, "Loaded $n block domains from $path")
                        loaded = true
                    }
                    break
                } catch (_: Exception) {
                }
            }
            if (!loaded) Log.e(TAG, "Failed to load nsfw.txt from assets")

            for (path in listOf(
                "allowlist.txt",
                "flutter_assets/assets/allowlist.txt",
                "assets/allowlist.txt",
            )) {
                try {
                    context.assets.open(path).bufferedReader().use {
                        eng.loadAllowlist(it.readText())
                    }
                    break
                } catch (_: Exception) {
                }
            }
            engine = eng
            return eng
        }
    }
}

/** Simple event bus from VPN service → Flutter EventChannel. */
object EventBus {
    @Volatile
    var listener: ((Map<String, Any?>) -> Unit)? = null

    fun emitStatus(status: String) {
        listener?.invoke(mapOf("type" to "status", "status" to status))
    }

    fun emitStats(queries: Long, blocked: Long, allowed: Long) {
        listener?.invoke(
            mapOf(
                "type" to "stats",
                "queries" to queries,
                "blocked" to blocked,
                "allowed" to allowed,
            ),
        )
    }

    fun emitBlocked(domain: String) {
        listener?.invoke(mapOf("type" to "blocked", "domain" to domain))
    }
}
