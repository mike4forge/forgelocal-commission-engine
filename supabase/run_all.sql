-- ============================================================
-- run_all.sql — convenience bundle for first-time verification
-- Paste this whole file into the Supabase SQL Editor and Run.
-- It builds the schema, the calc service, loads the fake data,
-- runs the calculator, and prints the payout numbers to check.
-- (Source of truth is the individual files; this is just a bundle.)
-- ============================================================

-- ===== 1/4 schema =====
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

-- ===== 2/4 calc service =====
-- ForgeLocal Commission Engine — calc service
-- Generates append-only commission_ledger rows from cash_events.
--
-- Model: differential stairstep, cash-basis.
--   * Whoever closes earns the closer rate (the 'rep' rate), unless the closer
--     IS the Director (then they take the full cap on their own deal).
--   * Each manager ABOVE the closer earns their rank's fixed override, at most
--     once per leg (compression: a 2nd same-rank manager earns nothing).
--   * An override is paid only if the manager is eligible for the period
--     (KPI/quota gate); otherwise it is absorbed into the Director residual.
--   * The Director absorbs the residual so the leg totals exactly the cap.
--   * If a leg has no Director at the top (e.g. "no upline yet"), the residual
--     is simply unpaid and stays with the company.
--   * Refunds/chargebacks mirror the original rows, negated and proportionally
--     scaled, against the same genealogy snapshot.
--
-- All money is integer cents. Rates are basis points (bps); amount = cents*bps/10000
-- (integer truncation). The Director amount is computed as cap_amount minus the
-- sum of the other rows, so each full leg sums to the cap exactly (no penny drift).

-- ------------------------------------------------------------------ KPI/quota gate
-- Sourced from a quarterly manual review (likely off GHL analytics). Absence of a
-- row means eligible. Insert eligible=false rows to suppress a manager's overrides
-- for a period; those overrides roll into the Director residual.
create table override_eligibility (
  id           uuid primary key default gen_random_uuid(),
  rep_id       uuid not null references reps(id),
  period_start date not null,
  period_end   date not null,            -- inclusive
  eligible     boolean not null,
  note         text,
  created_at   timestamptz not null default now()
);
create index override_eligibility_rep_idx on override_eligibility(rep_id);

create or replace function override_eligible(p_rep uuid, p_ts timestamptz)
returns boolean language sql stable as $$
  select not exists (
    select 1 from override_eligibility
    where rep_id = p_rep
      and eligible = false
      and p_ts::date >= period_start
      and p_ts::date <= period_end
  );
$$;

-- ------------------------------------------------------------------ main generator
create or replace function generate_commission(p_cash_event_id uuid)
returns int language plpgsql as $$
declare
  ev            cash_events%rowtype;
  plan          commission_plans%rowtype;
  v_cap_bps     int;
  v_cap_amount  bigint;
  v_closer      reps%rowtype;
  v_closer_bps  int;
  v_lead_bps    int;
  v_state_bps   int;
  v_snap_id     uuid;
  v_paid_amount bigint := 0;
  v_lead_paid   boolean := false;
  v_state_paid  boolean := false;
  v_director_id uuid;
  v_director_lvl int;
  v_rows        int := 0;
  up            record;
  v_amt         bigint;
