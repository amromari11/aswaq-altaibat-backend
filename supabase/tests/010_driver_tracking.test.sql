-- Tests for 010_driver_tracking.sql (apply 008, 009, 010 first: run_local.py reset 008 009 010).
-- Run via run_local.py `test`: one rolled-back transaction, one PASS/FAIL line per check.
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

insert into public.categories (id, name, name_ar) values ('cccccccc-cccc-cccc-cccc-cccccccccccc','Dairy','Dairy-ar');
insert into public.products (id, category_id, name, name_ar, price, sku) values
 ('aaaaaaaa-0000-0000-0000-000000000004','cccccccc-cccc-cccc-cccc-cccccccccccc','Big','Big-ar', 25.000,'S4');
create function tst.zone(n text) returns uuid language sql as $$ select id from public.delivery_zones where name_en = n $$;
create function tst.place(tok uuid, phone text, lat numeric default 32.100000, lng numeric default 36.200000)
returns uuid language sql as $$
  select public.place_order('Tester', phone,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]'::jsonb,
    'Street 1', tst.zone('Beta'), null, lat, lng, null, tok) $$;
grant execute on function tst.zone(text), tst.place(uuid,text,numeric,numeric) to anon, authenticated;
grant all on all tables in schema public to service_role;

create table tst.o (k text, id uuid, tok uuid);
grant all on tst.o to anon, authenticated, service_role;
set local role anon;
insert into tst.o select 'a', i, 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa' from (select tst.place('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '+962791234567') i) x;
insert into tst.o select 'b', i, 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb' from (select tst.place('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', '+962771112222', null, null) i) x;
reset role;

create function tst.trk(k text) returns jsonb language sql as
  $$ select public.get_order_tracking((select id from tst.o where tst.o.k = $1), (select tok from tst.o where tst.o.k = $1)) $$;

-- ===== the delivery pin is part of tracking =====
select tst.check('tracking returns the delivery pin',
  (select (j ->> 'delivery_lat')::numeric = 32.1 and (j ->> 'delivery_lng')::numeric = 36.2 from (select tst.trk('a') j) s));
select tst.check('an order placed without a map pin has null coordinates (the app then shows only the store)',
  (select j -> 'delivery_lat' = 'null'::jsonb and j -> 'delivery_lng' = 'null'::jsonb from (select tst.trk('b') j) s));
select tst.check('no driver before the order is out for delivery',
  (select j -> 'driver' = 'null'::jsonb from (select tst.trk('a') j) s));

-- ===== moving the driver: rules =====
set local role service_role;
select tst.expect_err('cannot place a driver on an order that is not out for delivery',
  $q$select public.set_driver_location((select id from tst.o where k='a'), 32.0, 36.0)$q$, 'not_out_for_delivery');
reset role;
update public.orders set status = 'out_for_delivery' where id = (select id from tst.o where k='a');

set local role service_role;
select tst.expect_err('latitude out of range', $q$select public.set_driver_location((select id from tst.o where k='a'), 91, 36.0)$q$, 'invalid_location');
select tst.expect_err('longitude out of range', $q$select public.set_driver_location((select id from tst.o where k='a'), 32.0, 181)$q$, 'invalid_location');
select tst.expect_err('missing coordinates', $q$select public.set_driver_location((select id from tst.o where k='a'), null, 36.0)$q$, 'invalid_location');
select tst.expect_err('unknown order', $q$select public.set_driver_location(gen_random_uuid(), 32.0, 36.0)$q$, 'order_not_found');
select public.set_driver_location((select id from tst.o where k='a'), 32.0123456789, 36.0987654321);
reset role;

select tst.check('driver position is stored rounded to 6 decimals',
  (select latitude = 32.012346 and longitude = 36.098765 from public.order_driver_locations where order_id = (select id from tst.o where k='a')));
select tst.check('the customer sees the driver while the order is out for delivery',
  (select (j -> 'driver' ->> 'latitude')::numeric = 32.012346 and (j -> 'driver' ->> 'longitude')::numeric = 36.098765
      and (j -> 'driver' ->> 'updated_at') is not null from (select tst.trk('a') j) s),
  (select (tst.trk('a') -> 'driver')::text));

set local role service_role;
select public.set_driver_location((select id from tst.o where k='a'), 32.05, 36.15);
reset role;
select tst.check('moving the driver again updates the single row (no duplicates)',
  (select count(*) = 1 and bool_and(latitude = 32.05 and longitude = 36.15) from public.order_driver_locations));

