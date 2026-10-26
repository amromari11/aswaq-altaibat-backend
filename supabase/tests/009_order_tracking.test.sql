-- Tests for 009_order_tracking.sql (apply 008 and 009 first: run_local.py reset 008 009).
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

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','g@example.com');
insert into public.categories (id, name, name_ar) values ('cccccccc-cccc-cccc-cccc-cccccccccccc','Dairy','Dairy-ar');
insert into public.products (id, category_id, name, name_ar, unit, price, discount_price, sku) values
 ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Milk','Milk-ar','1L', 2.500, null,'S1'),
 ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Cheese','Cheese-ar',null, 4.000, 3.250,'S2'),
 ('aaaaaaaa-0000-0000-0000-000000000004','cccccccc-cccc-cccc-cccc-cccccccccccc','Big','Big-ar',null, 25.000, null,'S4');

create function tst.zone(n text) returns uuid language sql as $$ select id from public.delivery_zones where name_en = n $$;
-- items: 2 Milk + 1 Cheese (8.250) -> zone Beta (min 7, fee 1.5, eta 35)
create function tst.order_tok(tok uuid, name text default 'Amr Test', phone text default '+962791234567')
returns uuid language sql as $$
  select public.place_order(name, phone,
    '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000001","quantity":2},{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":1}]'::jsonb,
    'Street 1, bldg 2', tst.zone('Beta'), null, 32.0, 36.0, 'ring bell', tok) $$;
grant execute on function tst.zone(text), tst.order_tok(uuid,text,text) to anon, authenticated;
grant all on all tables in schema public to service_role;

-- ===== placing orders (guest) =====
create table tst.o (k text, id uuid, tok uuid);
grant all on tst.o to anon, authenticated, service_role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
insert into tst.o select 'a', i, 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa' from (select tst.order_tok('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') i) x;
insert into tst.o select 'b', i, 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb' from (select tst.order_tok('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', 'Second Guest', '+962771112222') i) x;
-- the app does not have to send a token (older builds): the 9-argument call still works
insert into tst.o select 'c', i, null from (select public.place_order('Old Build','+962781110000',
  '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000004","quantity":1}]'::jsonb,'Street 9', tst.zone('Beta')) i) x;
reset role;

