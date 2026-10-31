-- Tests for 015_order_type_schedule.sql (run_local.py reset 008 009 010).
-- Run via run_local.py `test`: one rolled-back transaction, one PASS/FAIL line per check.
-- helpers below call the 12-argument place_order, which only exists after the include
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

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','g@example.com');
insert into public.categories (id, name, name_ar) values ('cccccccc-cccc-cccc-cccc-cccccccccccc','Dairy','Dairy-ar');
insert into public.products (id, category_id, name, name_ar, unit, price, discount_price, sku) values
 ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Milk','Milk-ar','1L', 2.500, null,'S1'),
 ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Cheese','Cheese-ar',null, 4.000, 3.250,'S2'),
 ('aaaaaaaa-0000-0000-0000-000000000004','cccccccc-cccc-cccc-cccc-cccccccccccc','Big','Big-ar',null, 25.000, null,'S4');

create function tst.zone(n text) returns uuid language sql as $$ select id from public.delivery_zones where name_en = n $$;
create sequence tst.ph;
grant usage on sequence tst.ph to anon, authenticated;
-- a fresh phone per order, so the 5-orders-per-hour guard never trips
create function tst.phone() returns text language sql as $$ select '+96279' || lpad(nextval('tst.ph')::text, 7, '0') $$;
-- Amman local wall-clock time -> timestamptz
create function tst.amman(ts timestamp) returns timestamptz language sql as $$ select ts at time zone 'Asia/Amman' $$;
create function tst.local_now() returns timestamp language sql as $$ select now() at time zone 'Asia/Amman' $$;
-- 2 Milk + 1 Cheese = 8.250 (zone Beta: min 7, fee 1.5)
create function tst.items(big boolean default false) returns jsonb language sql as $$
  select case when big then '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]'::jsonb
              else '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2},{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":1}]'::jsonb end $$;
create function tst.one_milk() returns jsonb language sql as $$ select '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]'::jsonb $$;
create function tst.pickup(sched timestamptz default null, items jsonb default null) returns uuid language sql as $$
  select public.place_order('Pick Up', tst.phone(), coalesce(items, tst.items()), null, null, null, null, null, null, gen_random_uuid(), 'pickup', sched) $$;
create function tst.delivery(sched timestamptz default null, items jsonb default null, zone uuid default null, addr text default 'Street 1') returns uuid language sql as $$
  select public.place_order('Deli Very', tst.phone(), coalesce(items, tst.items()), addr, coalesce(zone, tst.zone('Beta')), null, 32.0, 36.0, null, gen_random_uuid(), 'delivery', sched) $$;
grant execute on all functions in schema tst to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
create table tst.o (k text, id uuid);
grant all on tst.o to anon, authenticated, service_role;

-- @include 015_order_type_schedule.sql

select tst.check('one store_settings row, seeded with the Zarqa branch',
  (select count(*) = 1 from public.store_settings)
  and (select branch_name_ar = U&'\0623\0633\0648\0627\0642 \0627\0644\0637\064A\0628\0627\062A - \0641\0631\0639 \0627\0644\0632\0631\0642\0627\0621' and latitude = 32.073313 and longitude = 36.095312
          and opens_at = '08:00' and closes_at = '23:00' and pickup_enabled and scheduling_enabled
          and slot_minutes = 60 and min_lead_minutes = 60 and max_days_ahead = 2 from public.store_settings));
select tst.expect_err('a second settings row is impossible', $q$insert into public.store_settings (id, branch_name_ar, branch_address_ar, latitude, longitude, opens_at, closes_at) values (false,'x','x',0,0,'08:00','09:00')$q$,
  'new row for relation "store_settings" violates check constraint "store_settings_id_check"');
select tst.expect_err('closing before opening is refused', $q$update public.store_settings set closes_at = '07:00'$q$,
  'new row for relation "store_settings" violates check constraint "store_settings_hours"');
select tst.check('only one place_order exists (12 arguments)', (select count(*) = 1 and max(pronargs) = 12 from pg_proc where proname = 'place_order'));

-- open around the clock for the "now" tests
update public.store_settings set opens_at = '00:00', closes_at = '24:00';

