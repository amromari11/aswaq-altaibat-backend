-- ============================================================================
-- Aswaq Altaibat - product images (admin uploads, one by one or in bulk)
--
-- Builds on schema.sql and 011 (categories.image_path). Safe to re-run (one transaction; create-if-missing /
-- upsert). ASCII-only. Same design as category-images (011).
--
-- WHAT IT DOES
--   1. products.image_path: the Storage object path of a picture uploaded from
--      the admin dashboard (NULL when there is no picture, or image_url is an
--      external link). It lets the dashboard delete the old file when a picture
--      is replaced or removed. products.image_url already exists and is what the
--      app shows; products with neither get a category-based fallback picture.
--   2. Storage bucket 'product-images': PUBLIC (served by URL to the app), max
--      2 MiB, JPEG / PNG / WebP only. No storage.objects policies on purpose:
--      only service_role (the dashboard) can upload or delete; nobody can list
--      the bucket.
--   3. The "canned goods" category photo set by 012 turned out to be a shelf of motor-oil
--      cans, which looks wrong on every canned-food product card that borrows it. It is
--      swapped for a tomato-can photo - ONLY if the category still has that exact
--      original placeholder (never a picture set from the dashboard).
--   Nothing is changed for existing products.
-- ============================================================================

begin;

alter table public.products
  add column if not exists image_path text;

comment on column public.products.image_path is
  'Storage path (bucket product-images) of an image uploaded from the admin dashboard; NULL for no image or an external image_url.';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

update public.categories
   set image_url = 'https://images.pexels.com/photos/18216881/pexels-photo-18216881.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'
 where name_ar = U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A'
   and image_path is null
   and image_url like 'https://images.pexels.com/photos/9395018/%';

notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select column_name from information_schema.columns
--    where table_schema = 'public' and table_name = 'products' and column_name = 'image_path';   -- 1 row
--   select id, public, file_size_limit from storage.buckets where id = 'product-images';           -- public, 2097152
-- ----------------------------------------------------------------------------
