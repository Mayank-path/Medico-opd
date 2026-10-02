import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import '../../patient/models/patient_model.dart';
import '../../consultation/models/consultation_model.dart';
import '../../ai_draft/screens/ai_draft_review_screen.dart';
import '../models/recording_lifecycle_state.dart';
import '../models/recording_model.dart';
import '../models/recording_session_model.dart';
import '../services/recording_service.dart';
import '../services/recording_state_manager.dart';

class RecordingScreen extends StatefulWidget {
  final PatientModel patient;
  final ConsultationModel consultation;
  final String doctorId;
  final String clientRecordingId;
  final RecordingService? recordingService;
  final RecordingStateManager? stateManager;

  const RecordingScreen({
    super.key,
    required this.patient,
    required this.consultation,
    required this.doctorId,
    required this.clientRecordingId,
    this.recordingService,
    this.stateManager,
  });

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> with WidgetsBindingObserver {
  late final RecordingService _recordingService;
  late final RecordingStateManager _stateManager;
  StreamSubscription<RecordingSessionModel>? _sessionSubscription;

  RecordingScreenState _currentState = RecordingScreenState.idle;
  int _recordingSeconds = 0;
  Timer? _timer;
  String? _errorMessage;
  String? _localAudioPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stateManager = widget.stateManager ??
        widget.recordingService?.stateManager ??
        RecordingStateManager();
    _recordingService = widget.recordingService ??
        RecordingService(stateManager: _stateManager);

    _sessionSubscription = _stateManager.sessionStream
        .where((s) => s.recordingSessionId == widget.clientRecordingId)
        .listen(_handleSessionUpdate);

    _reconcileState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reconcileState();
    }
  }

  void _handleSessionUpdate(RecordingSessionModel session) {
    if (!mounted) return;
    setState(() {
      _currentState = _mapLifecycleToScreenState(session.state);
      if (session.localFilePath != null) {
        _localAudioPath = session.localFilePath;
      }
      if (session.lastErrorMessage != null) {
        _errorMessage = session.lastErrorMessage;
      }
      if (session.durationSeconds > 0 && _recordingSeconds == 0) {
        _recordingSeconds = session.durationSeconds;
      }
    });
  }

  RecordingScreenState _mapLifecycleToScreenState(RecordingLifecycleState state) {
    switch (state) {
      case RecordingLifecycleState.idle:
      case RecordingLifecycleState.preparing:
        return RecordingScreenState.idle;
      case RecordingLifecycleState.recording:
      case RecordingLifecycleState.paused:
        return RecordingScreenState.recording;
      case RecordingLifecycleState.stopping:
      case RecordingLifecycleState.recorded:
      case RecordingLifecycleState.uploadPending:
      case RecordingLifecycleState.uploading:
        return RecordingScreenState.uploading;
      case RecordingLifecycleState.uploaded:
      case RecordingLifecycleState.processing:
        return RecordingScreenState.processing;
      case RecordingLifecycleState.completed:
        return RecordingScreenState.transcribed;
      case RecordingLifecycleState.failed:
      case RecordingLifecycleState.recoveryRequired:
        if (_currentState == RecordingScreenState.processing) {
          return RecordingScreenState.processingFailed;
        }
        return RecordingScreenState.uploadFailed;
    }
  }

  Future<void> _reconcileState() async {
    // 1. Inspect local canonical state for fast resume across widget rebuilds
    try {
      final localSession = await _stateManager.getSession(widget.clientRecordingId);
      if (localSession != null && mounted) {
        int duration = localSession.durationSeconds;
        if (localSession.state == RecordingLifecycleState.recording && localSession.startedAt != null) {
          final elapsed = DateTime.now().difference(localSession.startedAt!).inSeconds;
          if (elapsed > duration) {
            duration = elapsed;
          }
        }

        setState(() {
          _currentState = _mapLifecycleToScreenState(localSession.state);
          _localAudioPath = localSession.localFilePath;
          _recordingSeconds = duration;
          if (localSession.lastErrorMessage != null) {
            _errorMessage = localSession.lastErrorMessage;
          }
        });
        if (localSession.state == RecordingLifecycleState.recording) {
          _startTimer();
          return;
        } else {
          _timer?.cancel();
        }
      }
    } catch (_) {}

    // 2. Reconcile with remote server state if available
    await _reconcileServerState();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _recordingSeconds++;
        });
      }
    });
  }

  Future<void> _reconcileServerState() async {
    try {
      final rec = await _recordingService.getRecording(widget.clientRecordingId);
      if (rec != null && mounted) {
        setState(() {
          if (rec.processingStatus == RecordingProcessingStatus.transcribed) {
            _currentState = RecordingScreenState.transcribed;
          } else if (rec.processingStatus == RecordingProcessingStatus.transcribing ||
              rec.processingStatus == RecordingProcessingStatus.structuring ||
              rec.processingStatus == RecordingProcessingStatus.queued) {
            _currentState = RecordingScreenState.processing;
          } else if (rec.processingStatus == RecordingProcessingStatus.failed) {
            _currentState = RecordingScreenState.processingFailed;
            _errorMessage = rec.lastErrorMessage ?? 'Processing failed';
          }
        });
      }
    } catch (_) {
      // Offline / network failure on resume: remain in initial idle state
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionSubscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _startRecording() async {
    setState(() {
      _currentState = RecordingScreenState.recording;
      _recordingSeconds = 0;
      _errorMessage = null;
    });

    try {
      _localAudioPath = await _recordingService.startRecording(
        consultationId: widget.consultation.id,
        patientId: widget.patient.id,
        clientRecordingId: widget.clientRecordingId,
      );

      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {
            _recordingSeconds++;
          });
        }
      });
    } catch (e) {
      debugPrint('[RecordingScreen] Failed to start microphone recording: $e');
      if (mounted) {
        setState(() {
          _currentState = RecordingScreenState.uploadFailed;
          _errorMessage = 'Microphone recording failed to start: $e';
        });
      }
    }
  }

  Future<void> _stopAndUpload() async {
    _timer?.cancel();

    setState(() {
      _currentState = RecordingScreenState.uploading;
      _errorMessage = null;
    });

    try {
      try {
        final stopped = await _recordingService.stopRecording();
        if (stopped != null && stopped.isNotEmpty) {
          _localAudioPath = stopped;
        }
      } catch (e) {
        debugPrint('[RecordingScreen] Notice: Audio stop returned error: $e');
      }

      if (_localAudioPath == null || _localAudioPath!.trim().isEmpty) {
        throw StateError('Audio recording path is missing or recording was not started.');
      }

      final audioFile = File(_localAudioPath!);
      if (!audioFile.existsSync()) {
        throw StateError('Recorded audio file not found on device: $_localAudioPath');
      }

      final fileLength = audioFile.lengthSync();
      if (fileLength == 0) {
        throw StateError('Recorded audio file is empty (0 bytes).');
      }

      // Secure upload pipeline: Audio byte verification -> Storage upload -> DB insert
      await _recordingService.uploadAndRegisterRecording(
        localAudioPath: _localAudioPath!,
        clientRecordingId: widget.clientRecordingId,
        clinicId: widget.consultation.clinicId,
        consultationId: widget.consultation.id,
        patientId: widget.patient.id,
        doctorId: widget.doctorId,
        durationSeconds: _recordingSeconds,
      );

      // Transition state to processing
      if (mounted) {
        setState(() {
          _currentState = RecordingScreenState.processing;
        });
      }

      // Trigger Edge Function pipeline
      await _recordingService.triggerEdgeFunctionProcessing(
        recordingId: widget.clientRecordingId,
        consultationId: widget.consultation.id,
      );

      // Pipeline success -> transcribed
      if (mounted) {
        setState(() {
          _currentState = RecordingScreenState.transcribed;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_currentState == RecordingScreenState.uploading) {
            _currentState = RecordingScreenState.uploadFailed;
            _errorMessage = 'Upload failed: $e';
          } else {
            _currentState = RecordingScreenState.processingFailed;
            _errorMessage = 'Processing failed: $e';
          }
        });
      }
    }
  }

  Future<void> _retryUploadOrProcess() async {
    if (_currentState == RecordingScreenState.processingFailed) {
      // Audio is already securely uploaded and recording row is registered with widget.clientRecordingId.
      // Re-trigger Edge Function processing preserving the exact same recording identity.
      setState(() {
        _currentState = RecordingScreenState.processing;
        _errorMessage = null;
      });

      try {
        await _recordingService.triggerEdgeFunctionProcessing(
          recordingId: widget.clientRecordingId,
          consultationId: widget.consultation.id,
        );

        if (mounted) {
          setState(() {
            _currentState = RecordingScreenState.transcribed;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _currentState = RecordingScreenState.processingFailed;
            _errorMessage = 'Processing failed: $e';
          });
        }
      }
    } else {
      // Upload failed or interrupted prior to remote storage registration
      await _stopAndUpload();
    }
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    const brandTeal = Color(0xFF007A78);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Consultation Audio Recording'),
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Patient details card
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      widget.patient.fullName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF003B3A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'OPD: ${widget.patient.opdNumber ?? "N/A"} • Consultation: ${widget.consultation.id.substring(0, 8)}',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Center area rendering distinct testable states
            Expanded(
              child: Center(
                child: _buildStateView(brandTeal),
              ),
            ),

            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade900, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Action buttons corresponding to state
            _buildActionButtons(brandTeal),
          ],
        ),
      ),
    );
  }

  Widget _buildStateView(Color brandTeal) {
    switch (_currentState) {
      case RecordingScreenState.idle:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none, size: 72, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text(
              'Ready to Record Consultation',
              key: Key('state_idle_label'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Patient consent has been verified and registered.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ],
        );

      case RecordingScreenState.recording:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mic, size: 72, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              _formatDuration(_recordingSeconds),
              key: const Key('state_recording_timer'),
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: Colors.redAccent,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Recording Consultation Audio...',
              key: Key('state_recording_label'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        );

      case RecordingScreenState.uploading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            const Text(
              'Uploading Consultation Audio...',
              key: Key('state_uploading_label'),
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Idempotency Key: ${widget.clientRecordingId.substring(0, 8)}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        );

      case RecordingScreenState.uploadFailed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 64, color: Colors.red.shade700),
            const SizedBox(height: 16),
            Text(
              'Audio Upload Failed',
              key: const Key('state_upload_failed_label'),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.red.shade800,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Audio is preserved locally. Tap retry to re-upload idempotently.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ],
        );

      case RecordingScreenState.processing:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.teal),
            const SizedBox(height: 20),
            const Text(
              'Transcribing & Generating Draft...',
              key: Key('state_processing_label'),
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'STT & AI pipeline active via Supabase Edge Functions',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        );

      case RecordingScreenState.processingFailed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.orange.shade800),
            const SizedBox(height: 16),
            Text(
              'AI Pipeline Processing Failed',
              key: const Key('state_processing_failed_label'),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.orange.shade900,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Audio was saved. Tap retry to run transcription again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ],
        );

      case RecordingScreenState.transcribed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 72, color: Colors.green),
            const SizedBox(height: 16),
            const Text(
              'Transcription Complete',
              key: Key('state_transcribed_label'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'AI Clinical Draft ready for doctor review and finalization.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ],
        );
    }
  }

  Widget _buildActionButtons(Color brandTeal) {
    switch (_currentState) {
      case RecordingScreenState.idle:
        return ElevatedButton.icon(
          key: const Key('start_recording_button'),
          onPressed: _startRecording,
          icon: const Icon(Icons.fiber_manual_record),
          label: const Text('Start Recording'),
          style: ElevatedButton.styleFrom(
            backgroundColor: brandTeal,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        );

      case RecordingScreenState.recording:
        return ElevatedButton.icon(
          key: const Key('stop_recording_button'),
          onPressed: _stopAndUpload,
          icon: const Icon(Icons.stop),
          label: const Text('Stop & Upload Audio'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        );

      case RecordingScreenState.uploading:
      case RecordingScreenState.processing:
        return const SizedBox.shrink();

      case RecordingScreenState.uploadFailed:
      case RecordingScreenState.processingFailed:
        return ElevatedButton.icon(
          key: const Key('retry_button'),
          onPressed: _retryUploadOrProcess,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
          style: ElevatedButton.styleFrom(
            backgroundColor: brandTeal,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        );

      case RecordingScreenState.transcribed:
        return ElevatedButton.icon(
          key: const Key('done_button'),
          onPressed: () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => AiDraftReviewScreen(
                  patient: widget.patient,
                  consultation: widget.consultation,
                  doctorId: widget.doctorId,
                ),
              ),
            );
          },
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Proceed to Clinical Draft'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        );
    }
  }
}
