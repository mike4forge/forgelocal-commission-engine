-- ForgeLocal Commission Engine — payout batch builder + approval gate
--
-- Turns unpaid commission_ledger rows into a payout batch, nets per rep, and
-- enforces a human approval gate before anything can be submitted to Ramp.
--
-- Lifecycle: draft -> pending_approval -> approved -> submitted -> paid
--   build_payout_batch()    creates a pending_approval batch and links rows
--   approve_payout_batch()   human gate: pending_approval -> approved
--   mark_batch_submitted()   approved -> submitted (called after a Ramp transfer)
--   mark_batch_paid()        submitted -> paid
--   cancel_payout_batch()    unlinks rows and resets a not-yet-submitted batch
--
-- Netting rule: per rep, sum all unpaid rows (earnings minus clawbacks) up to the
-- period end. Reps with a net > 0 are paid and ALL their unpaid rows are batched.
-- Reps with net <= 0 are left unbatched so the deficit carries into a later batch
-- (we never "forgive" a clawback by marking it paid, and never pay a negative).

-- Relax the append-only guard: payout_batch_id is operational metadata, not a
-- financial figure, so it may be set OR cleared (so a batch can be rebuilt/cancelled).
-- Every financial/identity column stays frozen, and deletes stay blocked. The
-- batch lifecycle functions below enforce that a submitted/paid batch can't be undone.
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
  then
    raise exception 'commission_ledger is append-only; financial columns are frozen';
  end if;
  return new;
end;
$$ language plpgsql;

-- ------------------------------------------------------------------ build
create or replace function build_payout_batch(p_period_start date, p_period_end date)
returns uuid language plpgsql as $$
declare
  v_batch_id uuid;
  v_total    bigint := 0;
begin
  insert into payout_batches(period_start, period_end, status, total_cents)
  values (p_period_start, p_period_end, 'pending_approval', 0)
  returning id into v_batch_id;

  with unpaid as (
    select cl.id, cl.earning_rep_id, cl.amount_cents
      from commission_ledger cl
      join cash_events ce on ce.id = cl.cash_event_id
     where cl.payout_batch_id is null
       and ce.occurred_at::date <= p_period_end
  ),
  payable as (
    select earning_rep_id
      from unpaid
     group by earning_rep_id
    having sum(amount_cents) > 0
  )
  update commission_ledger cl
     set payout_batch_id = v_batch_id
    from unpaid u
   where cl.id = u.id
     and u.earning_rep_id in (select earning_rep_id from payable);

  select coalesce(sum(amount_cents), 0) into v_total
    from commission_ledger where payout_batch_id = v_batch_id;

  update payout_batches set total_cents = v_total where id = v_batch_id;
  return v_batch_id;
end;
$$;

-- ------------------------------------------------------------------ summary (the review sheet)
create or replace function payout_batch_summary(p_batch_id uuid)
returns table(rep_id uuid, rep_name text, ramp_recipient_id text, amount_cents bigint)
language sql stable as $$
  select r.id, r.name, r.ramp_recipient_id, sum(cl.amount_cents)
    from commission_ledger cl
    join reps r on r.id = cl.earning_rep_id
   where cl.payout_batch_id = p_batch_id
   group by r.id, r.name, r.ramp_recipient_id
   order by sum(cl.amount_cents) desc;
$$;

-- ------------------------------------------------------------------ approve (human gate)
create or replace function approve_payout_batch(p_batch_id uuid, p_approver text)
returns void language plpgsql as $$
declare v_status payout_status; v_total bigint;
begin
  select status, total_cents into v_status, v_total from payout_batches where id = p_batch_id;
  if not found then raise exception 'batch % not found', p_batch_id; end if;
  if v_status <> 'pending_approval' then
    raise exception 'batch % is %; only pending_approval can be approved', p_batch_id, v_status;
  end if;
  if v_total <= 0 then
    raise exception 'batch % total is % cents; nothing to approve', p_batch_id, v_total;
  end if;
  update payout_batches
     set status = 'approved', approved_by = p_approver, approved_at = now()
   where id = p_batch_id;
end;
$$;

-- ------------------------------------------------------------------ submit / paid (post-Ramp state)
create or replace function mark_batch_submitted(p_batch_id uuid, p_ramp_transfer_id text)
returns void language plpgsql as $$
declare v_status payout_status;
begin
  select status into v_status from payout_batches where id = p_batch_id;
  if not found then raise exception 'batch % not found', p_batch_id; end if;
  if v_status <> 'approved' then
    raise exception 'batch % is %; must be approved before submitting', p_batch_id, v_status;
  end if;
  update payout_batches set status = 'submitted', ramp_transfer_id = p_ramp_transfer_id where id = p_batch_id;
end;
$$;

create or replace function mark_batch_paid(p_batch_id uuid)
returns void language plpgsql as $$
begin
  update payout_batches set status = 'paid' where id = p_batch_id and status = 'submitted';
  if not found then raise exception 'batch % is not in submitted state', p_batch_id; end if;
end;
$$;

-- ------------------------------------------------------------------ cancel (only before submission)
create or replace function cancel_payout_batch(p_batch_id uuid)
returns void language plpgsql as $$
declare v_status payout_status;
begin
  select status into v_status from payout_batches where id = p_batch_id;
  if not found then raise exception 'batch % not found', p_batch_id; end if;
  if v_status in ('submitted', 'paid') then
    raise exception 'batch % is %; cannot cancel after submission', p_batch_id, v_status;
  end if;
  update commission_ledger set payout_batch_id = null where payout_batch_id = p_batch_id;
  update payout_batches set status = 'draft', total_cents = 0 where id = p_batch_id;
end;
$$;
