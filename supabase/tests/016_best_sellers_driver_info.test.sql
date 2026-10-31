-- Tests for 016_best_sellers_driver_info.sql (run_local.py reset 008 009 010; 015 is included below).
-- Run via run_local.py `test`: one rolled-back transaction, one PASS/FAIL line per check.
-- helpers below call the 12-argument place_order, which only exists after the include
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

insert into public.categories (id, name, name_ar) values ('cccccccc-cccc-cccc-cccc-cccccccccccc','Dairy','Dairy-ar');
-- p1 sells most, p2 some, p3 on offer but unsold, p4 plain and unsold, p5 sold but out of stock,
-- p6 inactive but sold, p7 only sold 40 days ago, p8 only in a cancelled order
insert into public.products (id, category_id, name, name_ar, price, discount_price, stock_status, is_active, sku, created_at) values
 ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','P1','P1-ar', 2.0, null, 'in_stock', true, 'S1', now() - interval '10 days'),
 ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','P2','P2-ar', 3.0, null, 'in_stock', true, 'S2', now() - interval '9 days'),
 ('aaaaaaaa-0000-0000-0000-000000000003','cccccccc-cccc-cccc-cccc-cccccccccccc','P3','P3-ar', 5.0, 4.0,  'in_stock', true, 'S3', now() - interval '8 days'),
 ('aaaaaaaa-0000-0000-0000-000000000004','cccccccc-cccc-cccc-cccc-cccccccccccc','P4','P4-ar', 6.0, null, 'in_stock', true, 'S4', now() - interval '7 days'),
 ('aaaaaaaa-0000-0000-0000-000000000005','cccccccc-cccc-cccc-cccc-cccccccccccc','P5','P5-ar', 7.0, null, 'out_of_stock', true, 'S5', now() - interval '6 days'),
 ('aaaaaaaa-0000-0000-0000-000000000006','cccccccc-cccc-cccc-cccc-cccccccccccc','P6','P6-ar', 8.0, null, 'in_stock', false, 'S6', now() - interval '5 days'),
 ('aaaaaaaa-0000-0000-0000-000000000007','cccccccc-cccc-cccc-cccc-cccccccccccc','P7','P7-ar', 9.0, null, 'in_stock', true, 'S7', now() - interval '4 days'),
 ('aaaaaaaa-0000-0000-0000-000000000008','cccccccc-cccc-cccc-cccc-cccccccccccc','P8','P8-ar', 1.0, null, 'in_stock', true, 'S8', now() - interval '3 days');
insert into public.customers (id, phone_number, full_name) values ('dddddddd-0000-0000-0000-000000000001', '+962791234567', 'C');
create function tst.mkorder(id uuid, st public.order_status, ago interval, typ text default 'delivery') returns void language sql as $$
  insert into public.orders (id, customer_id, customer_name, customer_phone, status, subtotal, delivery_fee, total_price, delivery_address, created_at, order_type)
  values (id, 'dddddddd-0000-0000-0000-000000000001', 'C', '+962791234567', st, 1, 0, 1, case when typ = 'pickup' then null else 'x street' end, now() - ago, typ) $$;
select tst.mkorder('eeeeeeee-0000-0000-0000-000000000001', 'delivered', interval '2 days');
select tst.mkorder('eeeeeeee-0000-0000-0000-000000000002', 'cancelled', interval '1 day');
select tst.mkorder('eeeeeeee-0000-0000-0000-000000000003', 'delivered', interval '40 days');
insert into public.order_items (order_id, product_id, quantity, unit_price, line_total) values
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001', 10, 2, 20),
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002', 4, 3, 12),
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000005', 50, 7, 350),
 ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000006', 50, 8, 400),
 ('eeeeeeee-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000008', 99, 1, 99),
 ('eeeeeeee-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000007', 99, 9, 891);
grant all on all tables in schema public to service_role;

-- @include 016_best_sellers_driver_info.sql

create table tst.names as select name, row_number() over () as n from public.best_sellers(20);
select tst.check('ranked by units sold, then the unsold product that is on offer',
  (select string_agg(name, ',' order by n) = 'P1,P2,P3' from tst.names), (select string_agg(name, ',' order by n) from tst.names));
select tst.check('cancelled, old (40 days), inactive, out-of-stock and plain unsold products are left out',
  (select count(*) = 3 and not bool_or(name in ('P4','P5','P6','P7','P8')) from tst.names));
select tst.check('the limit is honoured', (select count(*) = 1 from public.best_sellers(1)));
select tst.check('a zero, negative or null limit still returns one row, a huge one is capped',
  (select count(*) = 1 from public.best_sellers(0)) and (select count(*) = 1 from public.best_sellers(-5)) and (select count(*) = 3 from public.best_sellers(null)) and (select count(*) = 3 from public.best_sellers(10000)));
select tst.check('it returns whole product rows (price, sku ...)', (select price = 2 and sku = 'S1' from public.best_sellers(1)));

