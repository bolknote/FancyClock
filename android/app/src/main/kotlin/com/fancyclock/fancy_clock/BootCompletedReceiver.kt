package com.fancyclock.fancy_clock

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Launches the clock UI after the system finishes booting.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        try {
            context.startActivity(launch)
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not start from boot (background launch restriction)", e)
        }
    }

    private companion object {
        private const val TAG = "BootCompletedReceiver"
    }
}
