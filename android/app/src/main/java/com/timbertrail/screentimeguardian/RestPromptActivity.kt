package com.timbertrail.screentimeguardian

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

class RestPromptActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private var canClose = false
    private var immediate = false
    private var canCloseAtMillis = 0L
    private var countdownView: TextView? = null
    private var closeButton: Button? = null
    private var language = "zh"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )

        val title = intent.getStringExtra(GuardianService.EXTRA_PROMPT_TITLE) ?: "Screen Time Guardian"
        val message = intent.getStringExtra(GuardianService.EXTRA_PROMPT_MESSAGE) ?: ""
        val countdownSeconds = intent.getIntExtra(GuardianService.EXTRA_PROMPT_COUNTDOWN, 0)
        immediate = intent.getBooleanExtra(GuardianService.EXTRA_PROMPT_IMMEDIATE, false)
        language = SessionStore(this).language
        canCloseAtMillis = intent.getLongExtra(
            GuardianService.EXTRA_PROMPT_CAN_CLOSE_AT,
            if (immediate) System.currentTimeMillis() else System.currentTimeMillis() + countdownSeconds.coerceAtLeast(0) * 1000L
        )

        val countdown = TextView(this).apply {
            textSize = 18f
            gravity = Gravity.CENTER
            setPadding(0, 16, 0, 16)
        }
        countdownView = countdown
        val close = Button(this).apply {
            text = L10n.text("关闭", "Close", language)
            isEnabled = immediate || System.currentTimeMillis() >= canCloseAtMillis
            setOnClickListener { closePrompt() }
        }
        closeButton = close
        canClose = close.isEnabled

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
            addView(TextView(this@RestPromptActivity).apply {
                text = title
                textSize = 26f
                gravity = Gravity.CENTER
            })
            addView(TextView(this@RestPromptActivity).apply {
                text = message
                textSize = 18f
                gravity = Gravity.CENTER
                setPadding(0, 20, 0, 12)
            })
            addView(countdown)
            addView(close)
        }
        setContentView(root)

        runCountdown()
    }

    override fun onResume() {
        super.onResume()
        updateCountdown()
    }

    override fun onBackPressed() {
        if (canClose) closePrompt()
    }

    private fun runCountdown() {
        val runnable = object : Runnable {
            override fun run() {
                updateCountdown()
                if (canClose) {
                    return
                }
                handler.postDelayed(this, 1000L)
            }
        }
        handler.post(runnable)
    }

    private fun updateCountdown() {
        val countdown = countdownView ?: return
        val close = closeButton ?: return
        if (immediate) {
            canClose = true
            close.isEnabled = true
            countdown.text = L10n.text("会议模式：可以立即关闭", "Meeting mode: can close immediately", language)
            return
        }

        val remaining = (((canCloseAtMillis - System.currentTimeMillis()) + 999L) / 1000L).toInt()
        if (remaining <= 0) {
            canClose = true
            close.isEnabled = true
            countdown.text = L10n.text("可以关闭", "Ready to close", language)
        } else {
            canClose = false
            close.isEnabled = false
            countdown.text = if (language == "en") "${remaining} seconds remaining" else "剩余 ${remaining} 秒"
        }
    }

    private fun closePrompt() {
        GuardianService.sendAction(this, GuardianService.ACTION_PROMPT_CLOSED)
        finish()
    }
}
