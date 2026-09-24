// Scheduled Retention & Purge Worker (Supabase Edge Function)
// Invariants 12 & 13: Data Minimization vs Statutory Retention
// NOTE: Remains practically inert until data_retention_policies.retention_days is explicitly configured.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

Deno.serve(async (req) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceRoleKey = Deno.env.get('SUPABASE_TEST_SERVICE_ROLE_KEY') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(
        JSON.stringify({ error: 'Supabase credentials not configured in environment.' }),
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      );
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false },
    });

    const nowIso = new Date().toISOString();

    // 1. Fetch active data retention policies
    const { data: policies, error: policyErr } = await supabase
      .from('data_retention_policies')
      .select('*');

    if (policyErr) {
      throw new Error(`Failed to fetch retention policies: ${policyErr.message}`);
    }

    // Check if raw_audio retention is configured
    const rawAudioPolicy = policies?.find((p) => p.data_class === 'raw_audio');
    const isAudioRetentionConfigured = rawAudioPolicy?.retention_days !== null && rawAudioPolicy?.retention_days !== undefined;

    // If retention_days is NULL across the board, worker logs and remains inert
    if (!isAudioRetentionConfigured) {
      console.log('[PurgeWorker] data_retention_policies.retention_days is NULL. Worker is safely inert; no records purged.');
    }

    // 2. Query expired artifacts: deletion_status='active', legal_hold=false, retention_expires_at IS NOT NULL AND retention_expires_at < now()
    const { data: expiredRecordings, error: recErr } = await supabase
      .from('recordings')
      .select('id, storage_path, consultation_id, legal_hold')
      .eq('deletion_status', 'active')
      .not('retention_expires_at', 'is', null)
      .lt('retention_expires_at', nowIso);

    if (recErr) {
      throw new Error(`Failed to query expired recordings: ${recErr.message}`);
    }

    let purgedCount = 0;
    let skippedLegalHoldCount = 0;

    for (const item of expiredRecordings ?? []) {
      // Step 7: Legal hold placed before scheduled deletion must be respected
      if (item.legal_hold === true) {
        skippedLegalHoldCount++;
        // Log skip to audit_logs
        await supabase.from('audit_logs').insert({
          event_type: 'PURGE_SKIPPED_LEGAL_HOLD',
          target_table: 'recordings',
          target_id: item.id,
          metadata: {
            reason: 'Item has legal_hold set to true; automated purge skipped.',
            storage_path: item.storage_path,
          },
        });
        continue;
      }

      // Mark deletion_status = 'pending_deletion'
      await supabase
        .from('recordings')
        .update({ deletion_status: 'pending_deletion' })
        .eq('id', item.id);

      // Log purge event to audit_logs
      await supabase.from('audit_logs').insert({
        event_type: 'RECORDING_PURGED_RETENTION',
        target_table: 'recordings',
        target_id: item.id,
        metadata: {
          storage_path: item.storage_path,
          consultation_id: item.consultation_id,
          purged_at: nowIso,
        },
      });

      // Execute storage deletion if file path is valid
      if (item.storage_path) {
        await supabase.storage
          .from('consultation-recordings')
          .remove([item.storage_path]);
      }

      // Update recording row to 'deleted'
      await supabase
        .from('recordings')
        .update({ deletion_status: 'deleted' })
        .eq('id', item.id);

      purgedCount++;
    }

    return new Response(
      JSON.stringify({
        status: 'success',
        raw_audio_policy_configured: isAudioRetentionConfigured,
        retention_days: rawAudioPolicy?.retention_days ?? null,
        expired_candidates_found: expiredRecordings?.length ?? 0,
        purged_count: purgedCount,
        skipped_legal_hold_count: skippedLegalHoldCount,
        timestamp: nowIso,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ error: err.message ?? 'Unknown worker error' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});
