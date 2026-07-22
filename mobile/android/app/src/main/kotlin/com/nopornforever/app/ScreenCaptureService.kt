package com.nopornforever.app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Base64
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Periodic screen capture via MediaProjection.
 *
 * Classifies frames **natively** against the PC Classifier API so detection
 * still works while Chrome (or any browser) is in the foreground — Flutter
 * alone is often paused in the background and never runs the trip logic.
 */
class ScreenCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private val running = AtomicBoolean(false)
    private val classifying = AtomicBoolean(false)
    private val tripped = AtomicBoolean(false)

    private var intervalMs = 2500L
    private var quality = 70
    private var maxWidth = 960
    private var captureWidth = 720
    private var captureHeight = 1280
    private var density = 320
    private var apiBaseUrl = "http://192.168.0.149:8765"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCapture()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                intervalMs = intent.getLongExtra(EXTRA_INTERVAL, 2500L)
                quality = intent.getIntExtra(EXTRA_QUALITY, 70)
                maxWidth = intent.getIntExtra(EXTRA_MAX_WIDTH, 960)
                apiBaseUrl = (intent.getStringExtra(EXTRA_API_BASE)
                    ?: apiBaseUrl).trim().trimEnd('/')
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_DATA)
                if (data == null) {
                    Log.e(TAG, "missing projection data")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForeground(NOTIF_ID, buildNotification("Scanning…"))
                startCapture(resultCode, data)
            }
        }
        return START_STICKY
    }

    private fun startCapture(resultCode: Int, data: Intent) {
        if (running.get()) return
        val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        projection = mpm.getMediaProjection(resultCode, data)
        if (projection == null) {
            Log.e(TAG, "getMediaProjection null")
            stopSelf()
            return
        }

        computeSize()
        handlerThread = HandlerThread("nopornforever-screen").also { it.start() }
        handler = Handler(handlerThread!!.looper)

        projection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopCapture()
                stopSelf()
            }
        }, handler)

        imageReader = ImageReader.newInstance(
            captureWidth,
            captureHeight,
            PixelFormat.RGBA_8888,
            2,
        )

        virtualDisplay = projection?.createVirtualDisplay(
            "NoPornForeverCapture",
            captureWidth,
            captureHeight,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface,
            null,
            handler,
        )

        running.set(true)
        scheduleTick()
        Log.i(
            TAG,
            "screen capture started ${captureWidth}x$captureHeight every ${intervalMs}ms api=$apiBaseUrl",
        )
        ScreenEventBus.emit(
            mapOf(
                "type" to "status",
                "status" to "scanning",
                "api" to apiBaseUrl,
            ),
        )
    }

    private fun scheduleTick() {
        handler?.postDelayed({
            if (!running.get() || tripped.get()) return@postDelayed
            grabFrame()
            scheduleTick()
        }, intervalMs)
    }

    private fun grabFrame() {
        if (classifying.get() || tripped.get()) return
        val reader = imageReader ?: return
        val image = reader.acquireLatestImage() ?: return
        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val rowPadding = rowStride - pixelStride * captureWidth
            val bitmap = Bitmap.createBitmap(
                captureWidth + rowPadding / pixelStride,
                captureHeight,
                Bitmap.Config.ARGB_8888,
            )
            bitmap.copyPixelsFromBuffer(buffer)
            val cropped = Bitmap.createBitmap(bitmap, 0, 0, captureWidth, captureHeight)
            if (cropped != bitmap) bitmap.recycle()

            val baos = ByteArrayOutputStream()
            cropped.compress(Bitmap.CompressFormat.JPEG, quality, baos)
            cropped.recycle()
            val jpeg = baos.toByteArray()
            val b64 = Base64.encodeToString(jpeg, Base64.NO_WRAP)

            // Still emit to Flutter when alive (UI stats).
            ScreenEventBus.emit(mapOf("type" to "frame", "b64" to b64, "bytes" to jpeg.size))

            // Classify on a worker so we don't block the capture handler.
            if (classifying.compareAndSet(false, true)) {
                thread(name = "screen-classify", isDaemon = true) {
                    try {
                        classifyAndMaybeTrip(b64)
                    } finally {
                        classifying.set(false)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "grabFrame failed", e)
        } finally {
            image.close()
        }
    }

    private fun classifyAndMaybeTrip(b64: String) {
        try {
            val result = postClassifyImage(b64)
            val label = result.optString("label", "")
            val score = result.optDouble("score", 0.0)
            val ok = result.optBoolean("ok", true)
            val error = result.optString("error", "")

            ScreenEventBus.emit(
                mapOf(
                    "type" to "classify",
                    "ok" to ok,
                    "label" to label,
                    "score" to score,
                    "error" to error,
                ),
            )

            updateNotification("Screen: $label ${(score * 100).toInt()}%")

            if (!ok) {
                Log.w(TAG, "classify soft-fail: $error")
                return
            }

            if (isImageNsfw(label, score)) {
                Log.w(TAG, "NSFW TRIP label=$label score=$score")
                trip(label, score)
            }
        } catch (e: Exception) {
            Log.w(TAG, "classify failed: ${e.message}")
            ScreenEventBus.emit(
                mapOf(
                    "type" to "classify",
                    "ok" to false,
                    "label" to "error",
                    "score" to 0.0,
                    "error" to (e.message ?: "error"),
                ),
            )
        }
    }

    private fun isImageNsfw(label: String, score: Double): Boolean {
        val l = label.lowercase().trim()
        // Screen path is stricter than browser extension — user is mid-browse.
        val bad = when (l) {
            "pornography", "hentai" -> score >= 0.35
            "enticing or sensual" -> score >= 0.55
            else -> false
        }
        return bad
    }

    private fun postClassifyImage(b64: String): JSONObject {
        val url = URL("$apiBaseUrl/classify/image")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 8000
            readTimeout = 45000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
        }
        val body = JSONObject().put("image_b64", b64).toString()
        OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(body) }
        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val text = stream?.bufferedReader()?.readText() ?: "{}"
        conn.disconnect()
        if (code !in 200..299) {
            throw IllegalStateException("HTTP $code: ${text.take(200)}")
        }
        return JSONObject(text)
    }

    private fun trip(label: String, score: Double) {
        if (!tripped.compareAndSet(false, true)) return
        running.set(false)

        ScreenEventBus.emit(
            mapOf(
                "type" to "trip",
                "reason" to "NSFW on screen",
                "detail" to "Image classifier: $label",
                "label" to label,
                "score" to score,
            ),
        )

        // Full-screen alarm notification (works when activity-from-background is restricted).
        val lockIntent = Intent(this, LockoutActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_NO_USER_ACTION,
            )
            putExtra(LockoutActivity.EXTRA_REASON, "NSFW on screen")
            putExtra(LockoutActivity.EXTRA_DETAIL, "Browser / screen content blocked")
            putExtra(LockoutActivity.EXTRA_LABEL, label)
            putExtra(LockoutActivity.EXTRA_SCORE, score)
        }
        val fullPi = PendingIntent.getActivity(
            this,
            99,
            lockIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel()
        val notif = NotificationCompat.Builder(this, CHANNEL_ALERT_ID)
            .setContentTitle("NoPornForever — blocked")
            .setContentText("Explicit content detected ($label)")
            .setSmallIcon(android.R.drawable.ic_delete)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setContentIntent(fullPi)
            .setFullScreenIntent(fullPi, true)
            .build()
        nm.notify(NOTIF_ALERT_ID, notif)

        // Best-effort direct start (allowed for some FGS types / OEMs).
        try {
            startActivity(lockIntent)
        } catch (e: Exception) {
            Log.w(TAG, "startActivity lockout failed (notif full-screen should cover): ${e.message}")
        }

        // Stop capturing shortly after.
        handler?.postDelayed({
            stopCapture()
            stopSelf()
        }, 500)
    }

    private fun computeSize() {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        density = metrics.densityDpi
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        if (w > maxWidth) {
            val scale = maxWidth.toFloat() / w
            captureWidth = maxWidth
            captureHeight = (h * scale).toInt().coerceAtLeast(1)
        } else {
            captureWidth = w
            captureHeight = h
        }
        if (captureWidth % 2 != 0) captureWidth--
        if (captureHeight % 2 != 0) captureHeight--
    }

    private fun stopCapture() {
        running.set(false)
        try {
            virtualDisplay?.release()
        } catch (_: Exception) {
        }
        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        virtualDisplay = null
        imageReader = null
        projection = null
        handlerThread?.quitSafely()
        handlerThread = null
        handler = null
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        ensureChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("NoPornForever screen guardian")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(pi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Screen Guardian", NotificationManager.IMPORTANCE_LOW),
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ALERT_ID,
                "Content blocked",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Full-screen alert when explicit content is detected"
                enableVibration(true)
            },
        )
    }

    companion object {
        private const val TAG = "ScreenCaptureService"
        const val ACTION_START = "com.nopornforever.app.SCREEN_START"
        const val ACTION_STOP = "com.nopornforever.app.SCREEN_STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        const val EXTRA_INTERVAL = "intervalMs"
        const val EXTRA_QUALITY = "quality"
        const val EXTRA_MAX_WIDTH = "maxWidth"
        const val EXTRA_API_BASE = "apiBaseUrl"
        private const val CHANNEL_ID = "nopornforever_screen"
        private const val CHANNEL_ALERT_ID = "nopornforever_screen_alert"
        private const val NOTIF_ID = 43
        private const val NOTIF_ALERT_ID = 44

        fun start(
            context: Context,
            resultCode: Int,
            data: Intent,
            intervalMs: Long,
            quality: Int,
            maxWidth: Int,
            apiBaseUrl: String,
        ) {
            val i = Intent(context, ScreenCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_DATA, data)
                putExtra(EXTRA_INTERVAL, intervalMs)
                putExtra(EXTRA_QUALITY, quality)
                putExtra(EXTRA_MAX_WIDTH, maxWidth)
                putExtra(EXTRA_API_BASE, apiBaseUrl)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, ScreenCaptureService::class.java).setAction(ACTION_STOP),
            )
        }
    }
}

object ScreenEventBus {
    @Volatile
    var listener: ((Map<String, Any?>) -> Unit)? = null

    fun emit(map: Map<String, Any?>) {
        listener?.invoke(map)
    }
}

/** @deprecated kept name for any old refs — use ScreenEventBus */
object FrameBus {
    fun emit(b64: String) {
        ScreenEventBus.emit(mapOf("type" to "frame", "b64" to b64))
    }
}
