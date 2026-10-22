-- ============================================================================
-- Aswaq Altaibat — delivery zones & saved customer addresses
-- Builds on schema.sql; run after it. Intended to run after 004 as well
-- (money columns here are numeric(10,3) to match), but doesn't depend on it.
--
-- Backs the Flutter app's location feature, which currently uses a static
-- zone list (lib/features/location/data/repositories/zones_repository.dart)
-- and in-memory saved addresses. Zone ids below match that file exactly so
-- the app can switch to reading this table without any id mapping.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. DELIVERY_ZONES  (catalog-style: public read, admin-only write)
-- ----------------------------------------------------------------------------

create table public.delivery_zones (
  id              text primary key,                     -- stable slug, e.g. 'new_zarqa'
  name_ar         text not null,
  name_en         text,
  delivery_fee    numeric(10, 3) not null check (delivery_fee >= 0),
  min_order       numeric(10, 3) not null default 0 check (min_order >= 0),
  eta_minutes     integer not null check (eta_minutes > 0),
  display_order   integer not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger trg_delivery_zones_updated_at
  before update on public.delivery_zones
  for each row execute function public.set_updated_at();

alter table public.delivery_zones enable row level security;

-- Same pattern as categories/products: the app reads active zones with its
-- anon key; writes stay service_role-only (admin dashboard).
create policy "Active delivery zones are publicly readable"
  on public.delivery_zones for select
  using (is_active = true);

-- Placeholder fees/minimums, identical to the app's current static list —
-- confirm real values with the store and adjust from the admin dashboard.
insert into public.delivery_zones (id, name_ar, name_en, delivery_fee, min_order, eta_minutes, display_order) values
  ('zarqa_center', 'وسط الزرقاء',     'Zarqa Center', 1.000,  5.000, 25, 1),
  ('new_zarqa',    'الزرقاء الجديدة', 'New Zarqa',    1.500,  8.000, 35, 2),
  ('hashmiyya',    'الهاشمية',        'Hashmiyya',    2.000, 10.000, 45, 3),
  ('russeifa',     'الرصيفة',         'Russeifa',     1.500,  8.000, 35, 4),
  ('awajan',       'عوجان',           'Awajan',       1.500,  8.000, 35, 5),
  ('sukhna',       'السخنة',          'Sukhna',       2.500, 12.000, 55, 6)
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- 2. USER_ADDRESSES  (per-user, RLS on auth.uid() like cart_items/orders)
-- ----------------------------------------------------------------------------

create table public.user_addresses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  label       text not null check (length(trim(label)) > 0),   -- 'المنزل', 'العمل', ...
  zone_id     text not null references public.delivery_zones (id) on delete restrict,
  details     text not null check (length(trim(details)) > 0), -- street / building / landmark
  latitude    numeric(9, 6),
  longitude   numeric(9, 6),
  is_default  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- Map pin is optional, but never half a pin.
  check ((latitude is null) = (longitude is null))
);

create index idx_user_addresses_user_id on public.user_addresses (user_id);

-- At most one default address per user.
create unique index uq_user_addresses_one_default
  on public.user_addresses (user_id)
  where is_default;

create trigger trg_user_addresses_updated_at
  before update on public.user_addresses
  for each row execute function public.set_updated_at();

-- Marking an address default clears the flag on that user's others first,
-- so the app can just insert/update with is_default = true (matching
-- SavedAddressesNotifier.upsert) without tripping uq_user_addresses_one_default.
-- Runs as the caller (security invoker), so RLS still limits it to their rows.
create function public.clear_other_default_addresses()
returns trigger
language plpgsql
as $$
begin
  if new.is_default then
    update public.user_addresses
       set is_default = false
     where user_id = new.user_id
       and id <> new.id
       and is_default;
  end if;
  return new;
end;
$$;

create trigger trg_user_addresses_single_default
  before insert or update of is_default on public.user_addresses
  for each row execute function public.clear_other_default_addresses();

alter table public.user_addresses enable row level security;

create policy "Users can view their own addresses"
  on public.user_addresses for select
  using (auth.uid() = user_id);

create policy "Users can insert their own addresses"
  on public.user_addresses for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own addresses"
  on public.user_addresses for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users can delete their own addresses"
  on public.user_addresses for delete
  using (auth.uid() = user_id);

-- ----------------------------------------------------------------------------
-- 3. ORDERS  — link each order to its zone/address for the admin dashboard
-- ----------------------------------------------------------------------------
-- delivery_address / delivery_lat / delivery_lng stay the source of truth
-- (a snapshot at order time — the customer can edit or delete the saved
-- address later). These two columns are for filtering/reporting by zone.

alter table public.orders
  add column zone_id    text references public.delivery_zones (id) on delete set null,
  add column address_id uuid references public.user_addresses (id) on delete set null;

create index idx_orders_zone_id on public.orders (zone_id);

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select id, name_ar, delivery_fee, min_order from public.delivery_zones order by display_order;  -- 6 rows
--   select to_regclass('public.user_addresses');                                                   -- not null
--   select column_name from information_schema.columns
--    where table_name = 'orders' and column_name in ('zone_id', 'address_id');                     -- 2 rows
-- ----------------------------------------------------------------------------