-- ===== as the app (anon) =====
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select tst.check('anon can read the store settings', (select count(*) = 1 from public.store_settings));
select tst.expect_err('anon cannot change the store settings', $q$update public.store_settings set opens_at = '01:00'$q$, 'permission denied for table store_settings');
insert into tst.o select 'old', public.place_order('Old Build', tst.phone(), tst.items(), 'Street 9', tst.zone('Beta'), null, 32.1, 36.1, 'n', gen_random_uuid());
insert into tst.o select 'deliv_now', tst.delivery();
insert into tst.o select 'pick_now', tst.pickup();
insert into tst.o select 'pick_small', tst.pickup(null, tst.one_milk());
insert into tst.o select 'pick_with_addr', public.place_order('Pick Up', tst.phone(), tst.items(), 'Ignored street', tst.zone('Beta'), null, 31.0, 35.0, null, gen_random_uuid(), 'pickup', null);
insert into tst.o select 'deliv_free', tst.delivery(null, tst.items(true));
insert into tst.o select 'deliv_later', tst.delivery(tst.amman(date_trunc('hour', tst.local_now()) + interval '3 hours'));
insert into tst.o select 'pick_later', tst.pickup(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 10 hours'));
select tst.expect_err('unknown order type', $q$select public.place_order('X Y', tst.phone(), tst.items(), null, null, null, null, null, null, null, 'drone', null)$q$, 'invalid_order_type');
select tst.expect_err('delivery still needs an address', $q$select tst.delivery(null, null, null, '')$q$, 'invalid_address');
select tst.expect_err('delivery still needs a zone', $q$select public.place_order('X Y', tst.phone(), tst.items(), 'Street', null, null, null, null, null, null, 'delivery', null)$q$, 'invalid_zone');
select tst.expect_err('delivery still has a minimum order', $q$select tst.delivery(null, tst.one_milk())$q$, 'below_minimum');
select tst.expect_err('a slot that has already started is refused', $q$select tst.delivery(tst.amman(date_trunc('hour', tst.local_now())))$q$, 'invalid_schedule');
select tst.expect_err('a slot too soon (inside the lead time) is refused', $q$select tst.delivery(tst.amman(date_trunc('hour', tst.local_now()) + interval '1 hour') - interval '30 minutes')$q$, 'invalid_schedule');
select tst.expect_err('a slot off the slot boundary is refused', $q$select tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 10 hours 30 minutes'))$q$, 'invalid_schedule');
select tst.expect_err('a slot with seconds is refused', $q$select tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 10 hours 5 seconds'))$q$, 'invalid_schedule');
select tst.expect_err('a slot beyond max_days_ahead is refused', $q$select tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '3 days 10 hours'))$q$, 'invalid_schedule');
select tst.expect_err('a slot in the past is refused', $q$select tst.delivery(now() - interval '1 day')$q$, 'invalid_schedule');
reset role;

select tst.check('an old app build (10 arguments) still places a delivery-now order',
  (select order_type = 'delivery' and scheduled_time is null and delivery_fee = 1.5 and delivery_address = 'Street 9' from public.orders where id = (select id from tst.o where k = 'old')));
select tst.check('delivery now: fee from the zone, total = subtotal + fee',
  (select order_type = 'delivery' and subtotal = 8.25 and delivery_fee = 1.5 and total_price = 9.75 and zone_id is not null from public.orders where id = (select id from tst.o where k = 'deliv_now')));
select tst.check('delivery over 20 JOD is still free',
  (select delivery_fee = 0 and total_price = subtotal from public.orders where id = (select id from tst.o where k = 'deliv_free')));
select tst.check('pickup: no fee, no address, no zone, no pin',
  (select order_type = 'pickup' and delivery_fee = 0 and total_price = subtotal and delivery_address is null
          and zone_id is null and delivery_lat is null and delivery_lng is null and address_id is null
     from public.orders where id = (select id from tst.o where k = 'pick_now')));
select tst.check('pickup has no minimum order', (select subtotal = 2.5 from public.orders where id = (select id from tst.o where k = 'pick_small')));
select tst.check('pickup ignores an address/zone/pin the app sent anyway',
  (select delivery_address is null and zone_id is null and delivery_lat is null and delivery_fee = 0 from public.orders where id = (select id from tst.o where k = 'pick_with_addr')));
select tst.check('a scheduled delivery keeps its slot',
  (select scheduled_time = tst.amman(date_trunc('hour', tst.local_now()) + interval '3 hours') and delivery_fee = 1.5 from public.orders where id = (select id from tst.o where k = 'deliv_later')));
select tst.check('a scheduled pickup keeps its slot',
  (select scheduled_time = tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 10 hours') and order_type = 'pickup' from public.orders where id = (select id from tst.o where k = 'pick_later')));
select tst.expect_err('the table itself refuses a delivery order without an address',
  $q$update public.orders set delivery_address = null where id = (select id from tst.o where k = 'deliv_now')$q$,
  'new row for relation "orders" violates check constraint "orders_delivery_has_address"');
select tst.expect_err('the table itself refuses an unknown order type',
  $q$update public.orders set order_type = 'drone' where id = (select id from tst.o where k = 'deliv_now')$q$,
  'new row for relation "orders" violates check constraint "orders_order_type_check"');

-- ===== opening hours 08:00-23:00 =====
update public.store_settings set opens_at = '08:00', closes_at = '23:00';
set local role anon;
insert into tst.o select 'first_slot', tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 8 hours'));
insert into tst.o select 'last_slot', tst.pickup(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 22 hours'));
select tst.expect_err('a slot before opening is refused', $q$select tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 7 hours'))$q$, 'invalid_schedule');
select tst.expect_err('a slot that would end after closing is refused', $q$select tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 23 hours'))$q$, 'invalid_schedule');
reset role;
select tst.check('the first (08:00) and last (22:00-23:00) slots of tomorrow are accepted',
  (select count(*) = 2 from public.orders where id in (select id from tst.o where k in ('first_slot', 'last_slot'))));

-- 30-minute slots: 22:30 becomes a real slot
update public.store_settings set slot_minutes = 30;
set local role anon;
insert into tst.o select 'half_slot', tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 22 hours 30 minutes'));
reset role;
select tst.check('with 30-minute slots, 22:30 is accepted', (select count(*) = 1 from tst.o where k = 'half_slot'));
update public.store_settings set slot_minutes = 60;

-- closed right now (an hour that never contains the current time)
update public.store_settings
   set opens_at  = case when extract(hour from tst.local_now()) < 12 then '13:00'::time else '01:00'::time end,
       closes_at = case when extract(hour from tst.local_now()) < 12 then '14:00'::time else '02:00'::time end;
set local role anon;
select tst.expect_err('ordering "now" while the store is closed is refused', $q$select tst.delivery()$q$, 'store_closed');
select tst.expect_err('...also for pickup', $q$select tst.pickup()$q$, 'store_closed');
insert into tst.o select 'closed_but_scheduled', tst.pickup(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day' + (select opens_at from public.store_settings)::interval));
reset role;
select tst.check('while closed, a slot in tomorrow''s opening hours still works', (select count(*) = 1 from tst.o where k = 'closed_but_scheduled' and id is not null));

-- switches
update public.store_settings set opens_at = '00:00', closes_at = '24:00', pickup_enabled = false, scheduling_enabled = false;
set local role anon;
select tst.expect_err('pickup switched off', $q$select tst.pickup()$q$, 'pickup_unavailable');
select tst.expect_err('scheduling switched off', $q$select tst.delivery(tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 10 hours'))$q$, 'scheduling_unavailable');
insert into tst.o select 'switches_off_now', tst.delivery();
reset role;
select tst.check('with both switched off, delivery now still works', (select count(*) = 1 from tst.o where k = 'switches_off_now'));

-- ===== tracking / list / driver =====
set local role anon;
create temp table trk as
  select public.get_order_tracking(o.id, o.tracking_token) as j, t.k
    from tst.o t join public.orders o on o.id = t.id where false;
reset role;
insert into trk select public.get_order_tracking(o.id, o.tracking_token), t.k from tst.o t join public.orders o on o.id = t.id where t.k in ('pick_later', 'deliv_now');
select tst.check('tracking says pickup and the slot',
  (select j ->> 'order_type' = 'pickup' and (j ->> 'scheduled_time')::timestamptz = tst.amman(date_trunc('day', tst.local_now()) + interval '1 day 10 hours') from trk where k = 'pick_later'));
select tst.check('tracking says delivery, no slot', (select j ->> 'order_type' = 'delivery' and j -> 'scheduled_time' = 'null'::jsonb from trk where k = 'deliv_now'));
select tst.check('the orders list carries type and slot',
  (select bool_and(s.order_type is not null) and count(*) filter (where s.order_type = 'pickup' and s.scheduled_time is not null) = 1
     from public.list_orders_summary((select jsonb_agg(jsonb_build_object('id', o.id, 'token', o.tracking_token)) from public.orders o
                                       where o.id in (select id from tst.o where k in ('pick_later', 'deliv_now')))) s));

update public.orders set status = 'out_for_delivery' where id in (select id from tst.o where k in ('pick_now', 'deliv_now'));
set local role service_role;
select tst.expect_err('no driver location for a pickup order', $q$select public.set_driver_location((select id from tst.o where k = 'pick_now'), 32.07, 36.09)$q$, 'pickup_order');
select public.set_driver_location((select id from tst.o where k = 'deliv_now'), 32.07, 36.09);
reset role;
select tst.check('a delivery order still takes a driver location', (select count(*) = 1 from public.order_driver_locations where order_id = (select id from tst.o where k = 'deliv_now')));
set local role anon;
select tst.expect_err('the app still cannot move a driver', $q$select public.set_driver_location((select id from tst.o where k = 'deliv_now'), 1, 1)$q$, 'permission denied for function set_driver_location');
reset role;

-- re-running keeps settings someone changed and does not duplicate anything
update public.store_settings set opens_at = '09:00', closes_at = '21:00', branch_phone = '0790000000';
-- @include 015_order_type_schedule.sql
select tst.check('re-run: settings edited from the dashboard are kept',
  (select opens_at = '09:00' and closes_at = '21:00' and branch_phone = '0790000000' and count(*) over () = 1 from public.store_settings));
select tst.check('re-run: still exactly one place_order', (select count(*) = 1 from pg_proc where proname = 'place_order'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