begin
  select * into ev from cash_events where id = p_cash_event_id;
  if not found then
    raise exception 'cash_event % not found', p_cash_event_id;
  end if;

  -- idempotency: never generate twice for the same cash_event
  if exists (select 1 from commission_ledger where cash_event_id = ev.id) then
    return 0;
  end if;

  select * into plan from commission_plans where is_active order by effective_from desc limit 1;
  if not found then
    raise exception 'no active commission_plan';
  end if;

  v_cap_bps    := case ev.basis when 'setup' then plan.setup_cap_bps else plan.monthly_cap_bps end;
  v_closer_bps := (select rate_bps from commission_rules where plan_id = plan.id and basis = ev.basis and role = 'rep');
  v_lead_bps   := (select rate_bps from commission_rules where plan_id = plan.id and basis = ev.basis and role = 'lead');
  v_state_bps  := (select rate_bps from commission_rules where plan_id = plan.id and basis = ev.basis and role = 'state_manager');

  -- refunds / chargebacks: mirror prior rows, negated and scaled
  if ev.type in ('refund','chargeback') or ev.amount_cents < 0 then
    return _claw_back(ev);
  end if;

  -- freeze the genealogy for reproducible math
  insert into genealogy_snapshots(reason, snapshot)
  values (
    'generate_commission cash_event ' || ev.id,
    (select coalesce(jsonb_object_agg(id::text, jsonb_build_object('sponsor_id', sponsor_id, 'role', role)), '{}'::jsonb) from reps)
  )
  returning id into v_snap_id;

  select r.* into v_closer from deals d join reps r on r.id = d.rep_id where d.id = ev.deal_id;
  if not found then
    raise exception 'cash_event % has no deal/closer', ev.id;
  end if;

  v_cap_amount := ev.amount_cents * v_cap_bps / 10000;

  -- Director closes own deal: takes the full cap, no overrides below.
  if v_closer.role = 'director' then
    insert into commission_ledger(cash_event_id, earning_rep_id, source_rep_id, genealogy_snapshot_id,
                                  basis, level, role_at_time, rate_bps, amount_cents)
    values (ev.id, v_closer.id, v_closer.id, v_snap_id, ev.basis, 0, 'director', v_cap_bps, v_cap_amount);
    return 1;
  end if;

  -- Closer earns the closer rate.
  v_amt := ev.amount_cents * v_closer_bps / 10000;
  insert into commission_ledger(cash_event_id, earning_rep_id, source_rep_id, genealogy_snapshot_id,
                                basis, level, role_at_time, rate_bps, amount_cents)
  values (ev.id, v_closer.id, v_closer.id, v_snap_id, ev.basis, 0, v_closer.role, v_closer_bps, v_amt);
  v_paid_amount := v_paid_amount + v_amt;
  v_rows := 1;

  -- Walk the upline from closer to root.
  for up in
    with recursive chain as (
      select r.id, r.role, r.sponsor_id, 1 as lvl
        from reps r where r.id = v_closer.sponsor_id
      union all
      select r.id, r.role, r.sponsor_id, chain.lvl + 1
        from reps r join chain on r.id = chain.sponsor_id
    )
    select * from chain order by lvl
  loop
    if up.role = 'director' then
      -- first director encountered is the residual absorber; pay after the loop
      if v_director_id is null then
        v_director_id  := up.id;
        v_director_lvl := up.lvl;
      end if;
    elsif up.role = 'lead' then
      if not v_lead_paid and override_eligible(up.id, ev.occurred_at) then
        v_amt := ev.amount_cents * v_lead_bps / 10000;
        insert into commission_ledger(cash_event_id, earning_rep_id, source_rep_id, genealogy_snapshot_id,
                                      basis, level, role_at_time, rate_bps, amount_cents)
        values (ev.id, up.id, v_closer.id, v_snap_id, ev.basis, up.lvl, 'lead', v_lead_bps, v_amt);
        v_paid_amount := v_paid_amount + v_amt;
        v_rows := v_rows + 1;
        v_lead_paid := true;
      end if;
    elsif up.role = 'state_manager' then
      if not v_state_paid and override_eligible(up.id, ev.occurred_at) then
        v_amt := ev.amount_cents * v_state_bps / 10000;
        insert into commission_ledger(cash_event_id, earning_rep_id, source_rep_id, genealogy_snapshot_id,
                                      basis, level, role_at_time, rate_bps, amount_cents)
        values (ev.id, up.id, v_closer.id, v_snap_id, ev.basis, up.lvl, 'state_manager', v_state_bps, v_amt);
        v_paid_amount := v_paid_amount + v_amt;
        v_rows := v_rows + 1;
        v_state_paid := true;
      end if;
    end if;
    -- reps in the upline earn no override
  end loop;

  -- Director residual = cap amount minus everything paid (keeps leg exact).
  if v_director_id is not null then
    v_amt := v_cap_amount - v_paid_amount;
    if v_amt < 0 then v_amt := 0; end if;
    insert into commission_ledger(cash_event_id, earning_rep_id, source_rep_id, genealogy_snapshot_id,
                                  basis, level, role_at_time, rate_bps, amount_cents)
    values (ev.id, v_director_id, v_closer.id, v_snap_id, ev.basis, v_director_lvl, 'director',
            v_cap_bps - (v_paid_amount * 10000 / nullif(ev.amount_cents,0)), v_amt);
    v_rows := v_rows + 1;
  end if;
  -- no director in leg: residual is unpaid, stays with the company

  return v_rows;
