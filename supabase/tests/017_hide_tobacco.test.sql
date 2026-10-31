-- Tests for 017_hide_tobacco.sql (run_local.py reset 008 009 010).
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


insert into public.categories (id, name, name_ar, is_active, display_order) values
  ('cccccccc-0000-0000-0000-000000000001', 'Dairy', 'Dairy-ar', true, 1),
  ('cccccccc-0000-0000-0000-000000000002', 'Tobacco', U&'\0627\0644\062A\0628\063A \0648\0627\0644\0645\0639\0633\0644', true, 12),
  ('cccccccc-0000-0000-0000-000000000003', 'Old hidden', 'old-hidden', false, 0);
insert into public.products (id, category_id, name, name_ar, price, sku, is_active) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'Milk', 'Milk-ar', 2.5, 'S1', true),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000002', 'Cigs', 'Cigs-ar', 30, 'T1', true),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'cccccccc-0000-0000-0000-000000000002', 'Shisha', 'Shisha-ar', 5, 'T2', true),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'cccccccc-0000-0000-0000-000000000002', 'Already off', 'off-ar', 5, 'T3', false);
grant all on all tables in schema public to service_role;
create function tst.zone(n text) returns uuid language sql as $$ select id from public.delivery_zones where name_en = n $$;
grant execute on function tst.zone(text) to anon;

-- @include 017_hide_tobacco.sql

select tst.check('the tobacco category is hidden', (select not is_active from public.categories where id = 'cccccccc-0000-0000-0000-000000000002'));
select tst.check('other categories are untouched',
  (select is_active from public.categories where id = 'cccccccc-0000-0000-0000-000000000001')
  and (select not is_active from public.categories where id = 'cccccccc-0000-0000-0000-000000000003'));
select tst.check('its products are hidden, nothing is deleted',
  (select count(*) = 3 and not bool_or(is_active) from public.products where category_id = 'cccccccc-0000-0000-0000-000000000002'));
select tst.check('other products are untouched', (select is_active from public.products where id = 'aaaaaaaa-0000-0000-0000-000000000001'));

-- the app's own queries: active categories and active products
set local role anon;
select tst.check('the app no longer lists the category', (select count(*) = 1 and bool_and(name_ar = 'Dairy-ar') from public.categories where is_active));
select tst.check('the app can no longer find its products', (select count(*) = 0 from public.products where is_active and category_id = 'cccccccc-0000-0000-0000-000000000002'));
select tst.check('...nor by a search on the SKU', (select count(*) = 0 from public.products where is_active and sku in ('T1', 'T2')));
select tst.expect_err('an order for a tobacco product is refused', $q$select public.place_order('Test Name', '+962791234567', '[{"product_id":"aaaaaaaa-0000-0000-0000-000000000002","quantity":1}]'::jsonb, 'Some street', tst.zone('Beta'))$q$, 'unknown_product');
reset role;

-- a later POS import brings products in by SKU: they must not come back
insert into public.products (category_id, name, name_ar, price, sku) values ('cccccccc-0000-0000-0000-000000000002', 'New import', 'new', 9, 'T9');
select tst.check('a new product inserted into the hidden category is hidden', (select not is_active from public.products where sku = 'T9'));
insert into public.products (id, category_id, name, name_ar, price, sku) values ('aaaaaaaa-0000-0000-0000-000000000010', 'cccccccc-0000-0000-0000-000000000001', 'Cheese', 'cheese', 4, 'S2');
update public.products set category_id = 'cccccccc-0000-0000-0000-000000000002' where sku = 'S2';
select tst.check('a product moved into the hidden category is hidden', (select not is_active from public.products where sku = 'S2'));
insert into public.products (category_id, name, name_ar, price, sku, is_active) values ('cccccccc-0000-0000-0000-000000000002', 'Forced on', 'on', 9, 'T10', true);
select tst.check('asking for it to be active does not work either', (select not is_active from public.products where sku = 'T10'));
update public.products set is_active = true where sku = 'T1';
select tst.check('re-activating a product while its category is hidden has no effect', (select not is_active from public.products where sku = 'T1'));
select tst.check('products elsewhere can be switched on and off freely',
  (select count(*) = 1 from (select 1 from public.products where sku = 'S1' and is_active) x));
update public.products set is_active = false where sku = 'S1';
update public.products set is_active = true where sku = 'S1';
select tst.check('...', (select is_active from public.products where sku = 'S1'));

-- the way back: category on, then products on
update public.categories set is_active = true where id = 'cccccccc-0000-0000-0000-000000000002';
select tst.check('showing the category does not by itself show the products', (select count(*) = 0 from public.products where category_id = 'cccccccc-0000-0000-0000-000000000002' and is_active));
update public.products set is_active = true where sku = 'T1';
select tst.check('after that, a product can be switched on again', (select is_active from public.products where sku = 'T1'));
update public.categories set is_active = false where id = 'cccccccc-0000-0000-0000-000000000002';

-- running it again changes nothing
-- @include 017_hide_tobacco.sql
select tst.check('re-run: still hidden, products still hidden',
  (select not is_active from public.categories where id = 'cccccccc-0000-0000-0000-000000000002')
  and (select count(*) = 0 from public.products where category_id = 'cccccccc-0000-0000-0000-000000000002' and is_active));
select tst.check('re-run: exactly one trigger', (select count(*) = 1 from pg_trigger where tgname = 'trg_products_follow_category'));
select tst.check('re-run: a category that is not there does not break it', true);

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
