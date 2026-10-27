-- Tests for 014_product_images.sql (run_local.py reset 008 009 010).
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

-- @include 011_category_images.sql
insert into public.categories (id, name, name_ar) values ('c0000000-0000-0000-0000-000000000001', 'cat', 'cat');
insert into public.categories (id, name, name_ar, image_url) values
  ('c0000000-0000-0000-0000-000000000002', 'canned', U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A', 'https://images.pexels.com/photos/9395018/pexels-photo-9395018.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop');
insert into public.categories (id, name, name_ar, image_url, image_path) values
  ('c0000000-0000-0000-0000-000000000003', 'canned-custom', U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A', 'https://x.supabase.co/storage/mine.webp', 'categories/mine.webp');
insert into public.products (id, category_id, name, price, image_url) values
  ('a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'has-link', 1, 'https://example.com/mine.jpg'),
  ('a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', 'bare', 2, null);

-- @include 014_product_images.sql

select tst.check('products.image_path exists, text, nullable',
  (select data_type = 'text' and is_nullable = 'YES' from information_schema.columns
    where table_schema='public' and table_name='products' and column_name='image_path'));
select tst.check('bucket product-images: public, 2 MiB, jpeg/png/webp only',
  (select public and file_size_limit = 2097152 and cardinality(allowed_mime_types) = 3 and allowed_mime_types @> array['image/webp']
     from storage.buckets where id = 'product-images'));
select tst.check('existing products are untouched',
  (select count(*) = 2 from public.products where image_path is null)
  and (select image_url = 'https://example.com/mine.jpg' from public.products where name = 'has-link')
  and (select image_url is null from public.products where name = 'bare'));

select tst.check('canned-goods placeholder (motor oil) is swapped for the tomato cans',
  (select image_url like 'https://images.pexels.com/photos/18216881/%' from public.categories where id = 'c0000000-0000-0000-0000-000000000002'));
select tst.check('a canned-goods category with its own uploaded picture is untouched',
  (select image_url = 'https://x.supabase.co/storage/mine.webp' and image_path = 'categories/mine.webp' from public.categories where id = 'c0000000-0000-0000-0000-000000000003'));
select tst.check('other categories are untouched', (select image_url is null from public.categories where id = 'c0000000-0000-0000-0000-000000000001'));
update public.categories set image_url = 'https://example.com/chosen-later.jpg' where id = 'c0000000-0000-0000-0000-000000000002';

-- a dashboard upload, then re-run the migration with a drifted bucket
update public.products set image_url = 'https://x/p.webp', image_path = 'products/a.webp' where name = 'bare';
update storage.buckets set public = false, file_size_limit = 1 where id = 'product-images';
-- @include 014_product_images.sql
select tst.check('re-run: an uploaded picture survives', (select image_path = 'products/a.webp' and image_url = 'https://x/p.webp' from public.products where name = 'bare'));
select tst.check('re-run: a picture chosen later for canned goods is not overwritten',
  (select image_url = 'https://example.com/chosen-later.jpg' from public.categories where id = 'c0000000-0000-0000-0000-000000000002'));
select tst.check('re-run: bucket settings repaired', (select public and file_size_limit = 2097152 from storage.buckets where id = 'product-images'));
select tst.check('exactly one product-images bucket', (select count(*) = 1 from storage.buckets where id = 'product-images'));

-- who can do what
create function tst.anon_update_count() returns int language plpgsql as $$
declare n int;
begin
  begin update public.products set image_url = 'https://evil/x.jpg'; get diagnostics n = row_count;
  exception when others then n := 0; end;
  return n;
end $$;
grant execute on function tst.anon_update_count() to anon;
set local role anon;
select tst.check('anon can read products and their picture columns', (select count(*) = 2 and count(image_path) = 1 from public.products));
select tst.check('anon cannot change a product picture (no row is updated)', tst.anon_update_count() = 0);
select tst.expect_err('anon cannot upload to the bucket', $q$insert into storage.objects (bucket_id, name) values ('product-images', 'products/x.webp')$q$, 'new row violates row-level security policy for table "objects"');
reset role;
select tst.check('...and the pictures are unchanged', (select count(*) = 0 from public.products where image_url like 'https://evil%'));
set local role service_role;
update public.products set image_url = null, image_path = null where name = 'bare';
select tst.check('the admin side (service_role) can set and clear pictures', (select image_path is null from public.products where name = 'bare'));
reset role;

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