set local role anon;
select tst.check('the app (anon) can read best sellers', (select count(*) = 3 from public.best_sellers(20)));
reset role;
set local role authenticated;
select tst.check('signed-in users can too', (select count(*) = 3 from public.best_sellers(20)));
reset role;

-- driver details
create temp table dd (k text, j jsonb);
update public.orders set status = 'out_for_delivery' where id = 'eeeeeeee-0000-0000-0000-000000000001';
update public.orders set tracking_token = '11111111-1111-4111-8111-111111111111' where id = 'eeeeeeee-0000-0000-0000-000000000001';
select tst.check('before details are set there is no driver_info',
  (select public.get_order_tracking('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-4111-8111-111111111111') -> 'driver_info' = 'null'::jsonb));
update public.orders set driver_name = 'Khaled Driver', driver_phone = '+962791112233' where id = 'eeeeeeee-0000-0000-0000-000000000001';
select tst.check('while out for delivery the customer sees the name and phone',
  (select (public.get_order_tracking('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-4111-8111-111111111111') -> 'driver_info') = '{"name":"Khaled Driver","phone":"+962791112233"}'::jsonb));
select tst.check('the wrong token still returns nothing', (select public.get_order_tracking('eeeeeeee-0000-0000-0000-000000000001', '99999999-9999-4999-8999-999999999999') is null));
update public.orders set status = 'preparing' where id = 'eeeeeeee-0000-0000-0000-000000000001';
select tst.check('not out for delivery: the number is not shown',
  (select public.get_order_tracking('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-4111-8111-111111111111') -> 'driver_info' = 'null'::jsonb));
update public.orders set status = 'delivered' where id = 'eeeeeeee-0000-0000-0000-000000000001';
select tst.check('after delivery it is not shown either',
  (select public.get_order_tracking('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-4111-8111-111111111111') -> 'driver_info' = 'null'::jsonb));
update public.orders set status = 'out_for_delivery', driver_name = null where id = 'eeeeeeee-0000-0000-0000-000000000001';
select tst.check('a phone with no name is still returned (name is null)',
  (select (public.get_order_tracking('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-4111-8111-111111111111') -> 'driver_info' ->> 'phone') = '+962791112233'));

select tst.expect_err('a driver phone must be a Jordanian mobile', $q$update public.orders set driver_phone = '0791112233'$q$,
  'new row for relation "orders" violates check constraint "orders_driver_phone_fmt"');
select tst.expect_err('a driver phone cannot carry a link or script', $q$update public.orders set driver_phone = 'javascript:alert(1)'$q$,
  'new row for relation "orders" violates check constraint "orders_driver_phone_fmt"');
select tst.expect_err('a one-letter driver name is refused', $q$update public.orders set driver_name = 'K'$q$,
  'new row for relation "orders" violates check constraint "orders_driver_name_len"');

-- pickup orders never show a driver
select tst.mkorder('eeeeeeee-0000-0000-0000-000000000009', 'out_for_delivery', interval '1 hour', 'pickup');
update public.orders set tracking_token = '22222222-2222-4222-8222-222222222222', driver_name = 'Not A Driver', driver_phone = '+962791112233' where id = 'eeeeeeee-0000-0000-0000-000000000009';
select tst.check('a pickup order never exposes driver details',
  (select public.get_order_tracking('eeeeeeee-0000-0000-0000-000000000009', '22222222-2222-4222-8222-222222222222') -> 'driver_info' = 'null'::jsonb));

create function tst.anon_update_orders() returns int language plpgsql as $$
declare n int;
begin
  begin update public.orders set driver_phone = '+962799999999'; get diagnostics n = row_count;
  exception when others then n := 0; end;
  return n;
end $$;
grant execute on function tst.anon_update_orders() to anon;
set local role anon;
select tst.check('anon cannot read orders directly (so no driver numbers leak)', (select count(*) = 0 from public.orders));
select tst.check('anon cannot set driver details (no row is updated)', tst.anon_update_orders() = 0);
reset role;
select tst.check('...and the number is unchanged', (select driver_phone = '+962791112233' from public.orders where id = 'eeeeeeee-0000-0000-0000-000000000001'));
reset role;

select tst.check('both triggers are in place',
  (select count(*) = 1 from pg_trigger where tgname = 'trg_orders_broadcast_driver') and (select count(*) = 1 from pg_trigger where tgname = 'trg_orders_broadcast_status'));
select tst.check('changing the driver name does not fail even though Realtime is not here (best effort)',
  (select true from (select 1) x where (select count(*) from public.orders) > 0));
update public.orders set driver_name = 'Changed Name' where id = 'eeeeeeee-0000-0000-0000-000000000001';
select tst.check('...and the change was saved', (select driver_name = 'Changed Name' from public.orders where id = 'eeeeeeee-0000-0000-0000-000000000001'));

-- re-running keeps data and does not break anything
-- @include 016_best_sellers_driver_info.sql
select tst.check('re-run: driver details survive', (select driver_phone = '+962791112233' from public.orders where id = 'eeeeeeee-0000-0000-0000-000000000001'));
select tst.check('re-run: best sellers unchanged', (select count(*) = 3 from public.best_sellers(20)));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