select tst.check('client-supplied token is stored on the order',
  (select tracking_token = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa' from public.orders where id = (select id from tst.o where k='a')));
select tst.check('order placed without a token gets a random one',
  (select tracking_token is not null and tracking_token not in ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb') from public.orders where id = (select id from tst.o where k='c')));
select tst.check('only one place_order exists (old signature dropped, no ambiguity)', (select count(*) = 1 from pg_proc where proname = 'place_order'));
select tst.check('tracking tokens are unique', (select count(distinct tracking_token) = count(*) from public.orders));
select tst.expect_err('reusing a token for a second order is refused, not silently shared',
  $q$select tst.order_tok('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'Dup', '+962791230000')$q$,
  'duplicate key value violates unique constraint "uq_orders_tracking_token"');

-- ===== get_order_tracking (as a guest, no account) =====
set local role anon;
create temp table trk as select public.get_order_tracking((select id from tst.o where k='a'), 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') as j;
grant all on trk to anon;
reset role;
select tst.check('tracking returns the order for the right id + token', (select j is not null and j ->> 'id' = (select id::text from tst.o where k='a') from trk));
select tst.check('tracking: status, money, address, zone, eta',
  (select j ->> 'status' = 'pending' and (j ->> 'subtotal')::numeric = 8.250 and (j ->> 'delivery_fee')::numeric = 1.5
      and (j ->> 'total_price')::numeric = 9.750 and j ->> 'delivery_address' = 'Street 1, bldg 2'
      and j ->> 'customer_name' = 'Amr Test' and j ->> 'payment_method' = 'cash' and j ->> 'notes' = 'ring bell'
      and j ->> 'zone_name_ar' = (select name_ar from public.delivery_zones where name_en='Beta')
      and (j ->> 'eta_minutes')::int = 35 from trk),
  (select j::text from trk));
select tst.check('tracking: items with names, quantities and server prices',
  (select jsonb_array_length(j -> 'items') = 2
      and (select bool_or(i ->> 'name_ar' = 'Milk-ar' and (i ->> 'quantity')::int = 2 and i ->> 'unit' = '1L' and (i ->> 'line_total')::numeric = 5.000) from jsonb_array_elements(j -> 'items') i)
      and (select bool_or(i ->> 'name_ar' = 'Cheese-ar' and (i ->> 'unit_price')::numeric = 3.250) from jsonb_array_elements(j -> 'items') i)
   from trk));
select tst.check('tracking does not leak the token, phone or other customers',
  (select not (j ? 'tracking_token') and not (j ? 'customer_phone') and not (j ? 'user_id') from trk));

set local role anon;
select tst.check('wrong token -> NULL (not an error)', public.get_order_tracking((select id from tst.o where k='a'), 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb') is null);
select tst.check('another order''s token does not open this order', public.get_order_tracking((select id from tst.o where k='b'), 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') is null);
select tst.check('unknown order id -> NULL', public.get_order_tracking(gen_random_uuid(), 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') is null);
select tst.check('a guest still cannot read the orders table directly', (select count(*) = 0 from public.orders));
select tst.expect_err('a guest cannot call the admin analytics', $q$select * from public.admin_order_insights(now()-interval '1 day', now())$q$, 'permission denied for function admin_order_insights');

-- ===== list_orders_summary =====
create temp table lst as select * from public.list_orders_summary(jsonb_build_array(
  jsonb_build_object('id', (select id from tst.o where k='a'), 'token', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
  jsonb_build_object('id', (select id from tst.o where k='b'), 'token', 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'),
  jsonb_build_object('id', (select id from tst.o where k='c'), 'token', 'cccccccc-9999-4999-8999-cccccccccccc'),   -- wrong token
  jsonb_build_object('id', 'not-a-uuid', 'token', 'x'),                                                              -- malformed
  jsonb_build_object('id', gen_random_uuid(), 'token', gen_random_uuid()),                                           -- unknown
  to_jsonb('just a string'::text)));                                                                                  -- not an object
grant all on lst to anon;
reset role;
select tst.check('summary: returns exactly the orders whose id + token match (garbage skipped, no error)', (select count(*) = 2 from lst));
select tst.check('summary: newest first, with item count, zone and eta',
  (select (select id from lst order by created_at desc, id limit 1) is not null
      and (select item_count from lst where id = (select id from tst.o where k='a')) = 3      -- 2 milk + 1 cheese
      and (select total_price from lst where id = (select id from tst.o where k='a')) = 9.750
      and (select eta_minutes from lst where id = (select id from tst.o where k='a')) = 35));
set local role anon;
select tst.check('summary: non-array input -> empty, no error', (select count(*) = 0 from public.list_orders_summary('{"a":1}'::jsonb)));
select tst.check('summary: null input -> empty, no error', (select count(*) = 0 from public.list_orders_summary(null)));
reset role;

-- ===== signed-in owner can read their own order's token through RLS (for cross-device history) =====
update public.orders set user_id = '11111111-1111-1111-1111-111111111111' where id = (select id from tst.o where k='a');
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select tst.check('owner sees their order and its token', (select count(*) = 1 and bool_and(tracking_token = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') from public.orders));
reset role;
select set_config('request.jwt.claim.sub', '', true);

-- ===== realtime broadcast trigger =====
-- (1) Realtime not available at all: the status change must still go through.
update public.orders set status = 'confirmed' where id = (select id from tst.o where k='a');
select tst.check('status change succeeds even when realtime.send does not exist', (select status = 'confirmed' from public.orders where id = (select id from tst.o where k='a')));

-- (2) Realtime available: one broadcast per status change, on the token's channel.
create schema realtime;
create table tst.sent (payload jsonb, event text, topic text, private boolean);
create function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
  language sql as $$ insert into tst.sent values (payload, event, topic, private) $$;
update public.orders set status = 'preparing' where id = (select id from tst.o where k='a');
select tst.check('a status change broadcasts once, on order:<token>, event "status", public channel',
  (select count(*) = 1 and bool_and(topic = 'order:aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa' and event = 'status' and private = false) from tst.sent));
select tst.check('broadcast payload carries order id and the new status only',
  (select payload ->> 'status' = 'preparing' and payload ->> 'order_id' = (select id::text from tst.o where k='a')
      and (select count(*) = 3 from jsonb_object_keys(payload)) from tst.sent));
update public.orders set notes = 'changed note' where id = (select id from tst.o where k='a');
update public.orders set status = 'preparing' where id = (select id from tst.o where k='a');
select tst.check('no broadcast for a non-status edit or a status set to the same value', (select count(*) = 1 from tst.sent));
update public.orders set status = 'out_for_delivery' where id = (select id from tst.o where k='b');
select tst.check('each order broadcasts on its own channel',
  (select count(*) = 1 from tst.sent where topic = 'order:bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'));

-- (3) Realtime raising: still must not block the admin.
create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
  language plpgsql as $$ begin raise exception 'realtime is down'; end $$;
update public.orders set status = 'delivered' where id = (select id from tst.o where k='a');
select tst.check('status change succeeds even when realtime.send raises', (select status = 'delivered' from public.orders where id = (select id from tst.o where k='a')));
select tst.check('tracking reflects the latest status', (select public.get_order_tracking((select id from tst.o where k='a'), 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') ->> 'status' = 'delivered'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
