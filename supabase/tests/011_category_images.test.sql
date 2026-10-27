-- Tests for 011_category_images.sql (apply 008-010 first: run_local.py reset 008 009 010).
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

-- ===== apply the migration =====
-- @include 011_category_images.sql

select tst.check('categories.image_path exists, text, nullable',
  (select data_type = 'text' and is_nullable = 'YES' from information_schema.columns
    where table_schema='public' and table_name='categories' and column_name='image_path'));

select tst.check('bucket category-images exists, public, 2 MiB, jpeg/png/webp only',
  (select public and file_size_limit = 2097152 and allowed_mime_types @> array['image/jpeg','image/png','image/webp']
      and cardinality(allowed_mime_types) = 3 from storage.buckets where id = 'category-images'));

select tst.check('all 39 live categories received a placeholder (the escapes match the real names)',
  (select count(*) = 39 and bool_and(c.image_url is not null) from public.categories c join tst.before b using (id)),
  (select string_agg(b.name_ar, ' | ') from tst.before b join public.categories c using (id) where c.image_url is null));

select tst.check('every placeholder is a distinct 600x600 Pexels URL',
  (select count(distinct image_url) = 39
      and bool_and(image_url ~ '^https://images\.pexels\.com/photos/[0-9]+/pexels-photo-[0-9]+\.jpeg\?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop$')
   from public.categories c join tst.before b using (id)));

select tst.check('spot checks: dairy, mineral water and meat get the intended photos',
  (select count(*) = 3 and bool_and(case name_ar
      when 'الألبان' then image_url like '%/5946742/%'
      when 'المياه المعدنية' then image_url like '%/11860560/%'
      when 'لحوم' then image_url like '%/5892851/%' end)
   from public.categories where name_ar in ('الألبان', 'المياه المعدنية', 'لحوم')));

select tst.check('similar names get different photos (الألبان / حليب ومشتقاته / اجبان…)',
  (select count(distinct image_url) = 3 from public.categories where name_ar in ('الألبان', 'حليب ومشتقاته', 'اجبان والبان ومشتقاتها')));

select tst.check('fill blanks only: a category with its own image_url keeps it',
  (select image_url = 'https://example.com/my-own.jpg' from public.categories where id = '11111111-1111-1111-1111-111111111111'));
select tst.check('a category the migration does not know stays empty',
  (select image_url is null from public.categories where id = '33333333-3333-3333-3333-333333333333'));

-- ===== a dashboard upload later replaces a placeholder; re-running must not undo it =====
-- a mapped category with an uploaded image_path but no image_url (edge: url cleared by hand)
update public.categories set image_url = null, image_path = 'categories/dajaj/uploaded.webp' where name_ar = 'دجاج';
update public.categories set image_url = 'https://x.supabase.co/storage/v1/object/public/category-images/categories/a/b.webp', image_path = 'categories/a/b.webp'
 where name_ar = 'عسل';
update storage.buckets set public = false, file_size_limit = 1, allowed_mime_types = array['text/plain'] where id = 'category-images';
-- @include 011_category_images.sql

select tst.check('fill blanks only: a mapped category with an uploaded image_path is not given a placeholder',
  (select image_url is null and image_path = 'categories/dajaj/uploaded.webp' from public.categories where name_ar = 'دجاج'));
select tst.check('re-running keeps an image uploaded from the dashboard',
  (select image_path = 'categories/a/b.webp' and image_url like '%category-images%' from public.categories where name_ar = 'عسل'));
select tst.check('re-running repairs bucket settings that drifted',
  (select public and file_size_limit = 2097152 and cardinality(allowed_mime_types) = 3 from storage.buckets where id = 'category-images'));
select tst.check('re-running leaves exactly one bucket', (select count(*) = 1 from storage.buckets where id = 'category-images'));
select tst.check('re-running does not touch the other placeholders (39 minus the two uploaded ones)',
  (select count(*) = 37 from public.categories c join tst.before b using (id) where c.image_url like 'https://images.pexels.com/%'),
  (select count(*)::text from public.categories c join tst.before b using (id) where c.image_url like 'https://images.pexels.com/%'));

-- ===== who can do what =====
set local role anon;
select tst.check('the app can read image_url and image_path', (select count(*) >= 39 and bool_or(image_url is not null) from public.categories));
update public.categories set image_url = 'https://evil.example/x.jpg';
select tst.check('the app cannot change a category image', (select count(*) = 0 from public.categories where image_url like 'https://evil%'));
select tst.expect_err('the app cannot add categories', $q$insert into public.categories (name) values ('x')$q$, 'new row violates row-level security policy for table "categories"');
select tst.expect_err('the app cannot upload files', $q$insert into storage.objects (bucket_id, name) values ('category-images', 'categories/x.webp')$q$, 'new row violates row-level security policy for table "objects"');
reset role;
insert into storage.objects (bucket_id, name) values ('category-images', 'categories/real.webp');
set local role anon;
select tst.check('the app cannot list or read bucket contents through the API (no storage policies)', (select count(*) = 0 from storage.objects));
reset role;

set local role service_role;
update public.categories set image_url = 'https://x/new.webp', image_path = 'categories/new.webp' where id = '33333333-3333-3333-3333-333333333333';
reset role;
select tst.check('the admin side (service_role) can set an image', (select image_path = 'categories/new.webp' from public.categories where id = '33333333-3333-3333-3333-333333333333'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
