-- ForgeLocal — payout batch verification
-- Run AFTER applying 20260618000002_payout_batches.sql.
-- Builds a batch from everything currently unpaid, then shows who gets paid.

-- 1) build a batch covering all unpaid commissions through year-end
select build_payout_batch('2026-01-01', '2026-12-31') as new_batch_id;

-- 2) batch header (status should be 'pending_approval')
select id, status, total_cents
  from payout_batches order by created_at desc limit 1;

-- 3) the review sheet — who gets paid and how much (this is what you approve).
--    Shown last so it's the result the SQL editor displays.
select * from payout_batch_summary(
  (select id from payout_batches order by created_at desc limit 1)
);

-- =====================================================================
-- EXPECTED (if your DB = seed data + the single $300 test payment to ghl-opp-003)
-- Per-rep payout (cents):
--   Dana Director  127851
--   Bravo Rep       38500
--   Alpha Rep       16575
--   Charlie Rep     16900
--   Lena Lead        9500
--   Delta Rep        6500
--   Liam Lead        3825
--   Sam State        1912
--   (Echo Rep is EXCLUDED — net 0 after his refund clawback; carried forward)
-- Batch total_cents: 221563   |   status: pending_approval
-- ramp_recipient_id will be NULL for everyone (seed never set it) — that's expected;
-- real reps need a Ramp recipient id before a batch can actually be sent.
-- =====================================================================

-- 4) (optional dry run) approve the batch as the human gate
-- select approve_payout_batch(
--   (select id from payout_batches order by created_at desc limit 1),
--   'michael@forgelocal.app'
-- );

-- 5) (optional) reset — unlinks the rows and clears the batch (only before submit)
-- select cancel_payout_batch(
--   (select id from payout_batches order by created_at desc limit 1)
-- );
