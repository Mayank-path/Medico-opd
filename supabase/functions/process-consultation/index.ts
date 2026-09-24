// Edge Function: process-consultation
// Orchestrates STT transcription, privacy data-minimization, and LLM clinical draft generation
// Invariants 11-15: Provider independence, DB consent verification, prompt injection defense

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { STTProvider, LLMProvider } from '../_shared/providers/types.ts';
import { DeepgramSTTProvider } from '../_shared/providers/deepgram_provider.ts';
import { ClaudeLLMProvider } from '../_shared/providers/claude_provider.ts';
import { DataMinimizer } from '../_shared/privacy/data_minimizer.ts';

Deno.serve(async (req) => {
  try {
    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405 });
    }

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing authorization bearer token' }), { status: 401 });
    }

    const { recording_id, consultation_id } = await req.json();
    if (!recording_id || !consultation_id) {
      return new Response(JSON.stringify({ error: 'recording_id and consultation_id are required' }), { status: 400 });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_TEST_SERVICE_ROLE_KEY') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Client authenticated with caller's JWT to enforce RLS and clinic scoping
    const userClient = createClient(supabaseUrl, authHeader.replace('Bearer ', ''), {
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
      return new Response(JSON.stringify({ error: 'Caller doctor profile not found or unauthorized' }), { status: 403 });
    }

    // 2. Fetch recording record
    const { data: recording, error: recErr } = await userClient
      .from('recordings')
      .select('*')
      .eq('id', recording_id)
      .single();

    if (recErr || !recording) {
      return new Response(JSON.stringify({ error: 'Recording record not found or cross-clinic access denied' }), { status: 404 });
    }

    // 3. STEP 7 Failure Handling: Immediate re-check of consent status BEFORE transcription begins
    // Handles scenario where patient revoked consent after recording was initiated/uploaded
    const { data: consentRecord, error: consentErr } = await adminClient
      .from('consultation_consents')
      .select('consent_status, revoked_at')
      .eq('consultation_id', consultation_id)
      .single();

    if (consentErr || !consentRecord || consentRecord.consent_status !== 'granted' || consentRecord.revoked_at !== null) {
      // Mark processing as failed due to revoked consent
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
        { status: 403, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // 4. Update recording status to 'transcribing'
    await adminClient
      .from('recordings')
      .update({ processing_status: 'transcribing' })
      .eq('id', recording_id);

    // 5. STT Stage via Provider Abstraction (never importing vendor SDK directly)
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
    try {
      sttResult = await sttProvider.transcribe(audioUrl);
    } catch (sttError: any) {
      // STEP 7 Failure Handling: STT failure moves status to 'failed', never silently lost
      await adminClient
        .from('recordings')
        .update({ processing_status: 'failed' })
        .eq('id', recording_id);

      await adminClient.from('audit_logs').insert({
        event_type: 'STT_PROCESSING_FAILED',
        clinic_id: doctor.clinic_id,
        actor_id: doctor.id,
        target_table: 'recordings',
        target_id: recording_id,
        metadata: { error: sttError.message, provider: 'deepgram' },
      });

      return new Response(
        JSON.stringify({ error: `STT Transcription failed: ${sttError.message}`, retryable: true }),
        { status: 502, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // 6. STEP 5: Privacy / Data-Minimization Stage
    const minimizationResult = DataMinimizer.process(sttResult.text);

    // Log categories of processing occurred (not sensitive text) to audit_logs
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

    // 7. Insert transcripts row
    const { data: transcriptRow, error: transErr } = await adminClient
      .from('transcripts')
      .insert({
        recording_id,
        raw_text_ref: `transcripts/${recording_id}/raw.txt`,
        privacy_processed_text: minimizationResult.minimizedText,
        stt_provider: sttResult.provider,
        stt_confidence: sttResult.confidence,
      })
      .select()
      .single();

    if (transErr) {
      throw new Error(`Failed to save transcript: ${transErr.message}`);
    }

    // 8. LLM Stage via Provider Abstraction (never importing vendor SDK directly)
    const llmProvider: LLMProvider = new ClaudeLLMProvider();
    let structuredDraft;
    try {
      structuredDraft = await llmProvider.generateDraft(minimizationResult.minimizedText);
    } catch (llmError: any) {
      // STEP 7 Failure Handling: LLM failure leaves NO corrupted ai_drafts row
      await adminClient
        .from('recordings')
        .update({ processing_status: 'transcribed' }) // audio is transcribed, but draft failed
        .eq('id', recording_id);

      await adminClient.from('audit_logs').insert({
        event_type: 'LLM_DRAFT_GENERATION_FAILED',
        clinic_id: doctor.clinic_id,
        actor_id: doctor.id,
        target_table: 'ai_drafts',
        metadata: { error: llmError.message, recording_id },
      });

      return new Response(
        JSON.stringify({
          error: `AI draft generation failed: ${llmError.message}. Transcript preserved.`,
          transcript_id: transcriptRow.id,
          retryable: true,
        }),
        { status: 502, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // 9. Persist ai_drafts record in status 'ai_draft'
    const { data: aiDraftRow, error: draftErr } = await adminClient
      .from('ai_drafts')
      .insert({
        consultation_id,
        structured_json: structuredDraft,
        status: 'ai_draft',
        model_used: structuredDraft.model_metadata?.model_name ?? 'claude-3-5-sonnet',
        prompt_version: structuredDraft.model_metadata?.prompt_version ?? 'v1.0.0',
      })
      .select()
      .single();

    if (draftErr) {
      throw new Error(`Failed to persist AI draft: ${draftErr.message}`);
    }

    // 10. Mark recording as transcribed and completed
    await adminClient
      .from('recordings')
      .update({ processing_status: 'transcribed' })
      .eq('id', recording_id);

    return new Response(
      JSON.stringify({
        status: 'success',
        recording_id,
        transcript_id: transcriptRow.id,
        ai_draft_id: aiDraftRow.id,
        ai_draft_status: aiDraftRow.status,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ error: err.message ?? 'Unknown pipeline error' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});
