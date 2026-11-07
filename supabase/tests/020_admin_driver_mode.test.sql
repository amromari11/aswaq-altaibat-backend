-- Tests for 020_admin_driver_mode.sql (run_local.py reset 008 009 010; 015, 016 and 019 are included below).
-- Run via run_local.py `test`: one rolled-back transaction, one PASS/FAIL line per check.
set local check_function_bodies = off;
create schema tst; grant usage on schema tst to anon, authenticated, service_role;
create table tst.log (ok boolean, name text, detail text);
grant all on tst.log to anon, authenticated, service_role;
create function tst.check(n text, cond boolean, d text default '') returns void language plpgsql as $$
begin insert into tst.log values (coalesce(cond,false), n, d); end $$;
create function tst.expect_err(n text, q text, code text) returns void language plpgsql as $$
declare m text;
begin
  begin execute q; m := 'NO ERROR'; exception when others then m := sqlerrm; end;
  insert into tst.log values (m = code, n, 'wanted ' || code || ' got ' || m);
end $$;
grant execute on all functions in schema tst to anon, authenticated, service_role;

-- @include 015_order_type_schedule.sql
-- @include 016_best_sellers_driver_info.sql
-- @include 019_driver_mode.sql
-- @include 020_admin_driver_mode.sql

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'customer@example.com'),
  ('66666666-6666-6666-6666-666666666666', 'admin@example.com');
update public.profiles set role = 'admin', full_name = 'Store Admin', phone_number = '+962795556666'
 where id = '66666666-6666-6666-6666-666666666666';

insert into public.orders (id, user_id, status, subtotal, total_price, delivery_address, order_type) values
 ('00000000-0000-0000-0000-0000000000b1', '11111111-1111-1111-1111-111111111111', 'confirmed', 5.000, 6.500, 'Zarqa', 'delivery');

-- ---- an admin can be assigned and drive an order ----
update public.orders set driver_id = '66666666-6666-6666-6666-666666666666' where id = '00000000-0000-0000-0000-0000000000b1';
select tst.check('an admin can be assigned an order',
  (select driver_id = '66666666-6666-6666-6666-666666666666' from public.orders where id = '00000000-0000-0000-0000-0000000000b1'));
select tst.expect_err('a customer still cannot be assigned', $q$update public.orders set driver_id = '11111111-1111-1111-1111-111111111111' where id = '00000000-0000-0000-0000-0000000000b1'$q$, 'not_a_driver');

set local role authenticated;
set local request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select tst.check('an admin can switch availability', public.driver_set_available(true));
create temp table admin_list as select * from public.driver_assigned_orders();
select tst.check('an admin sees the orders assigned to them', (select count(*) = 1 from admin_list));
select tst.check('an admin can pick up', public.driver_pick_up('00000000-0000-0000-0000-0000000000b1') = 'out_for_delivery');
create temp table admin_done as select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000b1') as r;
reset role;
select tst.check('an admin delivery awards the customer points', (select (r ->> 'points_awarded')::int = 5 from admin_done)
  and (select loyalty_points = 5 from public.profiles where id = '11111111-1111-1111-1111-111111111111'));

-- ---- customers are still refused, and require_driver stays internal ----
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select tst.expect_err('a customer is still not a driver', 'select * from public.driver_assigned_orders()', 'not_a_driver');
select tst.expect_err('require_driver is still internal', 'select public.require_driver()', 'permission denied for function require_driver');
reset role;
set local role anon;
select tst.expect_err('a guest still cannot call driver functions', 'select public.driver_set_available(true)', 'permission denied for function driver_set_available');
reset role;

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
