-- Tests for 008_guest_checkout_customers.sql. Run through run_local.py (see its docstring),
-- which wraps this file in one transaction and rolls it back, so nothing persists.
-- Prints one PASS/FAIL line per check.
create schema tst; grant usage on schema tst to anon, authenticated, service_role;
create table tst.log (ok boolean, name text, detail text);
grant all on tst.log to anon, authenticated, service_role;

-- check(name, condition, detail)
create function tst.check(n text, cond boolean, d text default '') returns void language plpgsql as $$
begin insert into tst.log values (coalesce(cond,false), n, d); end $$;
-- expect_err(name, sql, code): sql must fail with message = code
create function tst.expect_err(n text, q text, code text) returns void language plpgsql as $$
declare m text;
begin
  begin execute q; m := 'NO ERROR';
  exception when others then m := sqlerrm; end;
  insert into tst.log values (m = code, n, 'wanted ' || code || ' got ' || m);
end $$;
grant execute on all functions in schema tst to anon, authenticated, service_role;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','g@example.com'), ('22222222-2222-2222-2222-222222222222','h@example.com');
insert into public.categories (id, name, name_ar) values ('cccccccc-cccc-cccc-cccc-cccccccccccc','Dairy','Dairy-ar');
insert into public.products (id, category_id, name, name_ar, price, discount_price, stock_quantity, stock_status, sku) values
 ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Milk','Milk-ar', 2.500, null, 0, 'in_stock','S1'),
 ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Cheese','Cheese-ar', 4.000, 3.250, 5, 'in_stock','S2'),
 ('aaaaaaaa-0000-0000-0000-000000000003','cccccccc-cccc-cccc-cccc-cccccccccccc','Gone','Gone-ar', 1.000, null, 0, 'out_of_stock','S3'),
 ('aaaaaaaa-0000-0000-0000-000000000004','cccccccc-cccc-cccc-cccc-cccccccccccc','Big','Big-ar', 25.000, null, 0, 'in_stock','S4');
-- zone A: fee 1.0 min 5 | zone B: fee 1.5 min 7
insert into public.user_addresses (id, user_id, zone_id, address_line)
 select '99999999-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', id, 'user1 addr' from public.delivery_zones where name_en='Beta';
insert into public.user_addresses (id, user_id, zone_id, address_line)
 select '99999999-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', id, 'user2 addr' from public.delivery_zones where name_en='Beta';

create function tst.zone(n text) returns uuid language sql as $$ select id from public.delivery_zones where name_en = n $$;
grant execute on function tst.zone(text) to anon, authenticated;

create function tst.order_(name text, phone text, items jsonb, zone text default 'Beta', addr text default 'Street 1, bldg 2', address_id uuid default null)
returns uuid language sql as $$
  select public.place_order(name, phone, items, addr, tst.zone(zone), address_id, 32.0, 36.0, 'ring bell') $$;
grant execute on function tst.order_(text,text,jsonb,text,text,uuid) to anon, authenticated;

-- ===== GUEST (anon, no auth) =====
set local role anon;
select set_config('request.jwt.claim.sub', '', true);

create temp table res as select tst.order_('Amr Test', '+962791234567',
  '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2},{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":1}]') as id;
grant all on res to anon, authenticated, service_role;

reset role;
select tst.check('guest order created', (select count(*) from res) = 1);
select tst.check('guest order: user_id null, snapshot + customer set',
  (select user_id is null and customer_name='Amr Test' and customer_phone='+962791234567' and customer_id is not null and status='pending' and payment_method='cash' from public.orders where id=(select id from res)));
select tst.check('totals: 2*2.500 + 3.250 = 8.250, fee 1.5, total 9.750 (server-priced, discount applied)',
  (select subtotal=8.250 and delivery_fee=1.5 and total_price=9.750 from public.orders where id=(select id from res)),
  (select subtotal||'/'||delivery_fee||'/'||total_price from public.orders where id=(select id from res)));
select tst.check('order_items written with server prices',
  (select count(*)=2 and sum(line_total)=8.250 and bool_or(unit_price=3.250) from public.order_items where order_id=(select id from res)));
