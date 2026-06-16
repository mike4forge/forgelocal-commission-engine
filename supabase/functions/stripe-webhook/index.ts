// ForgeLocal — Stripe webhook -> cash_events -> generate_commission()
//
// IMPORTANT: deploy this function with JWT verification DISABLED. Stripe cannot
// send a Supabase auth token, so leaving JWT on returns 401 and the webhook fails.
//
// Events handled (start in Stripe TEST mode):
//   checkout.session.completed (mode=payment) -> setup cash_event   (one-time fees)
//   invoice.paid                              -> monthly cash_event (subscriptions)
//   charge.refunded                           -> refund cash_event  (clawback)
//
// Attribution: each Stripe payment is matched to a deal via metadata —
// metadata.ghl_opportunity_id (preferred) or metadata.deal_id. If neither is
// present, the cash_event is recorded WITHOUT a deal and not calculated; it waits
// for manual linking. We never silently drop a payment.
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
        if (s.mode === "payment") {
          await ingestPayment({
            eventId: event.id,
            basis: "setup",
            amountCents: s.amount_total ?? 0,
            currency: s.currency ?? "usd",
            occurredAt: new Date(event.created * 1000).toISOString(),
            metadata: (s.metadata ?? {}) as Record<string, string>,
            raw: s,
          });
        }
        break;
      }
      case "invoice.paid": {
        const inv = event.data.object as Stripe.Invoice;
        await ingestPayment({
          eventId: event.id,
          basis: "monthly",
          amountCents: inv.amount_paid ?? 0,
          currency: inv.currency ?? "usd",
          occurredAt: new Date(event.created * 1000).toISOString(),
          metadata: (inv.metadata ?? {}) as Record<string, string>,
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
          metadata: (ch.metadata ?? {}) as Record<string, string>,
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

async function resolveDealId(metadata: Record<string, string>): Promise<string | null> {
  if (metadata.deal_id) return metadata.deal_id;
  const opp = metadata.ghl_opportunity_id;
  if (!opp) return null;
  const { data } = await supabase.from("deals").select("id").eq("ghl_opportunity_id", opp).maybeSingle();
  return data?.id ?? null;
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
  metadata: Record<string, string>;
  raw: unknown;
}) {
  const dealId = await resolveDealId(e.metadata);
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
  metadata: Record<string, string>;
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
  if (!dealId) dealId = await resolveDealId(e.metadata);

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
