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
