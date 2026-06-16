# ForgeLocal Commission Engine

Commission and payout engine for ForgeLocal's differential stairstep sales plan.

**Stack:** Supabase (Postgres + edge functions + cron) · Stripe webhooks (cash events) · GoHighLevel (deal attribution) · Ramp API (payouts).

## Commission model

Differential stairstep, **cash-basis**: commission is earned when cash is actually
collected (a Stripe cash event), and clawed back on refund/chargeback. Whoever
closes earns the closer rate; each manager above earns a fixed override; the
Director absorbs the residual so every full leg totals the cap.

| Rank | Setup override | Monthly override |
|------|----------------|------------------|
| Rep (closer)  | 13%  | 6% |
| Lead          | 3%   | 2% |
| State Manager | 1.5% | 1% |
| Director      | residual to cap | residual to cap |

**Cap (lever):** 18.58% setup / 9.29% monthly — the gross 20%/10% cap minus a
7.65% employer-FICA reserve. Stored in `commission_plans`; tunable without code.

Operating rules carried into the calc service (not the schema): **compression**
(lower of two same-rank earns the close), **orphan roll-up** (commission follows
tier, not the person), and **KPI-gated overrides** (a manager who misses quota
rolls their override up to the manager above).

## Schema

Eight tables. The six core tables plus `commission_plans` + `commission_rules`
(rates live in data, not code).

- **reps** — people + genealogy (adjacency list via `sponsor_id`).
- **commission_plans** — the cap lever + reserve, versioned.
- **commission_rules** — fixed tier overrides under a plan.
- **deals** — closed opportunities, attributed from GoHighLevel.
- **cash_events** — Stripe-driven money in/out; `basis` (setup|monthly) picks the
  rate set; `stripe_event_id` is unique for webhook idempotency.
- **commission_ledger** — append-only; one row per (cash_event, earning rep). The
  applied `rate_bps` is frozen on each row, and a guard trigger blocks deletes and
  any edit other than a one-time `payout_batch_id` assignment.
- **payout_batches** — groups ledger rows into a Ramp run; `approved_by`/
  `approved_at` is the human gate (payouts never auto-submit).
- **genealogy_snapshots** — point-in-time tree freeze so historical payouts stay
  reproducible after sponsors change.

## Local setup

```bash
supabase start
supabase db reset      # applies migrations + runs seed.sql
```

Copy `.env.example` to `.env` and fill in. Secrets come from env only.

## Status

- [x] Schema (`supabase/migrations/20260616000000_init.sql`)
- [x] Synthetic seed — Director → State → 2 Leads → 5 Reps + test deals (`supabase/seed.sql`)
- [x] Calc service — `generate_commission()` + clawback + batch runner (`supabase/migrations/20260616000001_calc_service.sql`)
- [x] Verification oracle with expected values (`supabase/verify.sql`)
- [ ] KPI/quota gate wiring — table exists (`override_eligibility`); quarterly GHL review thresholds TBD
- [ ] Stripe webhook ingest → cash_events (calls `generate_commission`)
- [ ] GoHighLevel deal sync
- [ ] Payout batch builder + Ramp submit (human-gated)