select tst.check('zone + coords + notes stored',
  (select zone_id=tst.zone('Beta') and delivery_lat=32.0 and delivery_lng=36.0 and notes='ring bell' and delivery_address='Street 1, bldg 2' from public.orders where id=(select id from res)));
select tst.check('customer row created, not linked to an account',
  (select count(*)=1 and bool_and(auth_user_id is null) from public.customers where phone_number='+962791234567'));

-- same phone, new name (formatted with spaces/dashes) -> same customer, name updated
set local role anon;
select tst.order_('Amr Updated', '+962 79-123 4567', '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]');
reset role;
select tst.check('same phone reuses the customer and updates the name',
  (select count(*)=1 and bool_and(full_name='Amr Updated') from public.customers where phone_number='+962791234567'));
select tst.check('free delivery at >= 20 (25.000 -> fee 0)',
  (select delivery_fee=0 and total_price=25 from public.orders where subtotal=25));
select tst.check('each order keeps its own name snapshot',
  (select count(*)=1 from public.orders where customer_name='Amr Test') and (select count(*)=1 from public.orders where customer_name='Amr Updated'));

-- validation errors (as guest)
set local role anon;
select tst.expect_err('below zone minimum', $q$select tst.order_('Amr','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":1}]')$q$, 'below_minimum');
select tst.expect_err('invalid phone (local format rejected; app normalizes first)', $q$select tst.order_('Amr','0791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]')$q$, 'invalid_phone');
select tst.expect_err('invalid phone (landline)', $q$select tst.order_('Amr','+96265123456','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]')$q$, 'invalid_phone');
select tst.expect_err('invalid name', $q$select tst.order_(' A ','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]')$q$, 'invalid_name');
select tst.expect_err('invalid address', $q$select tst.order_('Amr','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]','Beta','x')$q$, 'invalid_address');
select tst.expect_err('empty items', $q$select tst.order_('Amr','+962791234567','[]')$q$, 'invalid_items');
select tst.expect_err('bad product id', $q$select tst.order_('Amr','+962791234567','[{"product_id":"nope","quantity":1}]')$q$, 'invalid_items');
select tst.expect_err('zero quantity', $q$select tst.order_('Amr','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":0}]')$q$, 'invalid_items');
select tst.expect_err('items not an array', $q$select tst.order_('Amr','+962791234567','{"a":1}')$q$, 'invalid_items');
select tst.expect_err('unknown product', $q$select tst.order_('Amr','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-0000000000ff","quantity":1}]')$q$, 'unknown_product');
select tst.expect_err('out of stock', $q$select tst.order_('Amr','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000003","quantity":1}]')$q$, 'out_of_stock');
select tst.expect_err('insufficient stock (6 > 5)', $q$select tst.order_('Amr','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":6}]')$q$, 'insufficient_stock');
select tst.expect_err('invalid zone', $q$select public.place_order('Amr','+962791234567','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]','Street 1',gen_random_uuid())$q$, 'invalid_zone');

-- direct table access is closed to the app keys
select tst.expect_err('anon cannot insert orders directly', $q$insert into public.orders (delivery_address) values ('x')$q$, 'new row violates row-level security policy for table "orders"');
select tst.expect_err('anon cannot read customers', $q$select * from public.customers$q$, 'permission denied for table customers');
select tst.expect_err('anon cannot read admin_customer_stats', $q$select * from public.admin_customer_stats$q$, 'permission denied for view admin_customer_stats');
select tst.expect_err('anon cannot run admin_top_products', $q$select * from public.admin_top_products(now()-interval '1 day', now())$q$, 'permission denied for function admin_top_products');
select tst.expect_err('anon cannot run admin_order_insights', $q$select * from public.admin_order_insights(now()-interval '1 day', now())$q$, 'permission denied for function admin_order_insights');
select tst.check('anon sees no orders (RLS)', (select count(*) from public.orders) = 0);
reset role;

-- abuse guard: 5 orders/hour per phone; the 6th is refused
set local role anon;
select tst.order_('Spammer','+962781111111','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]') from generate_series(1,5);
select tst.expect_err('6th order within the hour is refused', $q$select tst.order_('Spammer','+962781111111','[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]')$q$, 'too_many_orders');
reset role;