end;
$$;

-- ------------------------------------------------------------------ clawback helper
create or replace function _claw_back(ev cash_events)
returns int language plpgsql as $$
declare
  v_orig_paid bigint;
  v_ratio     numeric;
  v_rows      int := 0;
  L           commission_ledger%rowtype;
begin
  -- total positive payment cash for this deal + basis (the base the refund reverses)
  select coalesce(sum(amount_cents),0) into v_orig_paid
    from cash_events
   where deal_id = ev.deal_id and basis = ev.basis and type = 'payment' and amount_cents > 0;

  if v_orig_paid = 0 then
    return 0;  -- nothing to reverse yet; will be retried once the payment is processed
  end if;

  v_ratio := abs(ev.amount_cents)::numeric / v_orig_paid::numeric;

  -- mirror each prior positive ledger row tied to this deal + basis
  for L in
    select cl.* from commission_ledger cl
      join cash_events ce on ce.id = cl.cash_event_id
     where ce.deal_id = ev.deal_id and cl.basis = ev.basis and cl.amount_cents > 0
       and not exists (select 1 from commission_ledger r where r.reverses_ledger_id = cl.id)
  loop
    insert into commission_ledger(cash_event_id, earning_rep_id, source_rep_id, genealogy_snapshot_id,
                                  basis, level, role_at_time, rate_bps, amount_cents, reverses_ledger_id)
    values (ev.id, L.earning_rep_id, L.source_rep_id, L.genealogy_snapshot_id,
            L.basis, L.level, L.role_at_time, L.rate_bps,
            -round(L.amount_cents * v_ratio)::bigint, L.id);
    v_rows := v_rows + 1;
  end loop;

  return v_rows;
end;
$$;

-- ------------------------------------------------------------------ batch runner
-- Process every cash_event with no ledger rows yet, oldest first (so payments
-- are generated before the refunds that reverse them).
create or replace function generate_all_pending()
returns int language plpgsql as $$
declare
  ce_id uuid;
  total int := 0;
begin
  for ce_id in
    select id from cash_events ce
     where not exists (select 1 from commission_ledger cl where cl.cash_event_id = ce.id)
     order by occurred_at asc, created_at asc
  loop
    total := total + generate_commission(ce_id);
  end loop;
  return total;
end;
$$;

-- ===== 3/4 seed data =====
-- ForgeLocal Commission Engine — synthetic seed
-- Runs on `supabase db reset`. Provides source data only: reps + genealogy,
-- the active commission plan + tier rules, deals, and cash_events.
-- The commission_ledger, payout_batches, and genealogy_snapshots are left empty
-- on purpose — the calc service populates them.
--
-- Genealogy (rank: director > state_manager > lead > rep):
--
--   Dana Director (director, root)            1111…
--   ├── Sam State (state_manager)             2222…
--   │   └── Liam Lead (lead)                  3333…
--   │       ├── Alpha (rep)  5555…  -> leg: rep+lead+state+director (full leg)
--   │       └── Echo  (rep)  6666…  -> leg: rep+lead+state+director (2nd rep, one lead)
--   ├── Lena Lead (lead)                      4444…
--   │   └── Bravo (rep)      7777…  -> leg: rep+lead+director
--   └── Charlie (rep)        8888…  -> leg: rep+director
--
--   Delta (rep, no sponsor)  9999…  -> leg: rep only ("no upline yet")
--
-- Counts: 1 director, 1 state manager, 2 leads, 5 reps = 9 reps.
-- The five legs exercise every SETUP scenario in the comp plan.

