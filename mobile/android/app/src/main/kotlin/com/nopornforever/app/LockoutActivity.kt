package com.nopornforever.app

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.system.exitProcess

/**
 * Full-screen hard stop shown when native screen guardian trips.
 * Starts from the capture foreground service so it works while Chrome is open.
 */
class LockoutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_FULLSCREEN,
        )

        val reason = intent.getStringExtra(EXTRA_REASON) ?: "Blocked content"
        val detail = intent.getStringExtra(EXTRA_DETAIL) ?: ""
        val label = intent.getStringExtra(EXTRA_LABEL) ?: ""
        val score = intent.getDoubleExtra(EXTRA_SCORE, 0.0)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0E4F8A"))
            setPadding(48, 96, 48, 48)
            gravity = Gravity.CENTER
        }
        fun tv(text: String, size: Float, color: Int, bold: Boolean = false) =
            TextView(this).apply {
                this.text = text
                textSize = size
                setTextColor(color)
                gravity = Gravity.CENTER
                if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(0, 12, 0, 12)
            }

        root.addView(tv("NoPornForever", 28f, Color.WHITE, true))
        root.addView(tv("Blocked", 22f, Color.parseColor("#FFCDD2"), true))
        root.addView(tv(reason, 16f, Color.WHITE))
        if (detail.isNotBlank()) root.addView(tv(detail, 14f, Color.parseColor("#B8E0FB")))
        if (label.isNotBlank()) {
            root.addView(
                tv(
                    "$label · ${(score * 100).toInt()}%",
                    13f,
                    Color.parseColor("#FFE0E0"),
                ),
            )
        }
        root.addView(tv("Closing…", 14f, Color.parseColor("#90CAF9")))
        setContentView(root)

        // Force-close our process shortly so the guard session ends hard.
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                finishAffinity()
            } catch (_: Exception) {
            }
            exitProcess(0)
        }, 1800)
    }

    companion object {
        const val EXTRA_REASON = "reason"
        const val EXTRA_DETAIL = "detail"
        const val EXTRA_LABEL = "label"
        const val EXTRA_SCORE = "score"
    }
}
