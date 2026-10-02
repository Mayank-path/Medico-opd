package com.medico.opd.medico_opd.recording

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.medico.opd.medico_opd.MainActivity

/**
 * Native Android Foreground Service for resilient background consultation recording.
 *
 * Enforces:
 * - FOREGROUND_SERVICE_TYPE_MICROPHONE (API 34+)
 * - Privacy-safe ongoing notification (NO patient names, UHIDs, or clinical data)
 * - Audio focus loss monitoring (phone calls, mic seizure)
 * - Safe foreground elevated priority preventing OS background execution kills
 */
class RecordingForegroundService : Service(), AudioManager.OnAudioFocusChangeListener {

    companion object {
        const val CHANNEL_ID = "medico_opd_recording_channel"
        const val CHANNEL_NAME = "Consultation Recording"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.medico.opd.action.START_RECORDING_SERVICE"
        const val ACTION_STOP = "com.medico.opd.action.STOP_RECORDING_SERVICE"
        const val ACTION_UPDATE_STATE = "com.medico.opd.action.UPDATE_RECORDING_STATE"

        const val EXTRA_SESSION_ID = "extra_session_id"
        const val EXTRA_CONSULTATION_ID = "extra_consultation_id"
        const val EXTRA_STATE = "extra_state"

        @Volatile
        var isServiceRunning: Boolean = false
            private set

        @Volatile
        var currentSessionId: String? = null
            private set

        var interruptionListener: ((reason: String, sessionId: String?) -> Unit)? = null
    }

    private lateinit var notificationManager: NotificationManager
    private lateinit var audioManager: AudioManager
    private var audioFocusRequest: AudioFocusRequest? = null

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action

        when (action) {
            ACTION_START -> {
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
                val consultationId = intent.getStringExtra(EXTRA_CONSULTATION_ID)
                currentSessionId = sessionId
                isServiceRunning = true

                requestRecordingAudioFocus()

                val notification = buildPrivacySafeNotification(isPaused = false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }

            ACTION_UPDATE_STATE -> {
                val state = intent.getStringExtra(EXTRA_STATE)
                val isPaused = state.equals("paused", ignoreCase = true)
                val updatedNotification = buildPrivacySafeNotification(isPaused = isPaused)
                notificationManager.notify(NOTIFICATION_ID, updatedNotification)
            }

            ACTION_STOP -> {
                abandonRecordingAudioFocus()
                stopForegroundService()
                return START_NOT_STICKY
            }

            else -> {
                // If restarted with null intent, ensure service terminates cleanly without false state
                if (intent == null) {
                    stopForegroundService()
                    return START_NOT_STICKY
                }
            }
        }

        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        abandonRecordingAudioFocus()
        isServiceRunning = false
        currentSessionId = null
        super.onDestroy()
    }

    private fun stopForegroundService() {
        isServiceRunning = false
        currentSessionId = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    /**
     * Builds a privacy-safe ongoing notification.
     * Contains ZERO patient identifiers, UHIDs, symptoms, or medical text.
     */
    private fun buildPrivacySafeNotification(isPaused: Boolean): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            pendingIntentFlags
        )

        val title = if (isPaused) {
            "Consultation Recording Paused"
        } else {
            "Consultation Recording in Progress"
        }

        val body = if (isPaused) {
            "Recording is paused. Tap to return to Medico-OPD."
        } else {
            "Recording consultation audio. Tap to return to Medico-OPD."
        }

        val iconRes = applicationInfo.icon.takeIf { it != 0 }
            ?: android.R.drawable.ic_btn_speak_now

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(iconRes)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows active consultation audio recording status"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun requestRecordingAudioFocus() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val playbackAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()

                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(playbackAttributes)
                    .setAcceptsDelayedFocusGain(false)
                    .setOnAudioFocusChangeListener(this)
                    .build()

                audioManager.requestAudioFocus(audioFocusRequest!!)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    this,
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN
                )
            }
        } catch (_: Exception) {
            // Audio focus request failure does not block service startup
        }
    }

    private fun abandonRecordingAudioFocus() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(this)
            }
        } catch (_: Exception) {
            // Safe teardown
        }
    }

    override fun onAudioFocusChange(focusChange: Int) {
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Permanent loss: Phone call answered or other app seized microphone
                interruptionListener?.invoke("AUDIOFOCUS_LOSS", currentSessionId)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Temporary loss: Phone ring, navigation alert
                interruptionListener?.invoke("AUDIOFOCUS_LOSS_TRANSIENT", currentSessionId)
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                // Audio focus regained
                interruptionListener?.invoke("AUDIOFOCUS_GAIN", currentSessionId)
            }
        }
    }
}
