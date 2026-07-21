package com.nopornforever.app

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Minimal DNS encode/decode for A/AAAA queries on the VPN path.
 * Blocked domains → sinkhole A or NXDOMAIN; allowed → forward upstream.
 */
object DnsPacket {
    data class Query(
        val id: Int,
        val name: String,
        val qtype: Int,
        val qclass: Int,
        val raw: ByteArray,
    )

    fun parseQuery(udpPayload: ByteArray): Query? {
        if (udpPayload.size < 12) return null
        val buf = ByteBuffer.wrap(udpPayload).order(ByteOrder.BIG_ENDIAN)
        val id = buf.short.toInt() and 0xFFFF
        val flags = buf.short.toInt() and 0xFFFF
        val qd = buf.short.toInt() and 0xFFFF
        buf.short // AN
        buf.short // NS
        buf.short // AR
        if ((flags and 0x8000) != 0) return null // not a query
        if (qd < 1) return null

        val name = readName(udpPayload, buf) ?: return null
        if (buf.remaining() < 4) return null
        val qtype = buf.short.toInt() and 0xFFFF
        val qclass = buf.short.toInt() and 0xFFFF
        return Query(id, name, qtype, qclass, udpPayload)
    }

    fun buildNxDomain(query: Query): ByteArray {
        val q = extractQuestion(query.raw) ?: return nxMinimal(query)
        val out = ByteBuffer.allocate(12 + q.size).order(ByteOrder.BIG_ENDIAN)
        out.putShort(query.id.toShort())
        val rd = query.raw[2].toInt() and 0x01
        // QR | AA | RD | RA | RCODE=3
        val flags = 0x8000 or 0x0400 or (rd shl 8) or 0x0080 or 0x0003
        out.putShort(flags.toShort())
        out.putShort(1)
        out.putShort(0)
        out.putShort(0)
        out.putShort(0)
        out.put(q)
        return out.array().copyOf(out.position())
    }

    fun buildSinkholeA(query: Query): ByteArray {
        val q = extractQuestion(query.raw) ?: return buildNxDomain(query)
        val out = ByteBuffer.allocate(12 + q.size + 16).order(ByteOrder.BIG_ENDIAN)
        out.putShort(query.id.toShort())
        val rd = query.raw[2].toInt() and 0x01
        val flags = 0x8000 or 0x0400 or (rd shl 8) or 0x0080 // NOERROR
        out.putShort(flags.toShort())
        out.putShort(1)
        out.putShort(1)
        out.putShort(0)
        out.putShort(0)
        out.put(q)
        out.putShort(0xC00C.toShort()) // pointer to QNAME
        out.putShort(1) // A
        out.putShort(1) // IN
        out.putInt(60)
        out.putShort(4)
        out.putInt(0) // 0.0.0.0
        return out.array().copyOf(out.position())
    }

    private fun nxMinimal(query: Query): ByteArray {
        val out = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
        out.putShort(query.id.toShort())
        out.putShort(0x8183.toShort())
        out.putShort(0)
        out.putShort(0)
        out.putShort(0)
        out.putShort(0)
        return out.array()
    }

    private fun extractQuestion(raw: ByteArray): ByteArray? {
        if (raw.size < 12) return null
        val buf = ByteBuffer.wrap(raw).order(ByteOrder.BIG_ENDIAN)
        buf.position(12)
        if (readName(raw, buf) == null) return null
        if (buf.remaining() < 4) return null
        buf.position(buf.position() + 4)
        return raw.copyOfRange(12, buf.position())
    }

    /** Read DNS name at buf.position(); advances buf past the name. */
    private fun readName(packet: ByteArray, buf: ByteBuffer): String? {
        val labels = ArrayList<String>(8)
        var pos = buf.position()
        var endPos = -1
        var jumps = 0

        while (jumps < 16) {
            if (pos < 0 || pos >= packet.size) return null
            val len = packet[pos].toInt() and 0xFF
            when {
                len == 0 -> {
                    if (endPos < 0) endPos = pos + 1
                    break
                }
                (len and 0xC0) == 0xC0 -> {
                    if (pos + 1 >= packet.size) return null
                    if (endPos < 0) endPos = pos + 2
                    val ptr = ((len and 0x3F) shl 8) or (packet[pos + 1].toInt() and 0xFF)
                    pos = ptr
                    jumps++
                }
                else -> {
                    pos++
                    if (pos + len > packet.size) return null
                    labels.add(String(packet, pos, len, Charsets.US_ASCII))
                    pos += len
                }
            }
        }
        if (endPos < 0) return null
        buf.position(endPos)
        return labels.joinToString(".")
    }
}
