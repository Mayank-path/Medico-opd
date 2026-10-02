// Block 1G: Scheduled Retention & Purge Worker (Supabase Edge Function)
// Enforces DPDP Act data minimization vs statutory retention rules.
// Provides bounded batch processing, dry-run mode, atomic DB claim,
// 404 reconciliation, and explicit Production safety guards.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const PRODUCTION_PROJECT_ID = 'dyfrknwejqwilstcoytt';
const BUCKET_NAME = 'consultation-recordings';

Deno.serve(async (req) => {
  const startTime = Date.now();

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') || '';
    const serviceRoleKey =
      Deno.env.get('SUPABASE_TEST_SERVICE_ROLE_KEY') ||
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ||
      '';

    // 1. Production Safety Guard (Parts 1, 2 & 27)
    if (supabaseUrl.toLowerCase().includes(PRODUCTION_PROJECT_ID)) {
      console.error(`[PurgeWorker] CRITICAL: Production target (${PRODUCTION_PROJECT_ID}) detected. Aborting execution.`);
      return new Response(
        JSON.stringify({
          error: 'CRITICAL: Execution is strictly forbidden in Production.',
          project: PRODUCTION_PROJECT_ID,
        }),
        { status: 403, headers: { 'Content-Type': 'application/json' } }
      );
    }

    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(
        JSON.stringify({ error: 'Supabase credentials not configured in environment.' }),
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      );
    }

    const url = new URL(req.url);
    const isDryRun = url.searchParams.get('dry_run') === 'true' || url.searchParams.get('dryRun') === 'true';
    const limitParam = parseInt(url.searchParams.get('limit') || '50', 10);
    const batchSize = isNaN(limitParam) ? 50 : Math.min(Math.max(limitParam, 1), 200);
    const clinicId = url.searchParams.get('clinic_id') || undefined;

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false },
    });

    const nowIso = new Date().toISOString();

    // 2. Resolve active retention policy via authoritative RPC
    const { data: policyRows, error: policyErr } = await supabase.rpc(
      'resolve_retention_policy',
      {
        p_clinic_id: clinicId ?? null,
        p_data_class: 'raw_audio',
      }
    );

    if (policyErr) {
      throw new Error(`Failed to resolve retention policy: ${policyErr.message}`);
    }

    const policy = policyRows && policyRows.length > 0 ? policyRows[0] : null;
    const isConfigured = policy && policy.retention_days !== null && policy.is_enabled === true;

    if (!isConfigured) {
      console.log('[PurgeWorker] Retention policy is inert (retention_days is NULL or disabled). 0 records purged.');
      return new Response(
        JSON.stringify({
          status: 'inert',
          reason: 'retention_days_null_or_disabled',
          scope: policy?.scope ?? 'unresolved',
          dry_run: isDryRun,
          eligible_count: 0,
          deleted_count: 0,
          blocked_count: 0,
          already_missing_count: 0,
          error_count: 0,
          duration_ms: Date.now() - startTime,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // 3. Query expired candidate recordings (bounded batch)
    let query = supabase
      .from('recordings')
      .select('id, storage_path, consultation_id, patient_id, doctor_id, legal_hold, processing_status, retention_expires_at')
      .eq('deletion_status', 'active')
      .eq('legal_hold', false)
      .not('retention_expires_at', 'is', null)
      .lte('retention_expires_at', nowIso)
      .order('retention_expires_at', { ascending: true })
      .limit(batchSize);

    const { data: expiredRecordings, error: recErr } = await query;
    if (recErr) {
      throw new Error(`Failed to query expired recordings: ${recErr.message}`);
    }

    let eligibleCount = 0;
    let blockedCount = 0;
    let alreadyMissingCount = 0;
    let deletedCount = 0;
    let errorCount = 0;
    const items: Array<{ id: string; status: string; reason?: string }> = [];

    const activeProcessingStatuses = new Set(['pending', 'queued', 'transcribing', 'structuring']);

    for (const item of expiredRecordings ?? []) {
      // Rule checks: legal hold or active processing
      if (item.legal_hold === true) {
        blockedCount++;
        items.push({ id: item.id, status: 'blocked', reason: 'legal_hold' });
        continue;
      }

      if (activeProcessingStatuses.has(item.processing_status?.toLowerCase())) {
        blockedCount++;
        items.push({ id: item.id, status: 'blocked', reason: 'active_processing' });
        continue;
      }

      eligibleCount++;

      if (isDryRun) {
        items.push({ id: item.id, status: 'dry_run_eligible' });
        continue;
      }

      // LIVE DELETION PIPELINE (Atomic claim -> Storage delete -> Finalize)
      try {
        // Step A: Atomic DB claim (prevents race with worker starting processing)
        const { data: claimData, error: claimErr } = await supabase.rpc(
          'claim_recording_for_retention_deletion',
          {
            p_recording_id: item.id,
            p_worker_id: 'edge_retention_purge_worker',
          }
        );

        if (claimErr || !claimData || claimData.length === 0) {
          blockedCount++;
          items.push({ id: item.id, status: 'claim_failed_concurrent_race' });
          continue;
        }

        // Step B: Storage object removal
        const { error: storageErr } = await supabase.storage
          .from(BUCKET_NAME)
          .remove([item.storage_path]);

        if (storageErr) {
          // Check if object was already missing (Database orphan reconciliation)
          if (storageErr.message?.includes('not found') || (storageErr as any).statusCode === '404') {
            await supabase.rpc('reconcile_missing_recording_storage', { p_recording_id: item.id });
            await supabase.from('audit_logs').insert({
              event_type: 'MISSING_OBJECT_RECONCILIATION',
              target_table: 'recordings',
              target_id: item.id,
              metadata: {
                storage_path: item.storage_path,
                reason: 'storage_object_404',
              },
            });
            alreadyMissingCount++;
            items.push({ id: item.id, status: 'reconciled_missing' });
            continue;
          } else {
            // Revert claim on unexpected storage failure
            await supabase.rpc('revert_recording_deletion', {
              p_recording_id: item.id,
              p_error_code: 'STORAGE_DELETE_FAILED',
            });
            errorCount++;
            items.push({ id: item.id, status: 'storage_delete_failed', reason: storageErr.message });
            continue;
          }
        }

        // Step C: Finalize DB recording deletion
        await supabase.rpc('finalize_recording_deletion', { p_recording_id: item.id });

        // Step D: Write immutable audit record
        await supabase.from('audit_logs').insert({
          event_type: 'RETENTION_DELETE',
          target_table: 'recordings',
          target_id: item.id,
          metadata: {
            reason: 'retention_window_expired',
            storage_path: item.storage_path,
            purged_at: nowIso,
          },
        });

        deletedCount++;
        items.push({ id: item.id, status: 'deleted' });
      } catch (opErr: any) {
        errorCount++;
        items.push({ id: item.id, status: 'error', reason: opErr.message });
      }
    }

    const durationMs = Date.now() - startTime;

    return new Response(
      JSON.stringify({
        status: 'success',
        dry_run: isDryRun,
        batch_size: batchSize,
        policy_scope: policy.scope,
        retention_days: policy.retention_days,
        eligible_count: eligibleCount,
        orphan_count: 0,
        blocked_count: blockedCount,
        already_missing_count: alreadyMissingCount,
        deleted_count: deletedCount,
        error_count: errorCount,
        duration_ms: durationMs,
        items,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({
        error: err.message ?? 'Unknown worker error',
        duration_ms: Date.now() - startTime,
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});
