-- ForgeLocal Commission Engine — initial schema
-- Differential stairstep MLM plan. Cash-basis. Append-only ledger.
--
-- Design notes:
--   * Money is always integer cents (bigint). Never float.
--   * Genealogy is an adjacency list (reps.sponsor_id); point-in-time math is
--     frozen via genealogy_snapshots so historical payouts stay reproducible.
--   * commission_ledger is append-only: amounts/rates can never change; only a
--     null->value payout_batch_id assignment is permitted (see guard trigger).
--   * Banking details live in Ramp. We store only a Ramp recipient token.
--   * Secrets come from env vars only — none are stored in the database.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums
create type rep_role         as enum ('rep', 'lead', 'state_manager', 'director');
create type commission_basis as enum ('setup', 'monthly');
create type cash_event_type  as enum ('payment', 'refund', 'chargeback');
create type payout_status    as enum ('draft', 'pending_approval', 'approved', 'submitted', 'paid', 'failed');

-- ---------------------------------------------------------------- reps
-- Genealogy via adjacency list. sponsor_id is the upline; null at the root
-- (the Director) or for a rep with "no upline yet".
create table reps (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  email              text unique,
  role               rep_role not null,
  sponsor_id         uuid references reps(id),
  ghl_user_id        text,               -- GoHighLevel attribution link
  ramp_recipient_id  text,               -- Ramp payout token (never raw bank details)
  status             text not null default 'active',
  created_at         timestamptz not null default now()
);
create index reps_sponsor_id_idx on reps(sponsor_id);

-- ---------------------------------------------------------------- commission_plans
-- The cap "lever" lives here, versioned. The Director absorbs the residual up
-- to the cap; the reserve carves employer FICA out of the gross 20%/10% cap.
create table commission_plans (
  id               uuid primary key default gen_random_uuid(),
  version          text not null,
  label            text,
  setup_cap_bps    int not null,            -- 1858 = 18.58%
  monthly_cap_bps  int not null,            -- 929  = 9.29%
  reserve_bps      int not null default 765,-- 7.65% employer-tax reserve carved from the gross cap
  is_active        boolean not null default true,
  effective_from   timestamptz not null default now(),
  created_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------- commission_rules
-- Fixed tier overrides under a plan. The Director row is is_residual (rate is
-- computed as cap minus the sum of the other tiers present in the leg).
create table commission_rules (
  id           uuid primary key default gen_random_uuid(),
  plan_id      uuid not null references commission_plans(id),
  basis        commission_basis not null,
  role         rep_role not null,
  rate_bps     int,                          -- null when is_residual
  is_residual  boolean not null default false,
  unique (plan_id, basis, role)
);

-- ---------------------------------------------------------------- deals
-- Attribution from GoHighLevel. rep_id is the closer.
create table deals (
  id                 uuid primary key default gen_random_uuid(),
  ghl_opportunity_id text unique,
  rep_id             uuid not null references reps(id),
  product            text,
  amount_cents       bigint not null,
  currency           text not null default 'usd',
  status             text not null default 'won',
  closed_at          timestamptz,
  created_at         timestamptz not null default now()
);
create index deals_rep_id_idx on deals(rep_id);

-- ---------------------------------------------------------------- cash_events
-- Driven by Stripe webhooks; this is the trigger for all commission. Cash-basis:
-- commission is earned when money is actually collected, clawed back on refund.
create table cash_events (
  id              uuid primary key default gen_random_uuid(),
  deal_id         uuid references deals(id),
  stripe_event_id text unique not null,        -- idempotency guard vs webhook re-delivery
  basis           commission_basis not null,   -- setup vs monthly => which rate set applies
  type            cash_event_type not null default 'payment',
  amount_cents    bigint not null,             -- negative for refunds/chargebacks => clawbacks
  currency        text not null default 'usd',
  occurred_at     timestamptz not null,
  raw             jsonb,                        -- original Stripe payload, for audit
  created_at      timestamptz not null default now()
);
create index cash_events_deal_id_idx on cash_events(deal_id);

-- ---------------------------------------------------------------- payout_batches
-- Groups ledger rows into a Ramp payout run. approved_by/approved_at is the
-- human gate: money in motion never auto-submits to Ramp.
create table payout_batches (
  id               uuid primary key default gen_random_uuid(),
  period_start     date,
  period_end       date,
  status           payout_status not null default 'draft',
  ramp_transfer_id text,
  total_cents      bigint not null default 0,
  approved_by      text,
  approved_at      timestamptz,
  created_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------- genealogy_snapshots
-- Point-in-time freeze of the tree so a payout computed today stays reproducible
-- even if sponsors change later. Each ledger row references the snapshot it used.
create table genealogy_snapshots (
  id          uuid primary key default gen_random_uuid(),
  captured_at timestamptz not null default now(),
  reason      text,
  snapshot    jsonb not null      -- rep_id -> { sponsor_id, role } at capture time
);

-- ---------------------------------------------------------------- commission_ledger
-- APPEND-ONLY. One row per (cash_event, earning_rep) commission slice. Reversals
-- are new negative rows (reverses_ledger_id), never edits.
create table commission_ledger (
  id                     uuid primary key default gen_random_uuid(),
  cash_event_id          uuid not null references cash_events(id),
  earning_rep_id         uuid not null references reps(id),   -- who gets paid
  source_rep_id          uuid not null references reps(id),   -- whose deal generated it
  genealogy_snapshot_id  uuid references genealogy_snapshots(id),
  basis                  commission_basis not null,
  level                  int not null,        -- 0 = closer/self, 1..n = upline distance
  role_at_time           rep_role not null,
  rate_bps               int not null,        -- rate actually applied, frozen for audit
  amount_cents           bigint not null,     -- positive = earn, negative = clawback/reversal
  reverses_ledger_id     uuid references commission_ledger(id),
  payout_batch_id        uuid references payout_batches(id),
  created_at             timestamptz not null default now()
);
create index commission_ledger_earning_rep_idx on commission_ledger(earning_rep_id);
create index commission_ledger_cash_event_idx  on commission_ledger(cash_event_id);
create index commission_ledger_batch_idx       on commission_ledger(payout_batch_id);

-- Append-only enforcement: no deletes; on update, every financial column is
-- frozen and payout_batch_id may only go null -> value (and is frozen once set).
create or replace function commission_ledger_guard() returns trigger as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'commission_ledger is append-only; DELETE not allowed';
  end if;
  if  new.cash_event_id         is distinct from old.cash_event_id
   or new.earning_rep_id        is distinct from old.earning_rep_id
   or new.source_rep_id         is distinct from old.source_rep_id
   or new.genealogy_snapshot_id is distinct from old.genealogy_snapshot_id
   or new.basis                 is distinct from old.basis
   or new.level                 is distinct from old.level
   or new.role_at_time          is distinct from old.role_at_time
   or new.rate_bps              is distinct from old.rate_bps
   or new.amount_cents          is distinct from old.amount_cents
   or new.reverses_ledger_id    is distinct from old.reverses_ledger_id
   or old.payout_batch_id       is not null
  then
    raise exception 'commission_ledger is append-only; only payout_batch_id (null->value) may change';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger commission_ledger_no_mutate
  before update or delete on commission_ledger
  for each row execute function commission_ledger_guard();