-- ------------------------------------------------------------------ reps
insert into reps (id, name, email, role, sponsor_id, ghl_user_id) values
  ('11111111-1111-1111-1111-111111111111', 'Dana Director', 'dana@forgelocal.app',    'director',      null,                                   'ghl-dana'),
  ('22222222-2222-2222-2222-222222222222', 'Sam State',     'sam@forgelocal.app',     'state_manager', '11111111-1111-1111-1111-111111111111', 'ghl-sam'),
  ('33333333-3333-3333-3333-333333333333', 'Liam Lead',     'liam@forgelocal.app',    'lead',          '22222222-2222-2222-2222-222222222222', 'ghl-liam'),
  ('44444444-4444-4444-4444-444444444444', 'Lena Lead',     'lena@forgelocal.app',    'lead',          '11111111-1111-1111-1111-111111111111', 'ghl-lena'),
  ('55555555-5555-5555-5555-555555555555', 'Alpha Rep',     'alpha@forgelocal.app',   'rep',           '33333333-3333-3333-3333-333333333333', 'ghl-alpha'),
  ('66666666-6666-6666-6666-666666666666', 'Echo Rep',      'echo@forgelocal.app',    'rep',           '33333333-3333-3333-3333-333333333333', 'ghl-echo'),
  ('77777777-7777-7777-7777-777777777777', 'Bravo Rep',     'bravo@forgelocal.app',   'rep',           '44444444-4444-4444-4444-444444444444', 'ghl-bravo'),
  ('88888888-8888-8888-8888-888888888888', 'Charlie Rep',   'charlie@forgelocal.app', 'rep',           '11111111-1111-1111-1111-111111111111', 'ghl-charlie'),
  ('99999999-9999-9999-9999-999999999999', 'Delta Rep',     'delta@forgelocal.app',   'rep',           null,                                   'ghl-delta');

-- ------------------------------------------------------------------ commission plan (the cap lever)
insert into commission_plans (id, version, label, setup_cap_bps, monthly_cap_bps, reserve_bps, is_active) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'v1', 'Differential stairstep (launch)', 1858, 929, 765, true);

-- ------------------------------------------------------------------ commission rules (fixed tier overrides)
-- SETUP:   rep 13%, lead 3%, state 1.5%, director residual to 18.58% cap.
-- MONTHLY: rep 6%,  lead 2%, state 1%,   director residual to 9.29% cap.
insert into commission_rules (plan_id, basis, role, rate_bps, is_residual) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'setup',   'rep',           1300, false),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'setup',   'lead',           300, false),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'setup',   'state_manager',  150, false),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'setup',   'director',      null, true),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'monthly', 'rep',            600, false),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'monthly', 'lead',           200, false),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'monthly', 'state_manager',  100, false),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'monthly', 'director',      null, true);

-- ------------------------------------------------------------------ deals (amounts from the pricing menu, in cents)
insert into deals (id, ghl_opportunity_id, rep_id, product, amount_cents, status, closed_at) values
  ('00000000-0000-0000-0000-00000000dea1', 'ghl-opp-001', '55555555-5555-5555-5555-555555555555', 'Inbound + Web + GHL Connect', 127500, 'won', now() - interval '20 days'),
  ('00000000-0000-0000-0000-00000000dea2', 'ghl-opp-002', '77777777-7777-7777-7777-777777777777', 'Voice AI Snapshot',           250000, 'won', now() - interval '18 days'),
  ('00000000-0000-0000-0000-00000000dea3', 'ghl-opp-003', '88888888-8888-8888-8888-888888888888', 'Inbound Agent + Web Widget',  100000, 'won', now() - interval '15 days'),
  ('00000000-0000-0000-0000-00000000dea4', 'ghl-opp-004', '99999999-9999-9999-9999-999999999999', 'Inbound Agent',                50000, 'won', now() - interval '12 days'),
  ('00000000-0000-0000-0000-00000000dea5', 'ghl-opp-005', '11111111-1111-1111-1111-111111111111', 'Full GHL Build-Out',          600000, 'won', now() - interval '10 days'),
  ('00000000-0000-0000-0000-00000000dea6', 'ghl-opp-006', '66666666-6666-6666-6666-666666666666', 'Outbound voice AI agents',    100000, 'won', now() - interval '8 days');

