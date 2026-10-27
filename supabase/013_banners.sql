-- ============================================================================
-- Aswaq Altaibat - promo banners for the Home carousel
--
-- Builds on schema.sql. Safe to re-run (one transaction; create-if-missing /
-- upsert / seed-only-when-empty). ASCII-only on purpose (Arabic as Unicode escapes).
--
-- WHAT IT DOES
--   1. public.banners: what the app's Home carousel shows. Each banner can open
--      a category, a product, an external https link, or nothing (target_type).
--      target_id holds the category/product uuid, or the link; the CHECK keeps
--      it consistent with target_type. Only the admin dashboard (service_role)
--      can write; the app (anon / signed-in) can only read ACTIVE banners.
--   2. Storage bucket 'banner-images': PUBLIC, max 3 MiB, JPEG / PNG / WebP.
--      No storage.objects policies on purpose, so only service_role can upload
--      or delete and nobody can list the bucket (same as category-images).
--   3. Three sample banners (Pexels photos, free for commercial use) so the
--      carousel is not empty - seeded ONLY when the table is empty, so editing or
--      deleting them in the dashboard is never undone by re-running this.
--
--   The older sponsors_banners table (003) is left as it is; the app no longer
--   reads it.
-- ============================================================================

begin;

create table if not exists public.banners (
  id            uuid primary key default gen_random_uuid(),
  title         text,
  image_url     text not null,
  image_path    text,                       -- Storage path of an uploaded image (null = external url)
  target_type   text not null default 'none'
                check (target_type in ('none', 'category', 'product', 'link')),
  target_id     text,
  is_active     boolean not null default true,
  display_order integer not null default 0,
  created_at    timestamptz not null default now(),
  constraint banners_target_matches_type check (
       (target_type = 'none'                      and target_id is null)
    or (target_type in ('category', 'product')    and target_id is not null and target_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    or (target_type = 'link'                      and target_id is not null and target_id ~* '^https://[^[:space:]]+$' and length(target_id) <= 2000)
  )
);

create index if not exists idx_banners_active_order
  on public.banners (display_order, created_at) where is_active;

alter table public.banners enable row level security;
revoke all on public.banners from anon, authenticated;
grant select on public.banners to anon, authenticated;

drop policy if exists "Active banners are publicly readable" on public.banners;
create policy "Active banners are publicly readable"
  on public.banners for select
  using (is_active = true);

-- ----------------------------------------------------------------------------
-- Storage bucket for uploaded banner images
-- ----------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('banner-images', 'banner-images', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ----------------------------------------------------------------------------
-- Sample banners (only into an empty table)
-- ----------------------------------------------------------------------------

insert into public.banners (title, image_url, target_type, target_id, display_order)
select v.title, v.image_url,
       -- a sample that points at a category which doesn't exist here just isn't tappable
       case when v.target_type = 'category' and v.target_id is null then 'none' else v.target_type end,
       v.target_id, v.ord
  from (values
  (U&'\062E\0635\0648\0645\0627\062A \064A\0648\0645\064A\0629 \0639\0644\0649 \0627\062D\062A\064A\0627\062C\0627\062A\0643', 'https://images.pexels.com/photos/21582447/pexels-photo-21582447.jpeg?auto=compress&cs=tinysrgb&w=1200&h=520&fit=crop', 'category', (select id::text from public.categories where name_ar = U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631' limit 1), 1),
  (U&'\062E\0636\0627\0631 \0648\0641\0648\0627\0643\0647 \0637\0627\0632\062C\0629 \0643\0644 \064A\0648\0645', 'https://images.pexels.com/photos/868110/pexels-photo-868110.jpeg?auto=compress&cs=tinysrgb&w=1200&h=520&fit=crop', 'none', null, 2),
  (U&'\062A\0648\0635\064A\0644 \0633\0631\064A\0639 \0625\0644\0649 \0628\0627\0628 \0628\064A\062A\0643', 'https://images.pexels.com/photos/7363163/pexels-photo-7363163.jpeg?auto=compress&cs=tinysrgb&w=1200&h=520&fit=crop', 'none', null, 3)
  ) as v(title, image_url, target_type, target_id, ord)
 where not exists (select 1 from public.banners);

notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select count(*) from public.banners;                                  -- 3 (fresh install)
--   select id, public, file_size_limit from storage.buckets where id = 'banner-images';
-- ----------------------------------------------------------------------------
