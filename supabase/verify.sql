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
