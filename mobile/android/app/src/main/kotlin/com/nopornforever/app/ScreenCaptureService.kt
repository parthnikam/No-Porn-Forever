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
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Periodic screen JPEGs via MediaProjection → base64 to Flutter EventChannel.
 * Same idea as “scan what the user is looking at” for the image classifier.
 */
class ScreenCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private val running = AtomicBoolean(false)

    private var intervalMs = 4000L
    private var quality = 55
    private var maxWidth = 720
    private var captureWidth = 720
    private var captureHeight = 1280
    private var density = 320

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCapture()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                intervalMs = intent.getLongExtra(EXTRA_INTERVAL, 4000L)
                quality = intent.getIntExtra(EXTRA_QUALITY, 55)
                maxWidth = intent.getIntExtra(EXTRA_MAX_WIDTH, 720)
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_DATA)
                if (data == null) {
                    Log.e(TAG, "missing projection data")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForeground(NOTIF_ID, buildNotification())
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
        handlerThread = HandlerThread("NoPornForever-screen").also { it.start() }
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
        Log.i(TAG, "screen capture started ${captureWidth}x$captureHeight every ${intervalMs}ms")
    }

    private fun scheduleTick() {
        handler?.postDelayed({
            if (!running.get()) return@postDelayed
            grabFrame()
            scheduleTick()
        }, intervalMs)
    }

    private fun grabFrame() {
        val reader = imageReader ?: return
        var image = reader.acquireLatestImage() ?: return
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
            val b64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
            FrameBus.emit(b64)
        } catch (e: Exception) {
            Log.w(TAG, "grabFrame failed", e)
        } finally {
            image.close()
        }
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
        // ImageReader likes even dimensions
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

    private fun buildNotification(): Notification {
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
            .setContentText("Scanning screen for NSFW content")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Screen Guardian", NotificationManager.IMPORTANCE_LOW),
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
        private const val CHANNEL_ID = "NoPornForever_screen"
        private const val NOTIF_ID = 43

        fun start(
            context: Context,
            resultCode: Int,
            data: Intent,
            intervalMs: Long,
            quality: Int,
            maxWidth: Int,
        ) {
            val i = Intent(context, ScreenCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_DATA, data)
                putExtra(EXTRA_INTERVAL, intervalMs)
                putExtra(EXTRA_QUALITY, quality)
                putExtra(EXTRA_MAX_WIDTH, maxWidth)
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

object FrameBus {
    @Volatile
    var listener: ((String) -> Unit)? = null

    fun emit(b64: String) {
        listener?.invoke(b64)
    }
}
