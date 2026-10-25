-- ============================================================================
-- Aswaq Altaibat — align the live delivery_zones / user_addresses with the app
--
-- Supersedes 006. On 2026-10-24 the live project got a *different* version of
-- these two tables than 006 describes (uuid zone ids, `min_order_amount`,
-- `address_line`, 6 real Zarqa neighbourhoods). We're keeping that live
-- version and its zone data, and adding what the app and admin dashboard
-- need on top of it. Do NOT run 006 against the live project.
--
-- Written defensively, because the live tables came from SQL that isn't in
-- this repo: every step either checks the current state or replaces it, and
-- the whole file runs in one transaction — any surprise rolls it all back.
-- Safe to re-run.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0. Preconditions — abort unless the live shape is what we verified
-- ----------------------------------------------------------------------------

do $$
declare
  zone_id_type text;
begin
  if to_regclass('public.delivery_zones') is null or to_regclass('public.user_addresses') is null then
    raise exception 'ABORT: delivery_zones / user_addresses missing';
  end if;

  if (select data_type from information_schema.columns
       where table_schema = 'public' and table_name = 'delivery_zones' and column_name = 'id') <> 'uuid' then
    raise exception 'ABORT: delivery_zones.id is not uuid — this is not the live schema 007 was written for';
  end if;

  select data_type into zone_id_type from information_schema.columns
   where table_schema = 'public' and table_name = 'user_addresses' and column_name = 'zone_id';
  if zone_id_type is distinct from 'uuid' then
    raise exception 'ABORT: user_addresses.zone_id is %, expected uuid', zone_id_type;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'delivery_zones' and column_name = 'min_order_amount')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'user_addresses' and column_name = 'address_line') then
    raise exception 'ABORT: expected live columns min_order_amount / address_line not found';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. DELIVERY_ZONES — add ETA, ordering, updated_at
--    Live names are kept as-is (min_order_amount, uuid id); the app adapts.
-- ----------------------------------------------------------------------------

alter table public.delivery_zones
  add column if not exists eta_minutes   integer,
  add column if not exists display_order integer not null default 0,
  add column if not exists updated_at    timestamptz not null default now();

-- Placeholder ETAs scaled by delivery fee (cheaper zone = closer to the
-- store) — confirm real values with the store. Only fills blanks, so a
-- re-run never overwrites values set later from the admin dashboard.
update public.delivery_zones
   set eta_minutes = case
         when delivery_fee <= 1.00 then 25
         when delivery_fee <= 1.25 then 30
         else 35
       end
 where eta_minutes is null;

alter table public.delivery_zones
  alter column eta_minutes set not null,
  alter column eta_minutes set default 30;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'delivery_zones_eta_minutes_check') then
    alter table public.delivery_zones
      add constraint delivery_zones_eta_minutes_check check (eta_minutes > 0);
  end if;
end $$;

-- Order the list cheapest/closest first, then by name; only for rows still
-- at the default, so manual ordering from the dashboard survives a re-run.
with ranked as (
  select id, row_number() over (order by delivery_fee, min_order_amount, name_ar) as rn
    from public.delivery_zones
)
update public.delivery_zones z
   set display_order = r.rn
  from ranked r
 where z.id = r.id and z.display_order = 0;

drop trigger if exists trg_delivery_zones_updated_at on public.delivery_zones;
create trigger trg_delivery_zones_updated_at
  before update on public.delivery_zones
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. USER_ADDRESSES — add label, integrity rules, one default per user
--    address_line stays the free-text street/building/landmark field.
-- ----------------------------------------------------------------------------

alter table public.user_addresses
  add column if not exists label text not null default 'المنزل';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_addresses_label_not_blank') then
    alter table public.user_addresses
      add constraint user_addresses_label_not_blank check (length(trim(label)) > 0);
  end if;

  -- Map pin is optional, but never half a pin.
  if not exists (select 1 from pg_constraint where conname = 'user_addresses_pin_complete') then
    alter table public.user_addresses
      add constraint user_addresses_pin_complete check ((latitude is null) = (longitude is null));
  end if;

  -- Foreign keys, only if the live table doesn't already have them.
  if not exists (
    select 1 from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
     where c.conrelid = 'public.user_addresses'::regclass and c.contype = 'f' and a.attname = 'user_id'
  ) then
    alter table public.user_addresses
      add constraint user_addresses_user_id_fkey
      foreign key (user_id) references public.profiles (id) on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
     where c.conrelid = 'public.user_addresses'::regclass and c.contype = 'f' and a.attname = 'zone_id'
  ) then
    alter table public.user_addresses
      add constraint user_addresses_zone_id_fkey
      foreign key (zone_id) references public.delivery_zones (id) on delete restrict;
  end if;
end $$;

alter table public.user_addresses
  alter column user_id set not null,
  alter column zone_id set not null;

create index if not exists idx_user_addresses_user_id on public.user_addresses (user_id);

create unique index if not exists uq_user_addresses_one_default
  on public.user_addresses (user_id)
  where is_default;

-- Marking an address default clears the flag on that user's others first,
-- so the app can just write is_default = true without tripping the unique
-- index. Security invoker: RLS still limits it to the caller's own rows.
create or replace function public.clear_other_default_addresses()
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

drop trigger if exists trg_user_addresses_single_default on public.user_addresses;
create trigger trg_user_addresses_single_default
  before insert or update of is_default on public.user_addresses
  for each row execute function public.clear_other_default_addresses();

drop trigger if exists trg_user_addresses_updated_at on public.user_addresses;
create trigger trg_user_addresses_updated_at
  before update on public.user_addresses
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 3. RLS — replace whatever policies the live tables came with
--    Postgres ORs permissive policies together, so an unknown "allow all"
--    left in place would silently defeat ours. Drop every existing policy on
--    these two tables, then define exactly the intended set.
-- ----------------------------------------------------------------------------

do $$
declare
  p record;
begin
  for p in
    select policyname, tablename from pg_policies
     where schemaname = 'public' and tablename in ('delivery_zones', 'user_addresses')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

alter table public.delivery_zones enable row level security;
alter table public.user_addresses enable row level security;

-- Catalog-style: app reads active zones with the anon key; writes are
-- service_role-only (admin dashboard), same as categories/products.
create policy "Active delivery zones are publicly readable"
  on public.delivery_zones for select
  using (is_active = true);

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
-- 4. ORDERS — link each order to its zone/address for the admin dashboard
--    delivery_address / delivery_lat / delivery_lng stay the snapshot of
--    record; these are for filtering/reporting by zone.
-- ----------------------------------------------------------------------------

alter table public.orders
  add column if not exists zone_id    uuid references public.delivery_zones (id) on delete set null,
  add column if not exists address_id uuid references public.user_addresses (id) on delete set null;

create index if not exists idx_orders_zone_id on public.orders (zone_id);

-- Make PostgREST see the new columns immediately.
notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running (expect: 6 zones all with eta_minutes, 5 policies,
-- 2 new orders columns):
--   select name_ar, delivery_fee, min_order_amount, eta_minutes, display_order
--     from public.delivery_zones order by display_order;
--   select tablename, policyname, cmd from pg_policies
--    where tablename in ('delivery_zones', 'user_addresses') order by 1, 2;
--   select column_name from information_schema.columns
--    where table_name = 'orders' and column_name in ('zone_id', 'address_id');
-- ----------------------------------------------------------------------------