-- ------------------------------------------------------------------ cash_events (Stripe-driven; setup, monthly, and a refund)
insert into cash_events (deal_id, stripe_event_id, basis, type, amount_cents, occurred_at) values
  -- setup payments
  ('00000000-0000-0000-0000-00000000dea1', 'evt_setup_001',  'setup',   'payment',  127500, now() - interval '20 days'),
  ('00000000-0000-0000-0000-00000000dea2', 'evt_setup_002',  'setup',   'payment',  250000, now() - interval '18 days'),
  ('00000000-0000-0000-0000-00000000dea3', 'evt_setup_003',  'setup',   'payment',  100000, now() - interval '15 days'),
  ('00000000-0000-0000-0000-00000000dea4', 'evt_setup_004',  'setup',   'payment',   50000, now() - interval '12 days'),
  ('00000000-0000-0000-0000-00000000dea5', 'evt_setup_005',  'setup',   'payment',  600000, now() - interval '10 days'),
  ('00000000-0000-0000-0000-00000000dea6', 'evt_setup_006',  'setup',   'payment',  100000, now() - interval '8 days'),
  -- recurring (monthly) payment on the Voice AI Snapshot deal
  ('00000000-0000-0000-0000-00000000dea2', 'evt_month_002a', 'monthly', 'payment',  100000, now() - interval '4 days'),
  -- refund clawing back the Outbound setup (negative amount, same basis)
  ('00000000-0000-0000-0000-00000000dea6', 'evt_refund_006', 'setup',   'refund',  -100000, now() - interval '2 days');

-- ===== 4/4 generate + verify =====
-- ForgeLocal Commission Engine — verification oracle
-- Run AFTER `supabase db reset` (schema + seed) to generate and check the ledger.
--   psql "$SUPABASE_DB_URL" -f supabase/verify.sql
-- Compare the output against the EXPECTED tables in the comments below.

-- 1) generate the ledger from all seeded cash_events
select generate_all_pending() as rows_written;   -- expect 19

-- 2) per-event leg breakdown
select ce.stripe_event_id, r.name as earns, cl.role_at_time, cl.rate_bps, cl.amount_cents
  from commission_ledger cl
  join cash_events ce on ce.id = cl.cash_event_id
  join reps r on r.id = cl.earning_rep_id
 order by ce.occurred_at, cl.level;

-- 3) net commission per rep (the bottom line)
select r.name, sum(cl.amount_cents) as net_cents
  from commission_ledger cl
  join reps r on r.id = cl.earning_rep_id
 group by r.name
 order by net_cents desc;

-- =====================================================================
-- EXPECTED — per cash_event (amounts in cents; each full leg sums to cap)
-- =====================================================================
-- evt_setup_001  Alpha 16575 | Liam 3825 | Sam 1912 | Dana 1377      (cap 23689 on 127500)
-- evt_setup_002  Bravo 32500 | Lena 7500 | Dana 6450                 (cap 46450 on 250000)
-- evt_setup_003  Charlie 13000 | Dana 5580                           (cap 18580 on 100000)
-- evt_setup_004  Delta 6500                                          (no upline; 2790 unpaid)
-- evt_setup_005  Dana 111480 (director closes own; full cap on 600000)
-- evt_setup_006  Echo 13000 | Liam 3000 | Sam 1500 | Dana 1080       (cap 18580 on 100000)
-- evt_month_002a Bravo 6000 | Lena 2000 | Dana 1290                  (monthly cap 9290 on 100000)
-- evt_refund_006 Echo -13000 | Liam -3000 | Sam -1500 | Dana -1080   (full reversal of evt_setup_006)
--
-- Total rows written: 4+3+2+1+1+4+3+4 = 19
-- =====================================================================
-- EXPECTED — net per rep
-- =====================================================================
--   Dana    126177
--   Bravo    38500
--   Alpha    16575
--   Charlie  13000
--   Lena      9500
--   Delta     6500
--   Liam      3825
--   Sam       1912
--   Echo          0   (paid on setup, fully clawed back by the refund)
-- =====================================================================
