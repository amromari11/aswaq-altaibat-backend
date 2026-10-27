-- Tests for 012_primary_categories.sql (apply 008-010 first: run_local.py reset 008 009 010).
-- The categories below are your REAL 39 live names (copied from the live table), so a pass proves the
-- migration's ASCII Unicode escapes match them exactly. Run via run_local.py `test`: one rolled-back
-- transaction, one PASS/FAIL line per check. `-- @include` pastes the migration in at that point.
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

-- the live catalogue, before the migration
insert into public.categories (name, name_ar, is_active, display_order) values
  ('اجبان والبان ومشتقاتها', 'اجبان والبان ومشتقاتها', true, 0),
  ('اخرى', 'اخرى', true, 0),
  ('ادوات منزلية', 'ادوات منزلية', true, 0),
  ('الألبان', 'الألبان', true, 0),
  ('البهارات', 'البهارات', true, 0),
  ('البهارت العامه', 'البهارت العامه', true, 0),
  ('الخبز والكعك بانواعه', 'الخبز والكعك بانواعه', true, 0),
  ('الزيوت ومشتقاتها', 'الزيوت ومشتقاتها', true, 0),
  ('السكاكر ومشتقاتها', 'السكاكر ومشتقاتها', true, 0),
  ('القهوة والشاي ومشتقاتها', 'القهوة والشاي ومشتقاتها', true, 0),
  ('المعلبات', 'المعلبات', true, 0),
  ('المنظفات', 'المنظفات', true, 0),
  ('المياه المعدنية', 'المياه المعدنية', true, 0),
  ('الورقيات والفوط وتوابعها', 'الورقيات والفوط وتوابعها', true, 0),
  ('ايس كريم والبوظه', 'ايس كريم والبوظه', true, 0),
  ('بطاريات وكشافات', 'بطاريات وكشافات', true, 0),
  ('بيض', 'بيض', true, 0),
  ('حبوب ومشتقاتها', 'حبوب ومشتقاتها', true, 0),
  ('حليب ومشتقاته', 'حليب ومشتقاته', true, 0),
  ('خليط الكيك والحلويات ومشتقاتها', 'خليط الكيك والحلويات ومشتقاتها', true, 0),
  ('دجاج', 'دجاج', true, 0),
  ('دخان ومعسل', 'دخان ومعسل', true, 0),
  ('ديلي الطيبات', 'ديلي الطيبات', true, 0),
  ('رب البندورة', 'رب البندورة', true, 0),
  ('سكاكر', 'سكاكر', false, 0),
  ('شيبس', 'شيبس', true, 0),
  ('طحينة', 'طحينة', true, 0),
  ('عسل', 'عسل', true, 0),
  ('عصائر', 'عصائر', true, 0),
  ('غير مصنف', 'غير مصنف', true, 0),
  ('لحوم', 'لحوم', false, 0),
  ('لوازم الشواء', 'لوازم الشواء', true, 0),
  ('مجمدات', 'مجمدات', true, 0),
  ('مشتقات الميزان', 'مشتقات الميزان', true, 0),
  ('مشروبات غازية', 'مشروبات غازية', true, 0),
  ('معلبات', 'معلبات', false, 0),
  ('منظفات', 'منظفات', false, 0),
  ('مواد منزلية', 'مواد منزلية', false, 0),
  ('نثربات', 'نثربات', true, 0);
-- two extra rows for the "never touch these" rules
insert into public.categories (id, name, name_ar, image_url) values
  ('11111111-1111-1111-1111-111111111111', 'Custom', 'custom-url-category', 'https://example.com/my-own.jpg');
insert into public.categories (id, name, name_ar) values
  ('33333333-3333-3333-3333-333333333333', 'Brand new', 'brand-new-category');
