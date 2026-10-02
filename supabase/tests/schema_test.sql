-- Behavioural tests for the init migration. Run with supabase/tests/run.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema test;
grant usage on schema test to authenticated;

create function test.expect_error(p_sql text, p_label text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'ok   % (rejected: %)', p_label, sqlerrm;
    return;
  end;
  raise exception 'FAIL % : expected an error', p_label;
end;
$$;

create function test.expect_eq(p_actual numeric, p_expected numeric, p_label text) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL % : expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'ok   %', p_label;
end;
$$;

create function test.on_hand(p_name text) returns numeric language sql as $$
  select on_hand from public.v_on_hand where name = p_name
$$;

grant execute on all functions in schema test to authenticated;

-- Users
insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', '{"full_name": "Manager"}'),
  ('00000000-0000-0000-0000-00000000000b', '{"full_name": "GM"}');
update public.profiles set role = 'manager' where id = '00000000-0000-0000-0000-00000000000a';

select test.expect_eq((select count(*) from public.profiles), 2, 'profiles created by auth trigger');

-- ------------------------------------------------------------------ viewer
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';

select test.expect_eq((select count(*) from public.items), 11, 'viewer can read items');
select test.expect_eq((select count(*) from public.profiles), 1, 'viewer sees only own profile');
select test.expect_error($$insert into public.inventory_transactions (item_id, type, qty_delta, reason, created_by)
  select id, 'waste', -1, 'x', auth.uid() from public.items limit 1$$, 'viewer cannot write ledger');
update public.items set par_level = 1;
select test.expect_eq((select count(*) from public.items where par_level = 1), 0, 'viewer update is a no-op under RLS');
select test.expect_error($$select public.submit_count(1)$$, 'viewer cannot submit counts');

-- ------------------------------------------------------------------ manager: manual entries
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';

select test.expect_eq(test.on_hand('Tito''s Vodka 1L'), 8, 'opening balance');

insert into public.inventory_transactions (item_id, type, qty_delta, reason)
select id, 'waste', -1, 'dropped bottle' from public.items where name = 'Tito''s Vodka 1L';
select test.expect_eq(test.on_hand('Tito''s Vodka 1L'), 7, 'waste reduces on-hand');

select test.expect_error($$insert into public.inventory_transactions (item_id, type, qty_delta)
  select id, 'waste', -1 from public.items limit 1$$, 'manual entry requires a reason');
select test.expect_error($$insert into public.inventory_transactions (item_id, type, qty_delta, reason, count_id)
  select id, 'count_correction', -1, 'x', null from public.items limit 1$$, 'cannot write count_correction directly');
delete from public.inventory_transactions;
select test.expect_eq((select count(*) from public.inventory_transactions), 12, 'manager delete is a no-op under RLS');
reset role;  -- the trigger also stops privileged roles (service_role, dashboard)
select test.expect_error($$update public.inventory_transactions set qty_delta = 5$$, 'ledger is immutable (update)');
select test.expect_error($$delete from public.inventory_transactions$$, 'ledger is immutable (delete)');
set role authenticated;

-- ------------------------------------------------------------------ manager: purchase order
insert into public.purchase_orders (vendor_id, status, placed_at, expected_at)
select id, 'placed', now(), current_date + 2 from public.vendors where name = 'Southern Glazer''s';

insert into public.po_lines (po_id, item_id, qty_ordered, unit_cost)
select (select max(id) from public.purchase_orders), id, 2, 270.00
from public.items where name = 'Tito''s Vodka 1L';

select test.expect_eq((select units_per_order_unit from public.po_lines order by id desc limit 1), 12,
  'po_line snapshots units_per_order_unit');

select test.expect_error(format($$select public.receive_purchase_order(%s, '[{"po_line_id": 999999, "qty": 1}]')$$,
  (select max(id) from public.purchase_orders)), 'receive rejects foreign po_line');

select public.receive_purchase_order(
  (select max(id) from public.purchase_orders),
  jsonb_build_array(jsonb_build_object('po_line_id', (select max(id) from public.po_lines), 'qty', 1))
) \gset recv_
select test.expect_eq(test.on_hand('Tito''s Vodka 1L'), 19, 'receiving 1 case adds 12 bottles');
select test.expect_eq((select case status when 'partially_received' then 1 else 0 end
  from public.purchase_orders order by id desc limit 1), 1, 'PO partially received');
select test.expect_eq((select unit_cost from public.items where name = 'Tito''s Vodka 1L'), 22.5,
  'item unit_cost updated from receipt ($270/12)');

select public.receive_purchase_order(
  (select max(id) from public.purchase_orders),
  jsonb_build_array(jsonb_build_object('po_line_id', (select max(id) from public.po_lines), 'qty', 1))
) \gset recv_
select test.expect_eq((select case status when 'received' then 1 else 0 end
  from public.purchase_orders order by id desc limit 1), 1, 'PO fully received');
select test.expect_eq((select count(*) from public.v_price_history), 2, 'price history from receipts');

-- Reverse the last receipt
select public.reverse_transaction(
  (select max(id) from public.inventory_transactions where type = 'receipt'), 'wrong case scanned'
) \gset rev_
select test.expect_eq(test.on_hand('Tito''s Vodka 1L'), 19, 'reversal removes receipt');
select test.expect_eq((select case status when 'partially_received' then 1 else 0 end
  from public.purchase_orders order by id desc limit 1), 1, 'PO back to partially received');
select test.expect_eq((select count(*) from public.v_price_history), 1, 'reversed receipt leaves price history');
select test.expect_error(format('select public.reverse_transaction(%s, %L)',
  (select max(id) from public.inventory_transactions where type = 'receipt'), 'again'), 'cannot reverse twice');

-- ------------------------------------------------------------------ manager: count
insert into public.counts default values;
insert into public.count_lines (count_id, item_id, quantity)
select (select max(id) from public.counts), id,
       case name when 'Tito''s Vodka 1L' then 15 when 'Coors Light 12oz can' then 144 else 0 end
from public.items where name in ('Tito''s Vodka 1L', 'Coors Light 12oz can', 'Hot dogs 1/4lb');

select test.expect_eq(public.submit_count((select max(id) from public.counts)), 2,
  'submit writes corrections only where counted <> expected');
select test.expect_eq(test.on_hand('Tito''s Vodka 1L'), 15, 'on-hand matches count after submit');
select test.expect_eq(test.on_hand('Hot dogs 1/4lb'), 0, 'zero count zeroes on-hand');
select test.expect_eq((select expected_qty from public.count_lines cl join public.items i on i.id = cl.item_id
  where i.name = 'Tito''s Vodka 1L'), 19, 'expected_qty recorded');

select test.expect_error(format('select public.submit_count(%s)', (select max(id) from public.counts)),
  'cannot submit twice');
select test.expect_error(format($$insert into public.count_lines (count_id, item_id, quantity)
  select %s, id, 1 from public.items where name = 'Brioche buns'$$, (select max(id) from public.counts)),
  'cannot edit a submitted count');

-- Usage: Tito's lost 1 (waste) + 4 (count correction) = 5 bottles; hot dogs 80
select test.expect_eq((select usage_qty from public.v_usage_by_count u join public.items i on i.id = u.item_id
  where i.name = 'Tito''s Vodka 1L'), 5, 'usage = waste + unexplained loss');
select test.expect_eq((select usage_qty from public.v_usage_by_count u join public.items i on i.id = u.item_id
  where i.name = 'Hot dogs 1/4lb'), 80, 'usage for zeroed item');

reset role;
\echo 'ALL TESTS PASSED'
