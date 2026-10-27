-- ============================================================================
-- Aswaq Altaibat - category images (placeholders now, admin uploads later)
--
-- Builds on schema.sql. Safe to re-run (one transaction; create-if-missing /
-- upsert / fill-blanks-only). ASCII-only on purpose: the Arabic category names
-- below are written as SQL Unicode escapes, so nothing depends on the clipboard
-- or terminal encoding (earlier pastes of raw Arabic got garbled).
--
-- WHAT IT DOES
--   1. categories.image_path: the Storage object path of an image uploaded from
--      the admin dashboard. NULL for a placeholder / external image_url. It lets
--      the dashboard delete the old file when an image is replaced or removed.
--   2. Storage bucket 'category-images': PUBLIC (images are served by URL to the
--      app, no sign-in), max 2 MiB, JPEG / PNG / WebP only. No storage.objects
--      policies on purpose: with none, only service_role (the admin dashboard)
--      can upload, replace or delete, and nobody can list the bucket.
--   3. Placeholder photos for the existing categories (Pexels, free for
--      commercial use, no attribution required; 600x600, ~55 KB each). FILL
--      BLANKS ONLY: a category that already has an image_url, or an uploaded
--      image (image_path), is never touched, so re-running this can't undo an
--      image set from the dashboard.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Where an uploaded image lives in Storage
-- ----------------------------------------------------------------------------

alter table public.categories
  add column if not exists image_path text;

comment on column public.categories.image_path is
  'Storage object path in bucket category-images for an image uploaded from the admin dashboard; NULL when image_url is a placeholder or external URL.';

-- ----------------------------------------------------------------------------
-- 2. The public bucket (settings re-applied on every run)
-- ----------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'category-images',
  'category-images',
  true,
  2097152,                                         -- 2 MiB
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ----------------------------------------------------------------------------
-- 3. Placeholder photos for the existing categories (fill blanks only)
-- ----------------------------------------------------------------------------

