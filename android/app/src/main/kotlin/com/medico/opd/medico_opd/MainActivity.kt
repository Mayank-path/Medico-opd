package com.medico.opd.medico_opd

import android.content.Intent
import android.os.Build
import androidx.annotation.NonNull
import com.medico.opd.medico_opd.recording.RecordingForegroundService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.medico.opd/recording_resilience"
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundService" -> {
                        val sessionId = call.argument<String>("recordingSessionId")
                        val consultationId = call.argument<String>("consultationId")

                        val intent = Intent(context, RecordingForegroundService::class.java).apply {
                            action = RecordingForegroundService.ACTION_START
                            putExtra(RecordingForegroundService.EXTRA_SESSION_ID, sessionId)
                            putExtra(RecordingForegroundService.EXTRA_CONSULTATION_ID, consultationId)
                        }

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.startForegroundService(intent)
                        } else {
                            context.startService(intent)
                        }
                        result.success(true)
                    }

                    "updateForegroundServiceState" -> {
                        val state = call.argument<String>("state")
                        val intent = Intent(context, RecordingForegroundService::class.java).apply {
                            action = RecordingForegroundService.ACTION_UPDATE_STATE
                            putExtra(RecordingForegroundService.EXTRA_STATE, state)
                        }
                        context.startService(intent)
                        result.success(true)
                    }

                    "stopForegroundService" -> {
                        val intent = Intent(context, RecordingForegroundService::class.java).apply {
                            action = RecordingForegroundService.ACTION_STOP
                        }
                        context.startService(intent)
                        result.success(true)
                    }

                    "isForegroundServiceRunning" -> {
                        result.success(RecordingForegroundService.isServiceRunning)
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }

        // Bridge native audio focus interruptions to Flutter layer
        RecordingForegroundService.interruptionListener = { reason, sessionId ->
            runOnUiThread {
                methodChannel?.invokeMethod(
                    "onAudioInterruption",
                    mapOf(
                        "reason" to reason,
                        "sessionId" to sessionId
                    )
                )
            }
        }
    }

    override fun onDestroy() {
        RecordingForegroundService.interruptionListener = null
        super.onDestroy()
    }
}
