// ForgeLocal — submit an APPROVED payout batch to Ramp (1099 contractors)
//
// MONEY MOVES HERE. Safeguards, in order:
//   1. Caller must send a valid x-admin-secret header (PAYOUT_ADMIN_SECRET).
//   2. The batch must already be in status 'approved' (a human ran
//      approve_payout_batch in SQL). This function will NOT approve.
//   3. Every payee must have a ramp_recipient_id (Ramp vendor id). If any is
//      missing, the whole run aborts — we never partially pay a batch.
//   4. DRY-RUN BY DEFAULT. Without {"confirm": true} in the body, it returns the
//      exact bills it WOULD create and calls Ramp for nothing.
//
// PREREQUISITES before a live (confirm:true) run can work:
//   - Each rep onboarded as a Ramp vendor; reps.ramp_recipient_id = vendor id.
//   - Secrets set: RAMP_CLIENT_ID, RAMP_CLIENT_SECRET, RAMP_ENTITY_ID,
//     PAYOUT_ADMIN_SECRET. Optional: RAMP_API_BASE (defaults to the SANDBOX),
//     RAMP_PAYMENT_METHOD.
//   - Test end-to-end in the Ramp SANDBOX first (RAMP_API_BASE = demo) before
//     ever pointing at production.
//
// Deploy with JWT verification ON (admin-only). UNTESTED against Ramp — treat the
// first sandbox run as the real test.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

// Default to the Ramp SANDBOX so an accidental live run can't move real money.
const RAMP_API_BASE = Deno.env.get("RAMP_API_BASE") ?? "https://demo-api.ramp.com/developer/v1";
const RAMP_ENTITY_ID = Deno.env.get("RAMP_ENTITY_ID") ?? "";
const RAMP_PAYMENT_METHOD = Deno.env.get("RAMP_PAYMENT_METHOD") ?? "ACH";
const ADMIN_SECRET = Deno.env.get("PAYOUT_ADMIN_SECRET") ?? "";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  // Gate 1: admin secret
  if (!ADMIN_SECRET || req.headers.get("x-admin-secret") !== ADMIN_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }

  let body: { batch_id?: string; confirm?: boolean };
  try { body = await req.json(); } catch { return new Response("Bad JSON body", { status: 400 }); }
  const batchId = body.batch_id;
  const confirm = body.confirm === true;
  if (!batchId) return new Response('Missing "batch_id"', { status: 400 });

  // Gate 2: batch must be approved
  const { data: batch, error: batchErr } = await supabase
    .from("payout_batches").select("*").eq("id", batchId).maybeSingle();
  if (batchErr) return jsonError(500, batchErr.message);
  if (!batch) return jsonError(404, `batch ${batchId} not found`);
  if (batch.status !== "approved") {
    return jsonError(409, `batch is '${batch.status}'; it must be 'approved' before submitting`);
  }

  // Build the payee list
  const { data: rows, error: sumErr } = await supabase.rpc("payout_batch_summary", { p_batch_id: batchId });
  if (sumErr) return jsonError(500, sumErr.message);
  const payees = (rows ?? []) as Array<{
    rep_id: string; rep_name: string; ramp_recipient_id: string | null; amount_cents: number;
  }>;
  if (payees.length === 0) return jsonError(409, "batch has no payees");

  // Gate 3: every payee must have a Ramp vendor id — never partially pay
  const missing = payees.filter((p) => !p.ramp_recipient_id);
  if (missing.length > 0) {
    return jsonError(422, "some payees have no ramp_recipient_id; aborting", {
      missing: missing.map((m) => ({ rep_id: m.rep_id, rep_name: m.rep_name })),
    });
  }

  // Assemble the Ramp bills (one per rep). Stable invoice_number = idempotency anchor.
  const today = new Date().toISOString().slice(0, 10);
  const issuedAt = batch.created_at ? new Date(batch.created_at).toISOString().slice(0, 10) : today;
  const bills = payees.map((p) => ({
    vendor_id: p.ramp_recipient_id,
    entity_id: RAMP_ENTITY_ID,
    invoice_number: `forgelocal-payout-${batchId}-${p.rep_id}`,
    issued_at: issuedAt,
    due_at: today,
    invoice_currency: "USD",
    line_items: [{ amount: p.amount_cents / 100, memo: `Commission payout — batch ${batchId}` }],
    payment_details: { method: RAMP_PAYMENT_METHOD },
    _rep: { id: p.rep_id, name: p.rep_name, amount_cents: p.amount_cents },
  }));

  // Gate 4: dry-run unless explicitly confirmed
  if (!confirm) {
    return Response.json({
      dry_run: true,
      note: "No money moved. Re-send with {\"confirm\": true} to submit to Ramp.",
      api_base: RAMP_API_BASE,
      batch_id: batchId,
      total_cents: payees.reduce((s, p) => s + Number(p.amount_cents), 0),
      bills,
    });
  }

  // LIVE PATH ---------------------------------------------------------------
  if (!RAMP_ENTITY_ID) return jsonError(412, "RAMP_ENTITY_ID is not set");

  let token: string;
  try { token = await rampToken(); } catch (e) { return jsonError(502, `Ramp auth failed: ${(e as Error).message}`); }

  const results: Array<{ rep_id: string; ok: boolean; ramp_bill_id?: string; error?: string }> = [];
  for (const b of bills) {
    const { _rep, ...payload } = b;
    try {
      const res = await fetch(`${RAMP_API_BASE}/bills`, {
        method: "POST",
        headers: { "Authorization": `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { results.push({ rep_id: _rep.id, ok: false, error: `${res.status}: ${JSON.stringify(data)}` }); }
      else { results.push({ rep_id: _rep.id, ok: true, ramp_bill_id: data.id }); }
    } catch (e) {
      results.push({ rep_id: _rep.id, ok: false, error: (e as Error).message });
    }
  }

  const allOk = results.every((r) => r.ok);
  if (allOk) {
    await supabase.rpc("mark_batch_submitted", { p_batch_id: batchId, p_ramp_transfer_id: `ramp-batch-${batchId}` });
  }
  return Response.json({ dry_run: false, batch_id: batchId, all_succeeded: allOk, results }, { status: allOk ? 200 : 207 });
});

// Ramp OAuth client-credentials token (scope may need adjusting per your Ramp app config).
async function rampToken(): Promise<string> {
  const id = Deno.env.get("RAMP_CLIENT_ID") ?? "";
  const secret = Deno.env.get("RAMP_CLIENT_SECRET") ?? "";
  const basic = btoa(`${id}:${secret}`);
  const res = await fetch(`${RAMP_API_BASE}/token`, {
    method: "POST",
    headers: { "Authorization": `Basic ${basic}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&scope=bills:write",
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${res.status}: ${JSON.stringify(data)}`);
  return data.access_token as string;
}

function jsonError(status: number, message: string, extra: Record<string, unknown> = {}) {
  return Response.json({ error: message, ...extra }, { status });
}