-- ===== SIGNED-IN (Google user 1) =====
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select tst.order_('Google One', '+962771111111', '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]', 'Beta', 'g addr', '99999999-0000-0000-0000-000000000001');
-- second order, different phone, same account (auth_user_id is unique): must not fail
select tst.order_('Google One', '+962772222222', '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]', 'Beta', 'g addr', '99999999-0000-0000-0000-000000000002');
reset role;
select tst.check('signed-in order carries user_id and linked customer',
  (select count(*)=1 from public.orders o join public.customers c on c.id=o.customer_id where o.user_id='11111111-1111-1111-1111-111111111111' and c.phone_number='+962771111111' and c.auth_user_id='11111111-1111-1111-1111-111111111111'));
select tst.check('own saved address is referenced',
  (select address_id='99999999-0000-0000-0000-000000000001' from public.orders where customer_phone='+962771111111'));
select tst.check('second phone on the same account: order kept, customer created but not double-linked',
  (select count(*)=1 from public.customers where phone_number='+962772222222' and auth_user_id is null)
  and (select count(*)=2 from public.orders where user_id='11111111-1111-1111-1111-111111111111'));
select tst.check('someone else''s address is NOT referenced',
  (select address_id is null from public.orders where customer_phone='+962772222222'));
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select tst.check('signed-in user sees only their own orders', (select count(*)=2 from public.orders));
reset role;

-- ===== ADMIN (service_role) =====
set local role service_role;
select tst.check('admin_top_products: the 25 JOD item sells the most units', (select product_id='aaaaaaaa-0000-0000-0000-000000000004' from public.admin_top_products(now()-interval '1 day', now()+interval '1 day', 10) limit 1),
  (select string_agg(name||':'||units_sold, ', ') from public.admin_top_products(now()-interval '1 day', now()+interval '1 day', 10)));
select tst.check('admin_top_products: window excludes old orders', (select count(*)=0 from public.admin_top_products(now()-interval '3 days', now()-interval '2 days', 10)));
select tst.check('admin_order_insights: count/sales/avg consistent',
  (select orders_count = (select count(*) from public.orders) and total_sales = (select sum(total_price) from public.orders)
      and abs(avg_order_value - total_sales/orders_count) < 0.001 from public.admin_order_insights(now()-interval '1 day', now()+interval '1 day')),
  (select orders_count||'/'||total_sales||'/'||round(avg_order_value,3)||'/'||unique_customers from public.admin_order_insights(now()-interval '1 day', now()+interval '1 day')));
select tst.check('admin_top_zones: Beta is the top zone', (select zone_name_ar = (select name_ar from public.delivery_zones where name_en='Beta') from public.admin_top_zones(now()-interval '1 day', now()+interval '1 day', 5) limit 1));
select tst.check('admin_sales_by_day: one Amman day, totals match', (select count(*)=1 and sum(sales)=(select sum(total_price) from public.orders) from public.admin_sales_by_day(now()-interval '1 day', now()+interval '1 day')));
select tst.check('admin_customer_stats: per-customer orders and spend',
  (select orders_count=2 and total_spend=(select sum(total_price) from public.orders where customer_phone='+962791234567' or customer_name='Amr Updated') from public.admin_customer_stats where phone_number='+962791234567'),
  (select orders_count||'/'||total_spend from public.admin_customer_stats where phone_number='+962791234567'));
select tst.check('admin_customer_stats: Google link flagged', (select has_google_account from public.admin_customer_stats where phone_number='+962771111111'));
reset role;

-- cancelled orders drop out of sales, spend and top products
update public.orders set status='cancelled' where customer_name='Amr Test';
set local role service_role;
select tst.check('cancelled order excluded from spend/orders count',
  (select orders_count=1 and cancelled_count=1 and total_spend=25 from public.admin_customer_stats where phone_number='+962791234567'),
  (select orders_count||'/'||cancelled_count||'/'||total_spend from public.admin_customer_stats where phone_number='+962791234567'));
select tst.check('cancelled order excluded from top products (no Milk/Cheese left)', (select count(*)=0 from public.admin_top_products(now()-interval '1 day', now()+interval '1 day', 10) where name in ('Milk','Cheese')));
select tst.check('admin_order_insights reports the cancellation', (select cancelled_count=1 from public.admin_order_insights(now()-interval '1 day', now()+interval '1 day')));
reset role;

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