select tst.check('another order''s tracking never shows this driver',
  (select j -> 'driver' = 'null'::jsonb from (select tst.trk('b') j) s));
select tst.check('a wrong token does not reveal the driver (the whole answer is null)',
  public.get_order_tracking((select id from tst.o where k='a'), 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb') is null);

-- ===== who may move the driver / read the table =====
set local role anon;
select tst.expect_err('a guest cannot move a driver', $q$select public.set_driver_location((select id from tst.o where k='a'), 1, 1)$q$, 'permission denied for function set_driver_location');
select tst.expect_err('a guest cannot read driver positions directly', $q$select * from public.order_driver_locations$q$, 'permission denied for table order_driver_locations');
reset role;
set local role authenticated;
select tst.expect_err('a signed-in customer cannot move a driver either', $q$select public.set_driver_location((select id from tst.o where k='a'), 1, 1)$q$, 'permission denied for function set_driver_location');
reset role;

-- ===== realtime: driver broadcasts =====
-- (1) realtime missing: moving the driver still works
set local role service_role;
select public.set_driver_location((select id from tst.o where k='a'), 32.06, 36.16);
reset role;
select tst.check('moving the driver works even when realtime.send does not exist',
  (select latitude = 32.06 from public.order_driver_locations where order_id = (select id from tst.o where k='a')));

-- (2) realtime available
create schema realtime;
create table tst.sent (payload jsonb, event text, topic text, private boolean);
create function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
  language sql as $$ insert into tst.sent values (payload, event, topic, private) $$;
set local role service_role;
select public.set_driver_location((select id from tst.o where k='a'), 32.07, 36.17);
reset role;
select tst.check('a position update broadcasts once on order:<token>, event "driver", public channel',
  (select count(*) = 1 and bool_and(event = 'driver' and topic = 'order:aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa' and private = false) from tst.sent));
select tst.check('driver broadcast carries the order id and coordinates',
  (select (payload ->> 'latitude')::numeric = 32.07 and (payload ->> 'longitude')::numeric = 36.17
      and payload ->> 'order_id' = (select id::text from tst.o where k='a') and payload ->> 'updated_at' is not null from tst.sent));

-- (3) realtime raising must not block the admin
create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
  language plpgsql as $$ begin raise exception 'realtime is down'; end $$;
set local role service_role;
select public.set_driver_location((select id from tst.o where k='a'), 32.08, 36.18);
reset role;
select tst.check('moving the driver works even when realtime.send raises',
  (select latitude = 32.08 from public.order_driver_locations where order_id = (select id from tst.o where k='a')));

-- ===== cleanup: the position lives only while out for delivery =====
update public.orders set notes = 'edit while out for delivery' where id = (select id from tst.o where k='a');
select tst.check('editing something other than the status keeps the driver position',
  (select count(*) = 1 from public.order_driver_locations));
update public.orders set status = 'delivered' where id = (select id from tst.o where k='a');
select tst.check('delivering the order deletes the driver position', (select count(*) = 0 from public.order_driver_locations));
select tst.check('and tracking no longer exposes any driver', (select j -> 'driver' = 'null'::jsonb from (select tst.trk('a') j) s));

update public.orders set status = 'out_for_delivery' where id = (select id from tst.o where k='a');
set local role service_role;
select public.set_driver_location((select id from tst.o where k='a'), 32.09, 36.19);
reset role;
update public.orders set status = 'cancelled' where id = (select id from tst.o where k='a');
select tst.check('cancelling an order that was out for delivery also removes the driver', (select count(*) = 0 from public.order_driver_locations));

update public.orders set status = 'out_for_delivery' where id = (select id from tst.o where k='a');
set local role service_role;
select public.set_driver_location((select id from tst.o where k='a'), 32.09, 36.19);
reset role;
update public.orders set status = 'preparing' where id = (select id from tst.o where k='a');
select tst.check('sending an order back to preparing removes the driver too', (select count(*) = 0 from public.order_driver_locations));

update public.orders set status = 'out_for_delivery' where id = (select id from tst.o where k='a');
set local role service_role;
select public.set_driver_location((select id from tst.o where k='a'), 32.09, 36.19);
reset role;
delete from public.orders where id = (select id from tst.o where k='a');
select tst.check('deleting an order removes its driver row', (select count(*) = 0 from public.order_driver_locations));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