-- the live names that share a prefix (so a sloppy match would cross-contaminate)
create table tst.before as select id, name_ar from public.categories where name_ar !~ '^(custom|brand)';
create function tst.cid(n text) returns uuid language sql as $$ select id from public.categories where name_ar = n order by created_at limit 1 $$;
-- the live products table has more columns; these are the required ones
insert into public.products (id, category_id, name, price) values
  ('a0000000-0000-0000-0000-000000000001', tst.cid(U&'\0627\0644\0623\0644\0628\0627\0646'), 'milk', 1),
  ('a0000000-0000-0000-0000-000000000002', tst.cid(U&'\0627\062C\0628\0627\0646 \0648\0627\0644\0628\0627\0646 \0648\0645\0634\062A\0642\0627\062A\0647\0627'), 'cheese', 2),
  ('a0000000-0000-0000-0000-000000000003', tst.cid(U&'\0645\0646\0638\0641\0627\062A'), 'soap-inactive-old', 3),
  ('a0000000-0000-0000-0000-000000000004', tst.cid(U&'\0627\062E\0631\0649'), 'misc', 4),
  ('a0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'custom-cat-product', 5);

-- ===== apply the migration =====
-- @include 011_category_images.sql
-- @include 012_primary_categories.sql

create function tst.prim(n text) returns uuid language sql as $$ select id from public.categories where name_ar = n and display_order between 1 and 13 $$;
create function tst.pcat(p text) returns text language sql as $$
  select c.name_ar from public.products x join public.categories c on c.id = x.category_id where x.name = p $$;

select tst.check('13 primary categories exist, active, ordered 1..13',
  (select count(*) = 13 and min(display_order) = 1 and max(display_order) = 13 and bool_and(is_active) and count(distinct display_order) = 13
     from public.categories where display_order between 1 and 13));
select tst.check('every primary has a picture',
  (select bool_and(image_url like 'https://images.pexels.com/%') from public.categories where display_order between 1 and 13));
select tst.check('all 39 old categories are now hidden (so the escapes match the real names)',
  (select count(*) = 39 and not bool_or(c.is_active) from public.categories c join tst.before b using (id)),
  (select string_agg(c.name_ar, ' | ') from public.categories c join tst.before b using (id) where c.is_active));
select tst.check('the app sees 13 + the 2 unrelated test categories, nothing else',
  (select count(*) = 15 from public.categories where is_active));
select tst.check('39 aliases, none pointing at itself, all at a primary',
  (select count(*) = 39 and bool_and(c.display_order between 1 and 13) and bool_and(c.name_ar <> a.alias_name_ar)
     from public.category_aliases a join public.categories c on c.id = a.category_id));

select tst.check('milk -> dairy primary', tst.pcat('milk') = U&'\0623\0644\0628\0627\0646 \0648\0623\062C\0628\0627\0646 \0648\0628\064A\0636');
select tst.check('cheese -> same primary (two old categories, one primary)', tst.pcat('cheese') = tst.pcat('milk'));
select tst.check('a product in a hidden old category (soap) still moves, to cleaning', tst.pcat('soap-inactive-old') = U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644');
select tst.check('misc -> the catch-all primary', tst.pcat('misc') = U&'\0645\0646\062A\062C\0627\062A \0645\062A\0646\0648\0639\0629');
select tst.check('a product in a non-POS category is left alone', tst.pcat('custom-cat-product') = 'custom-url-category');
select tst.check('products keep their old category in legacy_category_id',
  (select legacy_category_id = tst.cid(U&'\0627\0644\0623\0644\0628\0627\0646') from public.products where name = 'milk')
  and (select legacy_category_id is null from public.products where name = 'custom-cat-product'));
select tst.check('no product lost', (select count(*) = 5 from public.products));
select tst.check('unrelated categories stay active', (select count(*) = 2 and bool_and(is_active) from public.categories where name_ar in ('custom-url-category','brand-new-category')));

-- ===== re-running changes nothing, and keeps admin edits =====
update public.categories set image_url = 'https://example.com/mine.jpg', image_path = 'categories/x.webp' where id = tst.prim(U&'\0627\0644\0645\0634\0631\0648\0628\0627\062A');
update public.products set category_id = tst.prim(U&'\0642\0647\0648\0629 \0648\0634\0627\064A') where name = 'misc';  -- admin refiles one product by hand
create table tst.snap as select name, category_id, legacy_category_id from public.products;
-- @include 012_primary_categories.sql
select tst.check('re-run: still exactly 13 primaries', (select count(*) = 13 from public.categories where display_order between 1 and 13));
select tst.check('re-run: still 39 aliases', (select count(*) = 39 from public.category_aliases));
select tst.check('re-run: no product changed category or lost its legacy id',
  (select count(*) = 5 from public.products p join tst.snap s using (name) where p.category_id = s.category_id and p.legacy_category_id is not distinct from s.legacy_category_id));
select tst.check('re-run: a dashboard image on a primary survives',
  (select image_url = 'https://example.com/mine.jpg' and image_path = 'categories/x.webp' from public.categories where id = tst.prim(U&'\0627\0644\0645\0634\0631\0648\0628\0627\062A')));
select tst.check('re-run: a product the admin refiled by hand stays where it was put', tst.pcat('misc') = U&'\0642\0647\0648\0629 \0648\0634\0627\064A');

-- ===== the aliases are admin-only =====
set local role anon;
select tst.expect_err('anon cannot read category_aliases', 'select * from public.category_aliases', 'permission denied for table category_aliases');
reset role;
set local role authenticated;
select tst.expect_err('signed-in users cannot read category_aliases', 'select * from public.category_aliases', 'permission denied for table category_aliases');
reset role;

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