update public.categories c
   set image_url = v.url
  from (values
    (U&'\0627\0644\0623\0644\0628\0627\0646', 'https://images.pexels.com/photos/5946742/pexels-photo-5946742.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- dairy / milk bottle
    (U&'\0645\062c\0645\062f\0627\062a', 'https://images.pexels.com/photos/6823362/pexels-photo-6823362.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- frozen berries
    (U&'\0627\062c\0628\0627\0646\0020\0648\0627\0644\0628\0627\0646\0020\0648\0645\0634\062a\0642\0627\062a\0647\0627', 'https://images.pexels.com/photos/4187783/pexels-photo-4187783.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- cheese
    (U&'\0627\062e\0631\0649', 'https://images.pexels.com/photos/8805182/pexels-photo-8805182.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- basket of vegetables
    (U&'\0627\062f\0648\0627\062a\0020\0645\0646\0632\0644\064a\0629', 'https://images.pexels.com/photos/28726706/pexels-photo-28726706.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- stainless pots
    (U&'\0627\0644\0628\0647\0627\0631\0627\062a', 'https://images.pexels.com/photos/1340116/pexels-photo-1340116.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- spice powders
    (U&'\0627\0644\0628\0647\0627\0631\062a\0020\0627\0644\0639\0627\0645\0647', 'https://images.pexels.com/photos/678414/pexels-photo-678414.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- spices flat-lay
    (U&'\0627\0644\062e\0628\0632\0020\0648\0627\0644\0643\0639\0643\0020\0628\0627\0646\0648\0627\0639\0647', 'https://images.pexels.com/photos/1383908/pexels-photo-1383908.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- breads
    (U&'\0627\0644\0632\064a\0648\062a\0020\0648\0645\0634\062a\0642\0627\062a\0647\0627', 'https://images.pexels.com/photos/10046938/pexels-photo-10046938.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- oil bottles
    (U&'\0627\0644\0633\0643\0627\0643\0631\0020\0648\0645\0634\062a\0642\0627\062a\0647\0627', 'https://images.pexels.com/photos/5469042/pexels-photo-5469042.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- gummy candy
    (U&'\0627\0644\0642\0647\0648\0629\0020\0648\0627\0644\0634\0627\064a\0020\0648\0645\0634\062a\0642\0627\062a\0647\0627', 'https://images.pexels.com/photos/2642842/pexels-photo-2642842.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- coffee cup
    (U&'\0627\0644\0645\0639\0644\0628\0627\062a', 'https://images.pexels.com/photos/9395018/pexels-photo-9395018.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- canned goods shelf
    (U&'\0627\0644\0645\0646\0638\0641\0627\062a', 'https://images.pexels.com/photos/5217900/pexels-photo-5217900.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- cleaning bottles
    (U&'\0627\0644\0645\064a\0627\0647\0020\0627\0644\0645\0639\062f\0646\064a\0629', 'https://images.pexels.com/photos/11860560/pexels-photo-11860560.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- water bottles
    (U&'\0627\0644\0648\0631\0642\064a\0627\062a\0020\0648\0627\0644\0641\0648\0637\0020\0648\062a\0648\0627\0628\0639\0647\0627', 'https://images.pexels.com/photos/3945257/pexels-photo-3945257.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- paper rolls
    (U&'\0627\064a\0633\0020\0643\0631\064a\0645\0020\0648\0627\0644\0628\0648\0638\0647', 'https://images.pexels.com/photos/1294943/pexels-photo-1294943.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- ice cream cone
    (U&'\0628\0637\0627\0631\064a\0627\062a\0020\0648\0643\0634\0627\0641\0627\062a', 'https://images.pexels.com/photos/1084213/pexels-photo-1084213.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- batteries
    (U&'\0628\064a\0636', 'https://images.pexels.com/photos/12969328/pexels-photo-12969328.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- eggs
    (U&'\062d\0628\0648\0628\0020\0648\0645\0634\062a\0642\0627\062a\0647\0627', 'https://images.pexels.com/photos/6187598/pexels-photo-6187598.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- lentils & pulses
    (U&'\062d\0644\064a\0628\0020\0648\0645\0634\062a\0642\0627\062a\0647', 'https://images.pexels.com/photos/236010/pexels-photo-236010.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- glass of milk
    (U&'\062e\0644\064a\0637\0020\0627\0644\0643\064a\0643\0020\0648\0627\0644\062d\0644\0648\064a\0627\062a\0020\0648\0645\0634\062a\0642\0627\062a\0647\0627', 'https://images.pexels.com/photos/3952054/pexels-photo-3952054.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- baking ingredients
    (U&'\062f\062c\0627\062c', 'https://images.pexels.com/photos/10842249/pexels-photo-10842249.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- chicken
    (U&'\062f\062e\0627\0646\0020\0648\0645\0639\0633\0644', 'https://images.pexels.com/photos/12007437/pexels-photo-12007437.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- hookah
    (U&'\062f\064a\0644\064a\0020\0627\0644\0637\064a\0628\0627\062a', 'https://images.pexels.com/photos/14415371/pexels-photo-14415371.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- deli salad bar
    (U&'\0631\0628\0020\0627\0644\0628\0646\062f\0648\0631\0629', 'https://images.pexels.com/photos/33984941/pexels-photo-33984941.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- tomatoes jar
    (U&'\0634\064a\0628\0633', 'https://images.pexels.com/photos/8023869/pexels-photo-8023869.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- chips
    (U&'\0637\062d\064a\0646\0629', 'https://images.pexels.com/photos/11842139/pexels-photo-11842139.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- hummus / tahini
    (U&'\0639\0633\0644', 'https://images.pexels.com/photos/5634210/pexels-photo-5634210.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- honey jar
    (U&'\0639\0635\0627\0626\0631', 'https://images.pexels.com/photos/34693942/pexels-photo-34693942.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- orange juice
    (U&'\063a\064a\0631\0020\0645\0635\0646\0641', 'https://images.pexels.com/photos/5951182/pexels-photo-5951182.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- supermarket
    (U&'\0644\0648\0627\0632\0645\0020\0627\0644\0634\0648\0627\0621', 'https://images.pexels.com/photos/604660/pexels-photo-604660.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- skewers charcoal
    (U&'\0645\0634\062a\0642\0627\062a\0020\0627\0644\0645\064a\0632\0627\0646', 'https://images.pexels.com/photos/625422/pexels-photo-625422.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- bulk grains sacks
    (U&'\0645\0634\0631\0648\0628\0627\062a\0020\063a\0627\0632\064a\0629', 'https://images.pexels.com/photos/16404143/pexels-photo-16404143.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- cola poured
    (U&'\0646\062b\0631\0628\0627\062a', 'https://images.pexels.com/photos/2161650/pexels-photo-2161650.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- mixed nuts
    (U&'\0633\0643\0627\0643\0631', 'https://images.pexels.com/photos/1906435/pexels-photo-1906435.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- hard candies
    (U&'\0645\0646\0638\0641\0627\062a', 'https://images.pexels.com/photos/5218014/pexels-photo-5218014.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- cleaning pink
    (U&'\0645\0648\0627\062f\0020\0645\0646\0632\0644\064a\0629', 'https://images.pexels.com/photos/10574059/pexels-photo-10574059.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- dish soap & sponge
    (U&'\0645\0639\0644\0628\0627\062a', 'https://images.pexels.com/photos/9898352/pexels-photo-9898352.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),  -- cans in box
    (U&'\0644\062d\0648\0645', 'https://images.pexels.com/photos/5892851/pexels-photo-5892851.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop')  -- raw steak
  ) as v(name_ar, url)
 where c.name_ar = v.name_ar
   and c.image_url is null
   and c.image_path is null;

-- Make PostgREST see the new column immediately.
notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select count(*) filter (where image_url is not null) as with_image,
--          count(*) as total
--     from public.categories;                          -- 39 / 39 (before any uploads)
--   select id, public, file_size_limit, allowed_mime_types
--     from storage.buckets where id = 'category-images';   -- public = true, 2097152
-- ----------------------------------------------------------------------------
