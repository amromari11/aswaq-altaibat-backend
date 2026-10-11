-- ============================================================================
-- Aswaq Altaibat — Supabase (PostgreSQL) schema
-- Tables: profiles, categories, products, orders, order_items
-- ============================================================================

-- gen_random_uuid() lives in pgcrypto; Supabase projects have it enabled by
-- default, but this is harmless if it's already on.
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. PROFILES  (extends Supabase's built-in auth.users with app-specific data)
-- ----------------------------------------------------------------------------
-- Supabase Auth already creates/manages auth.users (email, phone, password
-- hash, etc). We never duplicate that here — profiles.id IS auth.users.id,
-- and this table only holds the extra fields the app needs, including the
-- loyalty points balance that makes the app feel "exclusive".

create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  full_name        text,
  phone_number     text unique,
  avatar_url       text,
  loyalty_points   integer not null default 0 check (loyalty_points >= 0),
  default_address  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.profiles is 'One row per customer, 1:1 with auth.users.';

-- Auto-create a profile row the moment someone signs up.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 2. CATEGORIES  (Dairy, Snacks, Meat, ...)
-- ----------------------------------------------------------------------------

create table public.categories (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  name_ar        text,                 -- Arabic label for the UI
  image_url      text,
  display_order  integer not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 3. PRODUCTS
-- ----------------------------------------------------------------------------

create type public.stock_status as enum ('in_stock', 'low_stock', 'out_of_stock');

create table public.products (
  id               uuid primary key default gen_random_uuid(),
  category_id      uuid not null references public.categories (id) on delete restrict,
  name             text not null,
  name_ar          text,
  description      text,
  sku              text unique,
  image_url        text,
  unit             text,                               -- 'kg', 'pack', 'liter', 'pc'
  price            numeric(10, 2) not null check (price >= 0),
  discount_price   numeric(10, 2) check (discount_price >= 0 and discount_price <= price),
  stock_quantity   integer not null default 0 check (stock_quantity >= 0),
  stock_status     public.stock_status not null default 'in_stock',
  is_weekly_offer  boolean not null default false,      -- shows in "This Week's Offers"
  is_app_exclusive boolean not null default false,       -- shows in "App Exclusive" shelf
  is_active        boolean not null default true,        -- soft-hide instead of deleting
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index idx_products_category_id on public.products (category_id);
create index idx_products_weekly_offer on public.products (is_weekly_offer) where is_weekly_offer = true;
create index idx_products_exclusive on public.products (is_app_exclusive) where is_app_exclusive = true;

-- ----------------------------------------------------------------------------
-- 4. ORDERS
-- ----------------------------------------------------------------------------

create type public.order_status as enum (
  'pending', 'confirmed', 'preparing', 'out_for_delivery', 'delivered', 'cancelled'
);

create table public.orders (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references public.profiles (id) on delete restrict,
  status                 public.order_status not null default 'pending',
  subtotal               numeric(10, 2) not null default 0 check (subtotal >= 0),
  delivery_fee           numeric(10, 2) not null default 0 check (delivery_fee >= 0),
  discount_amount        numeric(10, 2) not null default 0 check (discount_amount >= 0),
  total_price            numeric(10, 2) not null default 0 check (total_price >= 0),
  loyalty_points_earned  integer not null default 0,
  loyalty_points_redeemed integer not null default 0,
  delivery_address       text not null,
  delivery_lat           numeric(9, 6),
  delivery_lng           numeric(9, 6),
  payment_method         text not null default 'cash',  -- 'cash', 'card'
  notes                  text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index idx_orders_user_id on public.orders (user_id);
create index idx_orders_status on public.orders (status);

-- ----------------------------------------------------------------------------
-- 5. ORDER_ITEMS  (junction: orders <-> products)
-- ----------------------------------------------------------------------------

create table public.order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders (id) on delete cascade,
  product_id  uuid not null references public.products (id) on delete restrict,
  quantity    integer not null check (quantity > 0),
  unit_price  numeric(10, 2) not null check (unit_price >= 0), -- price at time of order
  line_total  numeric(10, 2) not null check (line_total >= 0), -- quantity * unit_price
  created_at  timestamptz not null default now()
);

create index idx_order_items_order_id on public.order_items (order_id);
create index idx_order_items_product_id on public.order_items (product_id);

-- ----------------------------------------------------------------------------
-- updated_at helper trigger, reused by profiles / products / orders
-- ----------------------------------------------------------------------------

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger trg_products_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

create trigger trg_orders_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- ============================================================================
-- Row Level Security — locks the database down for the mobile app's anon/
-- authenticated keys. The Streamlit admin dashboard uses the service_role
-- key instead, which bypasses RLS entirely, so none of this restricts it.
-- ============================================================================

alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Categories & products: public catalog, readable by anyone (even logged out).
create policy "Categories are publicly readable"
  on public.categories for select
  using (true);

create policy "Active products are publicly readable"
  on public.products for select
  using (is_active = true);

-- Profiles: a customer can only see/update their own row.
create policy "Users can view their own profile"
  on public.profiles for select
  using (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- Orders: a customer can only see/create their own orders.
create policy "Users can view their own orders"
  on public.orders for select
  using (auth.uid() = user_id);

create policy "Users can create their own orders"
  on public.orders for insert
  with check (auth.uid() = user_id);

-- Order items: visible only through an order the customer owns.
create policy "Users can view their own order items"
  on public.order_items for select
  using (
    exists (
      select 1 from public.orders
      where orders.id = order_items.order_id
        and orders.user_id = auth.uid()
    )
  );

create policy "Users can insert items on their own orders"
  on public.order_items for insert
  with check (
    exists (
      select 1 from public.orders
      where orders.id = order_items.order_id
        and orders.user_id = auth.uid()
    )
  );
