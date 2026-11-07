-- Tests for 022_driver_live_location.sql (run_local.py reset 008 009 010; 015, 016, 019, 020, 021 are included below).
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
-- @include 021_driver_vehicle.sql
-- @include 022_driver_live_location.sql

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'customer@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'driver@example.com'),
  ('44444444-4444-4444-4444-444444444444', 'driver2@example.com');
update public.profiles set role = 'driver' where id in ('22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444');

insert into public.orders (id, user_id, status, subtotal, total_price, delivery_address, order_type, driver_id, tracking_token) values
 ('00000000-0000-0000-0000-0000000000d1', '11111111-1111-1111-1111-111111111111', 'confirmed', 5, 6.5, 'Zarqa', 'delivery',
  '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-0000000000d1');

set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select tst.expect_err('no position before pick-up', $q$select public.driver_update_location('00000000-0000-0000-0000-0000000000d1', 32.07, 36.09)$q$, 'not_out_for_delivery');
select public.driver_pick_up('00000000-0000-0000-0000-0000000000d1');
select public.driver_update_location('00000000-0000-0000-0000-0000000000d1', 32.0712345, 36.0956789);
select tst.expect_err('a nonsense position is refused', $q$select public.driver_update_location('00000000-0000-0000-0000-0000000000d1', 132, 36)$q$, 'invalid_location');
reset role;

select tst.check('the position is stored (rounded to 6 places)',
  (select latitude = 32.071235 and longitude = 36.095679 from public.order_driver_locations where order_id = '00000000-0000-0000-0000-0000000000d1'));

set local role anon;
select tst.check('the customer''s tracking shows it',
  (select (public.get_order_tracking('00000000-0000-0000-0000-0000000000d1', 'aaaaaaaa-0000-0000-0000-0000000000d1') -> 'driver' ->> 'latitude')::numeric = 32.071235));
select tst.expect_err('a guest cannot move a driver', $q$select public.driver_update_location('00000000-0000-0000-0000-0000000000d1', 32, 36)$q$, 'permission denied for function driver_update_location');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select tst.expect_err('another driver cannot move this order', $q$select public.driver_update_location('00000000-0000-0000-0000-0000000000d1', 32, 36)$q$, 'order_not_found');
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select tst.expect_err('a customer cannot move a driver', $q$select public.driver_update_location('00000000-0000-0000-0000-0000000000d1', 32, 36)$q$, 'not_a_driver');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000d1');
select tst.expect_err('no position after delivery', $q$select public.driver_update_location('00000000-0000-0000-0000-0000000000d1', 32, 36)$q$, 'not_out_for_delivery');
reset role;
select tst.check('the position is wiped once delivered (010)',
  (select count(*) = 0 from public.order_driver_locations where order_id = '00000000-0000-0000-0000-0000000000d1'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
