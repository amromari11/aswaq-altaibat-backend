-- Tests for 019_driver_mode.sql (run_local.py reset 008 009 010; 015 and 016 are included below).
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

-- customer C, drivers D and E, customer F
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'customer@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'driver@example.com'),
  ('44444444-4444-4444-4444-444444444444', 'driver2@example.com'),
  ('55555555-5555-5555-5555-555555555555', 'customer2@example.com');
update public.profiles set role = 'driver', full_name = 'Khaled Driver', phone_number = '+962791112233'
 where id = '22222222-2222-2222-2222-222222222222';
update public.profiles set role = 'driver', full_name = 'X', phone_number = '0790000000'
 where id = '44444444-4444-4444-4444-444444444444';

select tst.check('new profiles default to customer, unavailable',
  (select role = 'customer' and not is_available and not paused_for_delivery
     from public.profiles where id = '11111111-1111-1111-1111-111111111111'));
select tst.expect_err('role must be one of the three', $q$update public.profiles set role = 'boss' where id = '11111111-1111-1111-1111-111111111111'$q$,
  'new row for relation "profiles" violates check constraint "profiles_role_valid"');

-- ---- the app can no longer give itself points or a role ----
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select tst.expect_err('a customer cannot raise their own points', $q$update public.profiles set loyalty_points = 999 where id = '11111111-1111-1111-1111-111111111111'$q$,
  'permission denied for table profiles');
select tst.expect_err('a customer cannot make themselves a driver', $q$update public.profiles set role = 'driver' where id = '11111111-1111-1111-1111-111111111111'$q$,
  'permission denied for table profiles');
select tst.expect_err('a customer cannot switch themselves available', $q$update public.profiles set is_available = true where id = '11111111-1111-1111-1111-111111111111'$q$,
  'permission denied for table profiles');
update public.profiles set phone_number = '+962781234567' where id = '11111111-1111-1111-1111-111111111111';
reset role;
select tst.check('...but can still save their phone (what the app does)',
  (select phone_number = '+962781234567' from public.profiles where id = '11111111-1111-1111-1111-111111111111'));

-- ---- orders ----
insert into public.orders (id, user_id, status, subtotal, delivery_fee, discount_amount, total_price, delivery_address, payment_method, loyalty_points_redeemed, customer_name, customer_phone, order_type, driver_id) values
 ('00000000-0000-0000-0000-0000000000a1', '11111111-1111-1111-1111-111111111111', 'confirmed', 10.750, 1.500, 0.500, 11.750, 'Zarqa A', 'cash', 0,  'Customer One', '+962781234567', 'delivery', '22222222-2222-2222-2222-222222222222'),
 ('00000000-0000-0000-0000-0000000000a2', null,                                   'preparing', 4.000,  1.500, 0,     5.500,  'Zarqa B', 'cash', 20, 'Guest Two',    '+962771234567', 'delivery', '22222222-2222-2222-2222-222222222222'),
 ('00000000-0000-0000-0000-0000000000a3', '11111111-1111-1111-1111-111111111111', 'delivered', 3.000,  1.500, 0,     4.500,  'Zarqa C', 'cash', 0,  'Customer One', '+962781234567', 'delivery', '22222222-2222-2222-2222-222222222222'),
 ('00000000-0000-0000-0000-0000000000a4', '55555555-5555-5555-5555-555555555555', 'confirmed', 6.000,  1.500, 0,     7.500,  'Zarqa D', 'cash', 0,  'Customer Two', '+962791234567', 'delivery', '44444444-4444-4444-4444-444444444444'),
 ('00000000-0000-0000-0000-0000000000a5', '11111111-1111-1111-1111-111111111111', 'cancelled', 2.000,  1.500, 0,     3.500,  'Zarqa E', 'cash', 0,  'Customer One', '+962781234567', 'delivery', '22222222-2222-2222-2222-222222222222'),
 ('00000000-0000-0000-0000-0000000000a6', '11111111-1111-1111-1111-111111111111', 'confirmed', 2.000,  0,     0,     2.000,  'Branch',  'cash', 0,  'Customer One', '+962781234567', 'pickup',   '22222222-2222-2222-2222-222222222222');

