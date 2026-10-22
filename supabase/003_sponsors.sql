-- ============================================================================
-- Aswaq Altaibat — retail media (sponsored banners & promoted products)
-- Builds on schema.sql; run after it. Lets supplier brands (Pepsi, Almarai,
-- Dettol, ...) buy placement, toggled from the admin dashboard, read by the
-- Flutter app's sponsors feature.
-- ============================================================================

create type public.banner_placement as enum ('home', 'in_cart');

create table public.sponsors_banners (
  id               uuid primary key default gen_random_uuid(),
  image_url        text not null,
  title            text,
  sponsor_name     text,              -- null = organic store promo, not paid
  link_product_id  uuid references public.products (id) on delete set null,
  link_category_id uuid references public.categories (id) on delete set null,
  placement        public.banner_placement not null default 'home',
  display_order    integer not null default 0,
  is_active        boolean not null default true,
  starts_at        timestamptz,
  ends_at          timestamptz,
  created_at       timestamptz not null default now()
);

create index idx_sponsors_banners_placement on public.sponsors_banners (placement) where is_active = true;

-- Product placements: "top of search" or "sponsored in category" slots.
create type public.promoted_product_slot as enum ('top_of_search', 'category_top', 'cart_cross_sell');

create table public.promoted_products (
  id             uuid primary key default gen_random_uuid(),
  product_id     uuid not null references public.products (id) on delete cascade,
  sponsor_name   text not null,
  slot           public.promoted_product_slot not null default 'top_of_search',
  category_id    uuid references public.categories (id) on delete cascade, -- required for category_top
  display_order  integer not null default 0,
  is_active      boolean not null default true,
  starts_at      timestamptz,
  ends_at        timestamptz,
  created_at     timestamptz not null default now()
);

create index idx_promoted_products_slot on public.promoted_products (slot) where is_active = true;
create index idx_promoted_products_category on public.promoted_products (category_id);

alter table public.sponsors_banners enable row level security;
alter table public.promoted_products enable row level security;

-- Public catalog data: the mobile app reads active placements with its
-- anon key, same as categories/products. Writes stay service_role-only
-- (admin dashboard), same pattern as the rest of the catalog.
create policy "Active sponsor banners are publicly readable"
  on public.sponsors_banners for select
  using (is_active = true);

create policy "Active promoted products are publicly readable"
  on public.promoted_products for select
  using (is_active = true);
