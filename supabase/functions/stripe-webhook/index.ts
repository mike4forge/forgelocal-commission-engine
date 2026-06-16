// ForgeLocal — Stripe webhook -> cash_events -> generate_commission()
//
// IMPORTANT: deploy this function with JWT verification DISABLED. Stripe cannot
// send a Supabase auth token, so leaving JWT on returns 401 and the webhook fails.
//
// Events handled (start in Stripe TEST mode):
//   checkout.session.completed (mode=payment)      -> setup cash_event   (one-time fees)
//   checkout.session.completed (mode=subscription) -> stamps the GHL id onto the
//                                                     subscription so monthly charges match
//   invoice.paid                                   -> monthly cash_event (subscriptions)
//   charge.refunded                                -> refund cash_event  (clawback)
//
// Attribution (how a payment finds its deal):
//   The closing app appends the GHL OPPORTUNITY id to the Stripe Payment Link as
//   ?client_reference_id=<ghl_opportunity_id>. The webhook reads that, falling back
//   to metadata.ghl_opportunity_id, then metadata.deal_id. It looks up the matching
//   row in `deals` (ghl_opportunity_id) and attributes commission to that closer.
//   If nothing matches, the cash_event is recorded WITHOUT a deal and not calculated;
//   it waits for manual linking. We never silently drop a payment.
//
// Secrets required (set in Supabase, not in code):
//   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SIGNING_SECRET
// Provided automatically by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import Stripe from "https://esm.sh/stripe@16.12.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SIGNING_SECRET") ?? "";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      sig ?? "",
      webhookSecret,
      undefined,
      cryptoProvider,
    );
  } catch (err) {
    console.error("signature verification failed:", (err as Error).message);
    return new Response(`Webhook signature error: ${(err as Error).message}`, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object as Stripe.Checkout.Session;
        const oppId = s.client_reference_id
          ?? (s.metadata?.ghl_opportunity_id as string | undefined)
          ?? null;

        if (s.mode === "payment") {
          // one-time setup fee
          await ingestPayment({
            eventId: event.id,
            basis: "setup",
            amountCents: s.amount_total ?? 0,
            currency: s.currency ?? "usd",
            occurredAt: new Date(event.created * 1000).toISOString(),
            oppId,
            dealUuid: (s.metadata?.deal_id as string | undefined) ?? null,
            raw: s,
          });
        } else if (s.mode === "subscription" && s.subscription && oppId) {
          // first charge is handled by invoice.paid; stamp the subscription so every
          // future monthly invoice carries the GHL id and stays matched automatically.
          const subId = typeof s.subscription === "string" ? s.subscription : s.subscription.id;
          await stripe.subscriptions.update(subId, { metadata: { ghl_opportunity_id: oppId } });
        }
        break;
      }
      case "invoice.paid": {
        const inv = event.data.object as Stripe.Invoice;
        const oppId = await invoiceOppId(inv);
        await ingestPayment({
          eventId: event.id,
          basis: "monthly",
          amountCents: inv.amount_paid ?? 0,
          currency: inv.currency ?? "usd",
          occurredAt: new Date(event.created * 1000).toISOString(),
          oppId,
          dealUuid: (inv.metadata?.deal_id as string | undefined) ?? null,
          raw: inv,
        });
        break;
      }
      case "charge.refunded": {
        const ch = event.data.object as Stripe.Charge;
        await ingestRefund({
          eventId: event.id,
          amountCents: ch.amount_refunded ?? 0,
          currency: ch.currency ?? "usd",
          occurredAt: new Date(event.created * 1000).toISOString(),
          paymentIntent: typeof ch.payment_intent === "string"
            ? ch.payment_intent
            : (ch.payment_intent?.id ?? null),
          oppId: (ch.metadata?.ghl_opportunity_id as string | undefined) ?? null,
          raw: ch,
        });
        break;
      }
      // all other event types are ignored
    }
    return Response.json({ received: true });
  } catch (err) {
    console.error("handler error:", err);
    return new Response(`Handler error: ${(err as Error).message}`, { status: 500 });
  }
});

// Pull the GHL opportunity id off a subscription invoice (stamped at first charge).
async function invoiceOppId(inv: Stripe.Invoice): Promise<string | null> {
  const fromInvoice = (inv.subscription_details?.metadata?.ghl_opportunity_id
    ?? inv.metadata?.ghl_opportunity_id) as string | undefined;
  if (fromInvoice) return fromInvoice;
  if (inv.subscription) {
    const subId = typeof inv.subscription === "string" ? inv.subscription : inv.subscription.id;
    const sub = await stripe.subscriptions.retrieve(subId);
    return (sub.metadata?.ghl_opportunity_id as string | undefined) ?? null;
  }
  return null;
}

async function resolveDeal(oppId: string | null, dealUuid: string | null): Promise<string | null> {
  if (oppId) {
    const { data } = await supabase.from("deals").select("id").eq("ghl_opportunity_id", oppId).maybeSingle();
    if (data) return data.id;
  }
  if (dealUuid) {
    const { data } = await supabase.from("deals").select("id").eq("id", dealUuid).maybeSingle();
    if (data) return data.id;
  }
  return null;
}

async function runCalc(cashEventId: string) {
  const { error } = await supabase.rpc("generate_commission", { p_cash_event_id: cashEventId });
  if (error) throw error;
}

async function ingestPayment(e: {
  eventId: string;
  basis: "setup" | "monthly";
  amountCents: number;
  currency: string;
  occurredAt: string;
  oppId: string | null;
  dealUuid: string | null;
  raw: unknown;
}) {
  const dealId = await resolveDeal(e.oppId, e.dealUuid);
  const { data, error } = await supabase.from("cash_events").insert({
    deal_id: dealId,
    stripe_event_id: e.eventId,
    basis: e.basis,
    type: "payment",
    amount_cents: e.amountCents,
    currency: e.currency,
    occurred_at: e.occurredAt,
    raw: e.raw,
  }).select("id").maybeSingle();

  if (error) {
    if (error.code === "23505") { console.log("duplicate event ignored:", e.eventId); return; }
    throw error;
  }
  if (!dealId) { console.warn("cash_event recorded without a deal (needs manual link):", e.eventId); return; }
  await runCalc(data!.id);
}

async function ingestRefund(e: {
  eventId: string;
  amountCents: number;
  currency: string;
  occurredAt: string;
  paymentIntent: string | null;
  oppId: string | null;
  raw: unknown;
}) {
  // Recover the original payment's deal + basis via its Stripe payment_intent.
  let basis: "setup" | "monthly" = "setup";
  let dealId: string | null = null;
  if (e.paymentIntent) {
    const { data } = await supabase
      .from("cash_events")
      .select("deal_id, basis")
      .eq("type", "payment")
      .filter("raw->>payment_intent", "eq", e.paymentIntent)
      .maybeSingle();
    if (data) { basis = data.basis as "setup" | "monthly"; dealId = data.deal_id; }
  }
  if (!dealId) dealId = await resolveDeal(e.oppId, null);

  const { data, error } = await supabase.from("cash_events").insert({
    deal_id: dealId,
    stripe_event_id: e.eventId,
    basis,
    type: "refund",
    amount_cents: -Math.abs(e.amountCents),
    currency: e.currency,
    occurred_at: e.occurredAt,
    raw: e.raw,
  }).select("id").maybeSingle();

  if (error) {
    if (error.code === "23505") { console.log("duplicate refund ignored:", e.eventId); return; }
    throw error;
  }
  if (!dealId) { console.warn("refund recorded without a deal (needs manual link):", e.eventId); return; }
  await runCalc(data!.id);
}