select tst.expect_err('only a driver can be assigned', $q$update public.orders set driver_id = '11111111-1111-1111-1111-111111111111' where id = '00000000-0000-0000-0000-0000000000a1'$q$,
  'not_a_driver');

-- ---- who may call the driver functions ----
set local role anon;
select tst.expect_err('a guest cannot list driver orders', 'select * from public.driver_assigned_orders()', 'permission denied for function driver_assigned_orders');
select tst.expect_err('a guest cannot toggle availability', 'select public.driver_set_available(true)', 'permission denied for function driver_set_available');
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select tst.expect_err('a customer is not a driver (list)', 'select * from public.driver_assigned_orders()', 'not_a_driver');
select tst.expect_err('a customer is not a driver (toggle)', 'select public.driver_set_available(true)', 'not_a_driver');
select tst.expect_err('a customer cannot deliver', $q$select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000a1')$q$, 'not_a_driver');
select tst.expect_err('require_driver is internal', 'select public.require_driver()', 'permission denied for function require_driver');
reset role;

-- ---- availability toggle ----
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select tst.check('the toggle returns the new state', public.driver_set_available(true));
reset role;
select tst.check('the toggle lands on the profile (what the admin reads)',
  (select is_available and available_changed_at is not null and not paused_for_delivery
     from public.profiles where id = '22222222-2222-2222-2222-222222222222'));

-- ---- my orders ----
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
create temp table mine as select * from public.driver_assigned_orders();
reset role;
select tst.check('the driver sees only their active delivery orders',
  (select array_agg(id order by id) = array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2']::uuid[] from mine),
  (select string_agg(id::text, ',') from mine));
select tst.check('each row carries the customer, address, total and payment details',
  (select customer_name = 'Customer One' and customer_phone = '+962781234567' and delivery_address = 'Zarqa A'
          and total_price = 11.750 and payment_method = 'cash' and loyalty_points_redeemed = 0
     from mine where id = '00000000-0000-0000-0000-0000000000a1'));
select tst.check('points paid on an order are visible', (select loyalty_points_redeemed = 20 from mine where id = '00000000-0000-0000-0000-0000000000a2'));

-- ---- pick up ----
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select tst.expect_err('another driver''s order is not found', $q$select public.driver_pick_up('00000000-0000-0000-0000-0000000000a4')$q$, 'order_not_found');
select tst.expect_err('an unknown order is not found', $q$select public.driver_pick_up('00000000-0000-0000-0000-0000000000ff')$q$, 'order_not_found');
select tst.expect_err('a pickup order cannot be driven', $q$select public.driver_pick_up('00000000-0000-0000-0000-0000000000a6')$q$, 'not_a_delivery');
select tst.expect_err('a delivered order cannot be picked up again', $q$select public.driver_pick_up('00000000-0000-0000-0000-0000000000a3')$q$, 'invalid_status');
select tst.expect_err('cannot deliver before picking up', $q$select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000a1')$q$, 'invalid_status');
select tst.check('picking up returns out_for_delivery', public.driver_pick_up('00000000-0000-0000-0000-0000000000a1') = 'out_for_delivery');
select tst.check('a second tap is harmless', public.driver_pick_up('00000000-0000-0000-0000-0000000000a1') = 'out_for_delivery');
reset role;
select tst.check('the order is out for delivery with the driver on it',
  (select status = 'out_for_delivery' and picked_up_at is not null and driver_name = 'Khaled Driver' and driver_phone = '+962791112233'
     from public.orders where id = '00000000-0000-0000-0000-0000000000a1'));
select tst.check('picking up pauses availability automatically',
  (select not is_available and paused_for_delivery from public.profiles where id = '22222222-2222-2222-2222-222222222222'));

-- a driver whose profile name/phone fail 016's checks still picks up; the fields stay empty
update public.orders set status = 'preparing' where id = '00000000-0000-0000-0000-0000000000a4';
set local role authenticated;
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select public.driver_pick_up('00000000-0000-0000-0000-0000000000a4');
reset role;
select tst.check('invalid profile name/phone are not copied onto the order',
  (select status = 'out_for_delivery' and driver_name is null and driver_phone is null from public.orders where id = '00000000-0000-0000-0000-0000000000a4'));
select tst.check('a driver who was not available stays unavailable and unpaused',
  (select not is_available and not paused_for_delivery from public.profiles where id = '44444444-4444-4444-4444-444444444444'));

-- ---- deliver ----
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
create temp table r1 as select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000a1') as r;
reset role;
select tst.check('points = floor(subtotal - discount) at 1 per JOD (delivery fee excluded)',
  (select (r ->> 'points_awarded')::int = 10 from r1), (select r::text from r1));
select tst.check('the order is delivered and paid',
  (select status = 'delivered' and delivered_at is not null and paid_at is not null and loyalty_points_earned = 10
     from public.orders where id = '00000000-0000-0000-0000-0000000000a1'));
select tst.check('the customer received the points', (select loyalty_points = 10 from public.profiles where id = '11111111-1111-1111-1111-111111111111'));
select tst.check('still one active order: availability stays paused',
  (select not is_available and paused_for_delivery from public.profiles where id = '22222222-2222-2222-2222-222222222222'));

set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
create temp table r2 as select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000a1') as r;
reset role;
select tst.check('delivering twice is harmless and awards nothing',
  (select (r ->> 'already_delivered')::boolean and (r ->> 'points_awarded')::int = 0 from r2)
  and (select loyalty_points = 10 from public.profiles where id = '11111111-1111-1111-1111-111111111111'));

-- the guest order: no points, and it is the last one, so availability comes back
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.driver_pick_up('00000000-0000-0000-0000-0000000000a2');
create temp table r3 as select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000a2') as r;
reset role;
select tst.check('a guest order awards no points', (select (r ->> 'points_awarded')::int = 0 from r3));
select tst.check('last order delivered: availability switches back on',
  (select is_available and not paused_for_delivery from public.profiles where id = '22222222-2222-2222-2222-222222222222')
  and (select (r ->> 'available')::boolean from r3));

-- a driver who switched off by hand is not switched back on
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.driver_set_available(false);
reset role;
insert into public.orders (id, user_id, status, subtotal, total_price, delivery_address, order_type, driver_id) values
 ('00000000-0000-0000-0000-0000000000a7', '11111111-1111-1111-1111-111111111111', 'confirmed', 3.999, 3.999, 'Zarqa F', 'delivery', '22222222-2222-2222-2222-222222222222');
update public.store_settings set points_per_jod = 2;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.driver_pick_up('00000000-0000-0000-0000-0000000000a7');
create temp table r4 as select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000a7') as r;
reset role;
select tst.check('the store rate is applied (3.999 JOD x 2 = 7 points)', (select (r ->> 'points_awarded')::int = 7 from r4));
select tst.check('a manual "off" is respected after the last delivery',
  (select not is_available and not paused_for_delivery from public.profiles where id = '22222222-2222-2222-2222-222222222222'));

-- ---- the rest of the app is untouched ----
select tst.check('the driver ping trigger is installed', (select count(*) = 1 from pg_trigger where tgname = 'trg_orders_broadcast_driver'));
select tst.check('the customer status broadcast is still installed', (select count(*) = 1 from pg_trigger where tgname = 'trg_orders_broadcast_status'));
set local role authenticated;
set local request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
create temp table seen as select id from public.orders;
reset role;
select tst.check('a customer still sees only their own orders',
  (select array_agg(id) = array['00000000-0000-0000-0000-0000000000a4']::uuid[] from seen), (select string_agg(id::text, ',') from seen));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
