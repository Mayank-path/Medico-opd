// Edge Function: process-consultation
// Orchestrates STT transcription, privacy data-minimization, and LLM clinical draft generation
// Invariants 11-15: Provider independence, DB consent verification, prompt injection defense
// Block 1F: Production-safe structured observability, metrics, correlation IDs & error taxonomy

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { STTProvider, LLMProvider } from '../_shared/providers/types.ts';
import { DeepgramSTTProvider } from '../_shared/providers/deepgram_provider.ts';
import { ClaudeLLMProvider } from '../_shared/providers/claude_provider.ts';
import { DataMinimizer } from '../_shared/privacy/data_minimizer.ts';
import { EdgeLogger, EdgeRedactor } from '../_shared/observability/logger.ts';

Deno.serve(async (req) => {
  const pipelineStart = performance.now();
  const requestId = req.headers.get('x-request-id') ?? `req_${Date.now()}_${crypto.randomUUID().substring(0, 8)}`;
  const correlationId = req.headers.get('x-correlation-id') ?? `corr_${Date.now()}_${crypto.randomUUID().substring(0, 8)}`;

  const responseHeaders = {
    'Content-Type': 'application/json',
    'X-Request-ID': requestId,
    'X-Correlation-ID': correlationId,
  };

  let logger = new EdgeLogger('process-consultation', {
    requestId,
    correlationId,
  });

  try {
    if (req.method !== 'POST') {
      logger.warning('METHOD_NOT_ALLOWED', 'http_check', 'METHOD_NOT_ALLOWED');
      return new Response(JSON.stringify({ error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' }), {
        status: 405,
        headers: responseHeaders,
      });
    }

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      logger.warning('MISSING_AUTH_TOKEN', 'auth_check', 'UNAUTHORIZED_ACCESS');
      return new Response(JSON.stringify({ error: 'Missing authorization bearer token', code: 'UNAUTHORIZED_ACCESS' }), {
        status: 401,
        headers: responseHeaders,
      });
    }

    const { recording_id, consultation_id } = await req.json();
    if (!recording_id || !consultation_id) {
      logger.warning('INVALID_ARGUMENTS', 'payload_check', 'INVALID_ARGUMENTS');
      return new Response(JSON.stringify({ error: 'recording_id and consultation_id are required', code: 'INVALID_ARGUMENTS' }), {
        status: 400,
        headers: responseHeaders,
      });
    }

    // Bind known IDs to logger context
    logger = new EdgeLogger('process-consultation', {
      requestId,
      correlationId,
      recordingId: recording_id,
      consultationId: consultation_id,
    });

    logger.info('PROCESSING_STARTED', 'pipeline_start');
    logger.metric('recordings_processing_total', 1, { stage: 'init' });

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Client authenticated with caller's JWT to enforce RLS and clinic scoping
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    });

    // Admin client for pipeline updates and audit logging
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false },
    });

    // 1. Verify caller doctor and clinic association
    const { data: doctor, error: docErr } = await userClient
      .from('doctors')
      .select('id, clinic_id')
      .single();

    if (docErr || !doctor) {
      logger.warning('DOCTOR_UNAUTHORIZED', 'doctor_lookup', 'UNAUTHORIZED_ACCESS');
      return new Response(JSON.stringify({ error: 'Caller doctor profile not found or unauthorized', code: 'UNAUTHORIZED_ACCESS' }), {
        status: 403,
        headers: responseHeaders,
      });
    }

    const clinicHash = await EdgeRedactor.hashTenantId(doctor.clinic_id);
    logger = new EdgeLogger('process-consultation', {
      requestId,
      correlationId,
      recordingId: recording_id,
      consultationId: consultation_id,
      clinicIdHash: clinicHash,
    });

    // 2. Fetch recording record
    const { data: recording, error: recErr } = await userClient
      .from('recordings')
      .select('*')
      .eq('id', recording_id)
      .single();

    if (recErr || !recording) {
      logger.warning('RECORDING_NOT_FOUND', 'recording_lookup', 'RECORDING_NOT_FOUND');
      return new Response(JSON.stringify({ error: 'Recording record not found or cross-clinic access denied', code: 'RECORDING_NOT_FOUND' }), {
        status: 404,
        headers: responseHeaders,
      });
    }

    // 3. STEP 7 Failure Handling: Immediate re-check of consent status BEFORE transcription begins
    const { data: consentRecord, error: consentErr } = await adminClient
      .from('consultation_consents')
      .select('consent_status, revoked_at')
      .eq('consultation_id', consultation_id)
      .single();

    if (consentErr || !consentRecord || consentRecord.consent_status !== 'granted' || consentRecord.revoked_at !== null) {
      logger.warning('CONSENT_REVOKED', 'consent_check', 'CONSENT_REVOKED');
      logger.metric('recordings_failed_total', 1, { error_code: 'CONSENT_REVOKED' });

      await adminClient
        .from('recordings')
        .update({ processing_status: 'failed' })
        .eq('id', recording_id);

      await adminClient.from('audit_logs').insert({
        event_type: 'PROCESSING_BLOCKED_CONSENT_REVOKED',
        clinic_id: doctor.clinic_id,
        actor_id: doctor.id,
        target_table: 'recordings',
        target_id: recording_id,
        metadata: {
          reason: 'Consent was revoked before or during pipeline execution. Pipeline aborted immediately.',
          consultation_id,
        },
      });

      return new Response(
        JSON.stringify({
          error: 'Processing aborted: Patient consent was revoked or is inactive.',
          code: 'CONSENT_REVOKED',
        }),
        { status: 403, headers: responseHeaders }
      );
    }

    // 3b. Idempotency Check & Atomic state claim: Transition recording from 'pending' or 'failed' to 'transcribing'
    const claimStart = performance.now();
    const { data: claimedRecording, error: claimErr } = await adminClient
      .from('recordings')
      .update({
        processing_status: 'transcribing',
        processing_started_at: new Date().toISOString(),
      })
      .eq('id', recording_id)
      .in('processing_status', ['pending', 'failed'])
      .select('id, processing_status, storage_path')
      .maybeSingle();

    const claimDurationMs = Math.round(performance.now() - claimStart);
    logger.metric('claim_latency_ms', claimDurationMs);

    if (claimErr) {
      logger.error('CLAIM_ERROR', 'atomic_claim', 'DATABASE_ERROR', undefined, claimDurationMs);
      throw new Error(`Failed to claim recording for processing: ${claimErr.message}`);
    }

    if (!claimedRecording) {
      // Could not claim recording. Inspect current state for safe idempotent exit.
      const { data: currentRec } = await adminClient
        .from('recordings')
        .select('processing_status')
        .eq('id', recording_id)
        .single();

      const currentStatus = currentRec?.processing_status;

      if (currentStatus === 'transcribing' || currentStatus === 'structuring') {
        logger.info('ALREADY_PROCESSING', 'atomic_claim', { current_status: currentStatus }, claimDurationMs);
        return new Response(
          JSON.stringify({
            status: 'processing',
            idempotent: true,
            code: 'RECORDING_ALREADY_PROCESSING',
            message: 'Recording is currently being processed by another request.',
            recording_id,
          }),
          { status: 409, headers: responseHeaders }
        );
      }

      if (currentStatus === 'transcribed') {
        const { data: existingDraft } = await adminClient
          .from('ai_drafts')
          .select('id, status')
          .eq('consultation_id', consultation_id)
          .in('status', ['ai_draft', 'doctor_reviewed', 'finalized'])
          .order('reviewed_at', { ascending: false })
          .maybeSingle();

        const { data: existingTranscript } = await adminClient
          .from('transcripts')
          .select('id')
          .eq('recording_id', recording_id)
          .maybeSingle();

        logger.info('ALREADY_COMPLETED', 'atomic_claim', { transcript_id: existingTranscript?.id }, claimDurationMs);
        return new Response(
          JSON.stringify({
            status: 'success',
            idempotent: true,
            recording_id,
            transcript_id: existingTranscript?.id ?? null,
            ai_draft_id: existingDraft?.id ?? null,
            ai_draft_status: existingDraft?.status ?? null,
          }),
          { status: 200, headers: responseHeaders }
        );
      }

      logger.warning('STATE_LOCKED', 'atomic_claim', 'CLAIM_FAILED', { current_status: currentStatus }, claimDurationMs);
      return new Response(
        JSON.stringify({
          status: 'ignored',
          idempotent: true,
          code: 'CLAIM_FAILED',
          message: `Recording cannot be claimed from current status: ${currentStatus}`,
          recording_id,
        }),
        { status: 409, headers: responseHeaders }
      );
    }

    // Helper: Execute with bounded retry and exponential backoff + metrics
    const executeWithRetry = async <T>(
      fn: () => Promise<T>,
      providerName: 'deepgram' | 'claude',
      stage: 'stt' | 'llm',
      maxRetries = 2
    ): Promise<T> => {
      let lastErr: any;
      for (let attempt = 0; attempt <= maxRetries; attempt++) {
        if (attempt > 0) {
          logger.metric('retry_attempt_total', 1, { provider: providerName, stage });
        }
        try {
          const res = await fn();
          if (attempt > 0) {
            logger.metric('retry_success_total', 1, { provider: providerName, stage });
          }
          return res;
        } catch (err: any) {
          lastErr = err;
          const msg = (err.message || '').toLowerCase();
          const isRateLimit = msg.includes('429') || msg.includes('rate limit');
          const isTransient = isRateLimit || msg.includes('500') || msg.includes('502') || msg.includes('503') || msg.includes('504') || msg.includes('timeout');

          if (isRateLimit) {
            logger.metric(`${providerName}_429_total`, 1);
          } else if (msg.includes('timeout')) {
            logger.metric(`${providerName}_timeout_total`, 1);
          } else {
            logger.metric(`${providerName}_5xx_total`, 1);
          }

          if (!isTransient || attempt === maxRetries) {
            if (attempt === maxRetries) {
              logger.metric('retry_terminal_failure_total', 1, { provider: providerName, stage });
            }
            throw err;
          }

          const baseDelay = Math.pow(2, attempt) * 200;
          const jitter = Math.floor(Math.random() * 100);
          await new Promise((resolve) => setTimeout(resolve, baseDelay + jitter));
        }
      }
      throw lastErr;
    };

    // 5. STT Stage: Reuse transcript if already exists from prior interrupted run
    let transcriptRow: any = null;
    let minimizedText = '';

    const { data: existingTranscript } = await adminClient
      .from('transcripts')
      .select('*')
      .eq('recording_id', recording_id)
      .maybeSingle();

    if (existingTranscript) {
      transcriptRow = existingTranscript;
      minimizedText = existingTranscript.privacy_processed_text;
      logger.info('TRANSCRIPT_REUSED', 'stt_stage');
    } else {
      let audioUrl = recording.storage_path;
      try {
        const { data: signedData, error: signedErr } = await adminClient
          .storage
          .from('consultation-recordings')
          .createSignedUrl(recording.storage_path, 300);
        if (!signedErr && signedData?.signedUrl) {
          audioUrl = signedData.signedUrl;
        }
      } catch (_storageErr) {
        // Keep direct path if signed URL creation fails or in mock test environment
      }

      const sttProvider: STTProvider = new DeepgramSTTProvider();
      let sttResult;
      const sttStart = performance.now();
      logger.metric('deepgram_requests_total', 1);

      try {
        sttResult = await executeWithRetry(
          () => sttProvider.transcribe(audioUrl),
          'deepgram',
          'stt'
        );
        const sttDurationMs = Math.round(performance.now() - sttStart);
        logger.metric('stt_duration_ms', sttDurationMs);
        logger.metric('deepgram_latency_ms', sttDurationMs);
        logger.metric('deepgram_success_total', 1);
        logger.info('STT_COMPLETED', 'stt_stage', { provider: 'deepgram' }, sttDurationMs);
      } catch (sttError: any) {
        const sttDurationMs = Math.round(performance.now() - sttStart);
        const is429 = sttError.message?.includes('429');
        const errCode = is429 ? 'STT_RATE_LIMIT' : 'STT_PROVIDER_ERROR';

        logger.metric('deepgram_failure_total', 1);
        logger.metric('recordings_failed_total', 1, { error_code: errCode });
        logger.error('STT_FAILED', 'stt_stage', errCode, undefined, sttDurationMs);

        await adminClient
          .from('recordings')
          .update({
            processing_status: 'failed',
          })
          .eq('id', recording_id);

        await adminClient.from('audit_logs').insert({
          event_type: 'STT_PROCESSING_FAILED',
          clinic_id: doctor.clinic_id,
          actor_id: doctor.id,
          target_table: 'recordings',
          target_id: recording_id,
          metadata: { provider: 'deepgram', error_code: errCode },
        });

        return new Response(
          JSON.stringify({ error: 'Speech-to-text transcription service temporarily unavailable.', code: errCode, retryable: true }),
          { status: 502, headers: responseHeaders }
        );
      }

      // STEP 5: Privacy / Data-Minimization Stage
      const minimizationResult = DataMinimizer.process(sttResult.text);
      minimizedText = minimizationResult.minimizedText;

      await adminClient.from('audit_logs').insert({
        event_type: 'DATA_MINIMIZATION_PROCESSED',
        clinic_id: doctor.clinic_id,
        actor_id: doctor.id,
        target_table: 'transcripts',
        metadata: {
          recording_id,
          categories_detected: minimizationResult.categoriesDetected,
          redactions_performed: minimizationResult.redactionCount,
        },
      });

      // 7. Insert transcripts row with duplicate protection
      const transPersistStart = performance.now();
      const { data: insertedTranscript, error: transErr } = await adminClient
        .from('transcripts')
        .insert({
          recording_id,
          raw_text_ref: `transcripts/${recording_id}/raw.txt`,
          privacy_processed_text: minimizedText,
          stt_provider: sttResult.provider,
          stt_confidence: sttResult.confidence,
        })
        .select()
        .single();

      const transPersistDurationMs = Math.round(performance.now() - transPersistStart);
      logger.metric('transcript_persistence_ms', transPersistDurationMs);

      if (transErr) {
        const { data: conflictedTranscript } = await adminClient
          .from('transcripts')
          .select('*')
          .eq('recording_id', recording_id)
          .maybeSingle();

        if (conflictedTranscript) {
          transcriptRow = conflictedTranscript;
          minimizedText = conflictedTranscript.privacy_processed_text;
        } else {
          logger.error('TRANSCRIPT_PERSIST_FAILED', 'transcript_insert', 'TRANSCRIPT_PERSIST_FAILED', undefined, transPersistDurationMs);
          throw new Error(`Failed to save transcript: ${transErr.message}`);
        }
      } else {
        transcriptRow = insertedTranscript;
      }
    }

    // 8. Re-verify consent before entering LLM stage
    const { data: consentRecheck } = await adminClient
      .from('consultation_consents')
      .select('consent_status, revoked_at')
      .eq('consultation_id', consultation_id)
      .single();

    if (!consentRecheck || consentRecheck.consent_status !== 'granted' || consentRecheck.revoked_at !== null) {
      logger.warning('CONSENT_REVOKED_PRE_LLM', 'consent_recheck', 'CONSENT_REVOKED');
      logger.metric('recordings_failed_total', 1, { error_code: 'CONSENT_REVOKED' });

      await adminClient
        .from('recordings')
        .update({ processing_status: 'failed' })
        .eq('id', recording_id);

      return new Response(
        JSON.stringify({
          error: 'Processing aborted: Consent revoked before AI structuring.',
          code: 'CONSENT_REVOKED',
        }),
        { status: 403, headers: responseHeaders }
      );
    }

    // 9. LLM Stage via Provider Abstraction
    const llmProvider: LLMProvider = new ClaudeLLMProvider();
    let structuredDraft: any;
    const llmStart = performance.now();
    logger.metric('anthropic_requests_total', 1);

    try {
      structuredDraft = await executeWithRetry(
        () => llmProvider.generateDraft(minimizedText),
        'claude',
        'llm'
      );

      // Validate required clinical schema fields
      if (!structuredDraft || typeof structuredDraft !== 'object') {
        throw new Error('LLM returned non-object response');
      }
      if (!Array.isArray(structuredDraft.chief_complaints) && !structuredDraft.chief_complaint) {
        throw new Error('LLM output missing required chief_complaints field');
      }

      const llmDurationMs = Math.round(performance.now() - llmStart);
      logger.metric('llm_duration_ms', llmDurationMs);
      logger.metric('anthropic_latency_ms', llmDurationMs);
      logger.metric('anthropic_success_total', 1);
      logger.info('LLM_COMPLETED', 'llm_stage', { provider: 'claude' }, llmDurationMs);
    } catch (llmError: any) {
      const llmDurationMs = Math.round(performance.now() - llmStart);
      const is429 = llmError.message?.includes('429');
      const isSchemaErr = llmError.message?.includes('chief_complaint') || llmError.message?.includes('non-object');
      const errCode = is429 ? 'LLM_RATE_LIMIT' : (isSchemaErr ? 'AI_SCHEMA_INVALID' : 'LLM_PROVIDER_ERROR');

      logger.metric('anthropic_failure_total', 1);
      logger.metric('recordings_failed_total', 1, { error_code: errCode });
      logger.error('LLM_FAILED', 'llm_stage', errCode, undefined, llmDurationMs);

      await adminClient
        .from('recordings')
        .update({ processing_status: 'failed' })
        .eq('id', recording_id);

      await adminClient.from('audit_logs').insert({
        event_type: 'LLM_DRAFT_GENERATION_FAILED',
        clinic_id: doctor.clinic_id,
        actor_id: doctor.id,
        target_table: 'ai_drafts',
        metadata: { error_code: errCode, recording_id },
      });

      return new Response(
        JSON.stringify({
          error: 'AI clinical note generation failed. Your consultation transcript is safely saved.',
          code: errCode,
          transcript_id: transcriptRow.id,
          retryable: true,
        }),
        { status: 502, headers: responseHeaders }
      );
    }

    // 10. Re-check for active AI draft before insert to prevent duplicate active drafts
    const draftPersistStart = performance.now();
    const { data: postCheckDraft } = await adminClient
      .from('ai_drafts')
      .select('id, status')
      .eq('consultation_id', consultation_id)
      .in('status', ['ai_draft', 'doctor_reviewed', 'finalized'])
      .maybeSingle();

    let finalAiDraft = postCheckDraft;

    if (!finalAiDraft) {
      const { data: aiDraftRow, error: draftErr } = await adminClient
        .from('ai_drafts')
        .insert({
          consultation_id,
          structured_json: structuredDraft,
          status: 'ai_draft',
          model_used: structuredDraft.model_metadata?.model_name ?? 'claude-3-5-sonnet',
          prompt_version: structuredDraft.model_metadata?.prompt_version ?? 'v1.0.0',
          revision: 1,
        })
        .select()
        .single();

      if (draftErr) {
        logger.error('DRAFT_PERSIST_FAILED', 'ai_draft_insert', 'DRAFT_PERSIST_FAILED');
        throw new Error(`Failed to persist AI draft: ${draftErr.message}`);
      }
      finalAiDraft = aiDraftRow;
    }

    const draftPersistDurationMs = Math.round(performance.now() - draftPersistStart);
    logger.metric('draft_persistence_ms', draftPersistDurationMs);

    // 11. Mark recording as transcribed and completed
    await adminClient
      .from('recordings')
      .update({ processing_status: 'transcribed' })
      .eq('id', recording_id);

    const totalPipelineDurationMs = Math.round(performance.now() - pipelineStart);
    logger.metric('total_processing_duration_ms', totalPipelineDurationMs);
    logger.metric('recordings_completed_total', 1);
    logger.info('PROCESSING_COMPLETED', 'pipeline_complete', undefined, totalPipelineDurationMs);

    return new Response(
      JSON.stringify({
        status: 'success',
        recording_id,
        transcript_id: transcriptRow.id,
        ai_draft_id: finalAiDraft.id,
        ai_draft_status: finalAiDraft.status,
      }),
      { status: 200, headers: responseHeaders }
    );
  } catch (err: any) {
    const totalPipelineDurationMs = Math.round(performance.now() - pipelineStart);
    logger.error('PIPELINE_ERROR', 'pipeline_catch', 'UNKNOWN_PROCESSING_ERROR', undefined, totalPipelineDurationMs);
    logger.metric('recordings_failed_total', 1, { error_code: 'UNKNOWN_PROCESSING_ERROR' });

    return new Response(
      JSON.stringify({ error: 'An unexpected processing error occurred.', code: 'UNKNOWN_PROCESSING_ERROR' }),
      { status: 500, headers: responseHeaders }
    );
  }
});
