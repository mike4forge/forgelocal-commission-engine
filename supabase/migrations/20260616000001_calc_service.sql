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
