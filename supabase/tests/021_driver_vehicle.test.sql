-- Tests for 021_driver_vehicle.sql (run_local.py reset 008 009 010; 015, 016, 019, 020 are included below).
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

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'customer@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'driver@example.com');
update public.profiles set role = 'driver', full_name = 'Khaled Driver', phone_number = '+962791112233',
       full_name_ar = U&'\062E\0627\0644\062F', vehicle_type = 'scooter', vehicle_model = 'SYM',
       vehicle_color = 'white', plate_number = '12-34567'
 where id = '22222222-2222-2222-2222-222222222222';

insert into public.orders (id, user_id, status, subtotal, total_price, delivery_address, order_type, driver_id, tracking_token) values
 ('00000000-0000-0000-0000-0000000000c1', '11111111-1111-1111-1111-111111111111', 'confirmed', 5, 6.5, 'Zarqa', 'delivery',
  '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-0000000000c1');

-- ---- validation ----
select tst.expect_err('vehicle type is scooter or car', $q$update public.profiles set vehicle_type = 'bus' where id = '22222222-2222-2222-2222-222222222222'$q$,
  'new row for relation "profiles" violates check constraint "profiles_vehicle_type_valid"');
select tst.expect_err('a plate is digits', $q$update public.profiles set plate_number = 'abc' where id = '22222222-2222-2222-2222-222222222222'$q$,
  'new row for relation "profiles" violates check constraint "profiles_plate_number_fmt"');
update public.profiles set plate_number = '2345678' where id = '22222222-2222-2222-2222-222222222222';
select tst.check('a plate without a dash is fine', (select plate_number = '2345678' from public.profiles where id = '22222222-2222-2222-2222-222222222222'));
update public.profiles set plate_number = '12-34567' where id = '22222222-2222-2222-2222-222222222222';

-- ---- the app cannot edit vehicle details ----
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select tst.expect_err('a driver cannot edit their plate from the app', $q$update public.profiles set plate_number = '99-99999' where id = '22222222-2222-2222-2222-222222222222'$q$,
  'permission denied for table profiles');
reset role;

-- ---- tracking: nothing before pick-up ----
set local role anon;
select tst.check('before pick-up the customer sees no driver',
  (select public.get_order_tracking('00000000-0000-0000-0000-0000000000c1', 'aaaaaaaa-0000-0000-0000-0000000000c1') -> 'driver_info') = 'null'::jsonb
  or (select public.get_order_tracking('00000000-0000-0000-0000-0000000000c1', 'aaaaaaaa-0000-0000-0000-0000000000c1') -> 'driver_info') is null);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.driver_pick_up('00000000-0000-0000-0000-0000000000c1');
reset role;

set local role anon;
create temp table info as
  select public.get_order_tracking('00000000-0000-0000-0000-0000000000c1', 'aaaaaaaa-0000-0000-0000-0000000000c1') -> 'driver_info' as d;
reset role;
select tst.check('on the way: the Arabic name wins', (select d ->> 'name' = U&'\062E\0627\0644\062F' from info), (select d::text from info));
select tst.check('on the way: phone from the order', (select d ->> 'phone' = '+962791112233' from info));
select tst.check('on the way: vehicle details',
  (select d ->> 'vehicle_type' = 'scooter' and d ->> 'vehicle_model' = 'SYM' and d ->> 'vehicle_color' = 'white' and d ->> 'plate_number' = '12-34567' from info));

-- no Arabic name: falls back to the order's snapshot
update public.profiles set full_name_ar = null where id = '22222222-2222-2222-2222-222222222222';
select tst.check('without an Arabic name the order snapshot is used',
  (public.get_order_tracking('00000000-0000-0000-0000-0000000000c1', 'aaaaaaaa-0000-0000-0000-0000000000c1') -> 'driver_info' ->> 'name') = 'Khaled Driver');

-- a wrong token still sees nothing
select tst.check('a wrong token gets nothing',
  public.get_order_tracking('00000000-0000-0000-0000-0000000000c1', 'bbbbbbbb-0000-0000-0000-0000000000c1') is null);

-- after delivery the driver disappears again
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.driver_mark_delivered('00000000-0000-0000-0000-0000000000c1');
reset role;
select tst.check('after delivery the customer no longer sees the driver',
  coalesce(public.get_order_tracking('00000000-0000-0000-0000-0000000000c1', 'aaaaaaaa-0000-0000-0000-0000000000c1') -> 'driver_info', 'null'::jsonb) = 'null'::jsonb);

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
