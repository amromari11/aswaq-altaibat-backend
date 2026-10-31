-- ============================================================================
-- Aswaq Altaibat - delivery or pickup, now or at a chosen time
--
-- Builds on 009 and 010 (replaces place_order, get_order_tracking,
-- list_orders_summary and set_driver_location). Safe to re-run (one
-- transaction; create-if-missing / drop-and-recreate). ASCII-only.
--
-- WHAT IT DOES
--   1. public.store_settings: ONE row with the pickup branch (name, address,
--      phone, map pin) and the rules for time slots (opening hours, slot length,
--      how far ahead, minimum lead time) and switches for pickup / scheduling.
--      The app reads it to show the branch and the slots; place_order enforces
--      the same values, so the two can never disagree. Admin-only writes.
--      Opening hours are Amman time; closing must be after opening on the same
--      day ('24:00' = midnight). The seeded hours are PLACEHOLDERS - set the
--      real ones from the dashboard's store settings page.
--   2. orders.order_type ('delivery' | 'pickup', existing orders: 'delivery')
--      and orders.scheduled_time (NULL = as soon as possible). A pickup order
--      has no delivery address, zone, pin or fee. orders.address_id (007) is
--      the link to the saved address, and delivery_fee / notes already exist.
--   3. place_order gains p_order_type and p_scheduled_time (both optional, so
--      older app builds keep working: they place delivery-now orders).
--      New error codes: invalid_order_type, pickup_unavailable,
--      scheduling_unavailable, invalid_schedule, store_closed.
--      - delivery: as before (zone, minimum order, fee, free over 20 JOD).
--      - pickup:   fee 0, no zone and no minimum order.
--      - now:      only while the store is open.
--      - later:    a slot start inside opening hours, on a slot boundary, at
--                  least min_lead_minutes away (15 minutes of grace for the
--                  time spent on the checkout screen) and at most
--                  max_days_ahead days ahead.
--   4. get_order_tracking / list_orders_summary also return order_type and
--      scheduled_time; set_driver_location refuses pickup orders.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Store settings (single row)
-- ----------------------------------------------------------------------------

create table if not exists public.store_settings (
  id                   boolean primary key default true check (id),
  branch_name_ar       text not null,
  branch_address_ar    text not null,
  branch_phone         text,
  latitude             numeric(9, 6) not null check (latitude between -90 and 90),
  longitude            numeric(9, 6) not null check (longitude between -180 and 180),
  opens_at             time not null,
  closes_at            time not null,
  pickup_enabled       boolean not null default true,
  scheduling_enabled   boolean not null default true,
  slot_minutes         integer not null default 60 check (slot_minutes in (30, 60, 90, 120)),
  min_lead_minutes     integer not null default 60 check (min_lead_minutes between 0 and 1440),
  max_days_ahead       integer not null default 2 check (max_days_ahead between 0 and 7),
  pickup_ready_minutes integer not null default 20 check (pickup_ready_minutes between 0 and 240),
  updated_at           timestamptz not null default now(),
  constraint store_settings_hours check (closes_at > opens_at)
);

insert into public.store_settings (branch_name_ar, branch_address_ar, latitude, longitude, opens_at, closes_at)
values (U&'\0623\0633\0648\0627\0642 \0627\0644\0637\064A\0628\0627\062A - \0641\0631\0639 \0627\0644\0632\0631\0642\0627\0621', U&'\0627\0644\0632\0631\0642\0627\0621', 32.073313, 36.095312, '08:00', '23:00')
on conflict (id) do nothing;

alter table public.store_settings enable row level security;
revoke all on public.store_settings from anon, authenticated;
grant select on public.store_settings to anon, authenticated;
drop policy if exists "Store settings are publicly readable" on public.store_settings;
create policy "Store settings are publicly readable" on public.store_settings for select using (true);

-- ----------------------------------------------------------------------------
-- 2. Orders: type and time
-- ----------------------------------------------------------------------------

alter table public.orders
  add column if not exists order_type     text not null default 'delivery',
  add column if not exists scheduled_time timestamptz;

alter table public.orders alter column delivery_address drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_order_type_check') then
    alter table public.orders add constraint orders_order_type_check check (order_type in ('delivery', 'pickup'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'orders_delivery_has_address') then
    alter table public.orders add constraint orders_delivery_has_address
      check (order_type = 'pickup' or delivery_address is not null);
  end if;
end $$;

create index if not exists idx_orders_scheduled_time on public.orders (scheduled_time) where scheduled_time is not null;

-- ----------------------------------------------------------------------------
-- 3. place_order with type and time
-- ----------------------------------------------------------------------------

drop function if exists public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text, uuid);

create or replace function public.place_order(
  p_customer_name    text,
  p_customer_phone   text,
  p_items            jsonb,
  p_delivery_address text    default null,
  p_zone_id          uuid    default null,
  p_address_id       uuid    default null,
  p_delivery_lat     numeric default null,
  p_delivery_lng     numeric default null,
  p_notes            text    default null,
  p_tracking_token   uuid    default null,
  p_order_type       text    default 'delivery',
  p_scheduled_time   timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- Mirrors AppConfig.freeDeliveryThresholdJod in the Flutter app.
  free_delivery_threshold constant numeric := 20;
  -- Time between seeing the slots and confirming the order.
  schedule_grace_minutes  constant int := 15;

  v_uid      uuid := auth.uid();
  v_type     text := coalesce(nullif(btrim(p_order_type), ''), 'delivery');
  v_pickup   boolean;
  v_name     text := btrim(coalesce(p_customer_name, ''));
  v_phone    text := regexp_replace(coalesce(p_customer_phone, ''), '[\s-]', '', 'g');
  v_address  text := btrim(coalesce(p_delivery_address, ''));
  v_notes    text := nullif(btrim(coalesce(p_notes, '')), '');
  v_store    public.store_settings%rowtype;
  v_zone     public.delivery_zones%rowtype;
  v_local    timestamp;
  v_minute   int;
  v_open     int;
  v_close    int;
  v_line     record;
  v_lines    jsonb;
  v_subtotal numeric := 0;
  v_fee      numeric;
  v_link_uid uuid;
  v_customer uuid;
  v_order    uuid;
  v_user     uuid;
  v_address_id uuid;
begin
  if v_type not in ('delivery', 'pickup') then
    raise exception 'invalid_order_type';
  end if;
  v_pickup := v_type = 'pickup';

  if char_length(v_name) < 2 or char_length(v_name) > 100 then
    raise exception 'invalid_name';
  end if;
  if v_phone !~ '^\+9627[789][0-9]{7}$' then
    raise exception 'invalid_phone';
  end if;
  if not v_pickup and (char_length(v_address) < 3 or char_length(v_address) > 500) then
    raise exception 'invalid_address';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
    raise exception 'invalid_items';
  end if;

  select * into v_store from public.store_settings where id;
  if not found then
    raise exception 'store_closed';   -- no settings row: nothing to order against
  end if;
  if v_pickup and not v_store.pickup_enabled then
    raise exception 'pickup_unavailable';
  end if;

  -- When: now (store must be open) or a slot start inside opening hours.
  v_open  := extract(epoch from v_store.opens_at)::int / 60;
  v_close := extract(epoch from v_store.closes_at)::int / 60;
  if p_scheduled_time is null then
    v_local  := now() at time zone 'Asia/Amman';
    v_minute := extract(epoch from v_local::time)::int / 60;
    if v_minute < v_open or v_minute >= v_close then
      raise exception 'store_closed';
    end if;
  else
    if not v_store.scheduling_enabled then
      raise exception 'scheduling_unavailable';
    end if;
    v_local  := p_scheduled_time at time zone 'Asia/Amman';
    v_minute := extract(epoch from v_local::time)::int / 60;
    if p_scheduled_time < now() + make_interval(mins => greatest(v_store.min_lead_minutes - schedule_grace_minutes, 0))
       or v_local::date > (now() at time zone 'Asia/Amman')::date + v_store.max_days_ahead
       or extract(second from v_local) <> 0
       or v_minute < v_open
       or v_minute + v_store.slot_minutes > v_close
       or (v_minute - v_open) % v_store.slot_minutes <> 0 then
      raise exception 'invalid_schedule';
    end if;
  end if;

  if not v_pickup then
    select * into v_zone from public.delivery_zones where id = p_zone_id and is_active;
    if not found then
      raise exception 'invalid_zone';
    end if;
  end if;

  -- Validate the shape first, so a malformed id/quantity is a clean
  -- 'invalid_items' rather than a raw cast error.
  if exists (
    select 1 from jsonb_array_elements(p_items) e
     where jsonb_typeof(e) <> 'object'
        or coalesce(e ->> 'product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or coalesce(e ->> 'quantity', '') !~ '^[0-9]{1,3}$'
  ) then
    raise exception 'invalid_items';
  end if;

  -- Collapse duplicate product lines; each product at most 99 per order.
  select jsonb_agg(jsonb_build_object('product_id', product_id, 'quantity', quantity))
    into v_lines
    from (
      select (e ->> 'product_id')::uuid as product_id, sum((e ->> 'quantity')::int) as quantity
        from jsonb_array_elements(p_items) e
       group by 1
    ) agg;
  if exists (select 1 from jsonb_to_recordset(v_lines) as x(product_id uuid, quantity int)
              where quantity < 1 or quantity > 99) then
    raise exception 'invalid_items';
  end if;

  -- Price, stock and subtotal come from the database, not the client.
  for v_line in
    select l.product_id, l.quantity, p.id as found_id, p.is_active, p.stock_status, p.stock_quantity,
           case when p.discount_price is not null and p.discount_price < p.price
                then p.discount_price else p.price end as unit_price
      from jsonb_to_recordset(v_lines) as l(product_id uuid, quantity int)
      left join public.products p on p.id = l.product_id
  loop
    if v_line.found_id is null or not v_line.is_active then
      raise exception 'unknown_product';
    end if;
    if v_line.stock_status = 'out_of_stock' then
      raise exception 'out_of_stock';
    end if;
    -- stock_quantity = 0 with a non-out_of_stock status means "not tracked".
    if v_line.stock_quantity > 0 and v_line.quantity > v_line.stock_quantity then
      raise exception 'insufficient_stock';
    end if;
    v_subtotal := v_subtotal + v_line.unit_price * v_line.quantity;
  end loop;

  if v_pickup then
    v_fee := 0;                        -- collected at the branch: no fee, no minimum
  else
    if v_subtotal < v_zone.min_order_amount then
      raise exception 'below_minimum';
    end if;
    v_fee := case when v_subtotal >= free_delivery_threshold then 0 else v_zone.delivery_fee end;
  end if;

  -- Customer: create or update by phone. Link the signed-in user only if they
  -- aren't already linked to a *different* phone (auth_user_id is unique).
  v_link_uid := case
    when v_uid is not null
     and not exists (select 1 from public.customers where auth_user_id = v_uid and phone_number <> v_phone)
    then v_uid end;

  insert into public.customers (phone_number, full_name, auth_user_id)
  values (v_phone, v_name, v_link_uid)
  on conflict (phone_number) do update
    set full_name    = excluded.full_name,
        auth_user_id = coalesce(public.customers.auth_user_id, excluded.auth_user_id)
  returning id into v_customer;

  -- Light abuse guard: this function is callable without an account.
  if (select count(*) from public.orders
       where customer_id = v_customer and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'too_many_orders';
  end if;

  -- user_id only for a real signed-in user that has a profile row.
  v_user := case when v_uid is not null
                  and exists (select 1 from public.profiles where id = v_uid)
                 then v_uid end;
  -- A saved address is only referenced if it belongs to the signed-in user.
  if not v_pickup then
    select id into v_address_id from public.user_addresses
     where id = p_address_id and user_id = v_uid;
  end if;

  insert into public.orders (
    user_id, customer_id, customer_name, customer_phone,
    subtotal, delivery_fee, total_price,
    delivery_address, delivery_lat, delivery_lng,
    payment_method, notes, zone_id, address_id, tracking_token,
    order_type, scheduled_time
  ) values (
    v_user, v_customer, v_name, v_phone,
    v_subtotal, v_fee, v_subtotal + v_fee,
    case when v_pickup then null else v_address end,
    case when v_pickup then null else p_delivery_lat end,
    case when v_pickup then null else p_delivery_lng end,
    'cash', v_notes,
    case when v_pickup then null else v_zone.id end,
    v_address_id, coalesce(p_tracking_token, gen_random_uuid()),
    v_type, p_scheduled_time
  ) returning id into v_order;

  insert into public.order_items (order_id, product_id, quantity, unit_price, line_total)
  select v_order, l.product_id, l.quantity,
         case when p.discount_price is not null and p.discount_price < p.price
              then p.discount_price else p.price end,
         case when p.discount_price is not null and p.discount_price < p.price
              then p.discount_price else p.price end * l.quantity
    from jsonb_to_recordset(v_lines) as l(product_id uuid, quantity int)
    join public.products p on p.id = l.product_id;

  return v_order;
end;
$$;

revoke all on function public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text, uuid, text, timestamptz) from public;
grant execute on function public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text, uuid, text, timestamptz)
  to anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Tracking and the orders list also say how and when
-- ----------------------------------------------------------------------------

create or replace function public.get_order_tracking(p_order_id uuid, p_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
           'id',               o.id,
           'status',           o.status::text,
           'created_at',       o.created_at,
           'updated_at',       o.updated_at,
           'subtotal',         o.subtotal,
           'delivery_fee',     o.delivery_fee,
           'total_price',      o.total_price,
           'payment_method',   o.payment_method,
           'notes',            o.notes,
           'delivery_address', o.delivery_address,
           'delivery_lat',     o.delivery_lat,
           'delivery_lng',     o.delivery_lng,
           'customer_name',    o.customer_name,
           'zone_name_ar',     z.name_ar,
           'eta_minutes',      z.eta_minutes,
           'order_type',       o.order_type,
           'scheduled_time',   o.scheduled_time,
           -- Only while the order is actually out for delivery.
           'driver', case when o.status = 'out_for_delivery' and o.order_type = 'delivery' then (
             select jsonb_build_object(
                      'latitude',   d.latitude,
                      'longitude',  d.longitude,
                      'updated_at', d.updated_at)
               from public.order_driver_locations d
              where d.order_id = o.id
           ) end,
           'items', coalesce((
             select jsonb_agg(
                      jsonb_build_object(
                        'name_ar',    coalesce(p.name_ar, p.name),
                        'name',       p.name,
                        'unit',       p.unit,
                        'quantity',   oi.quantity,
                        'unit_price', oi.unit_price,
                        'line_total', oi.line_total
                      ) order by oi.created_at, p.name)
               from public.order_items oi
               join public.products p on p.id = oi.product_id
              where oi.order_id = o.id
           ), '[]'::jsonb)
         )
    from public.orders o
    left join public.delivery_zones z on z.id = o.zone_id
   where o.id = p_order_id
     and o.tracking_token = p_token;
$$;

revoke all on function public.get_order_tracking(uuid, uuid) from public;
grant execute on function public.get_order_tracking(uuid, uuid) to anon, authenticated, service_role;

-- New output columns: a changed return type needs drop + create.
drop function if exists public.list_orders_summary(jsonb);
create function public.list_orders_summary(p_refs jsonb)
returns table (
  id uuid, status text, created_at timestamptz, updated_at timestamptz,
  subtotal numeric, delivery_fee numeric, total_price numeric,
  item_count bigint, zone_name_ar text, eta_minutes int,
  order_type text, scheduled_time timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with refs as (
    select case when e ->> 'id'    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                then (e ->> 'id')::uuid end    as id,
           case when e ->> 'token' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                then (e ->> 'token')::uuid end as token
      from jsonb_array_elements(
             case when jsonb_typeof(p_refs) = 'array' then p_refs else '[]'::jsonb end
           ) e
     where jsonb_typeof(e) = 'object'
     limit 50
  )
  select o.id, o.status::text, o.created_at, o.updated_at,
         o.subtotal, o.delivery_fee, o.total_price,
         (select coalesce(sum(oi.quantity), 0) from public.order_items oi where oi.order_id = o.id)::bigint,
         z.name_ar, z.eta_minutes,
         o.order_type, o.scheduled_time
    from refs r
    join public.orders o on o.id = r.id and o.tracking_token = r.token
    left join public.delivery_zones z on z.id = o.zone_id
   order by o.created_at desc;
$$;

revoke all on function public.list_orders_summary(jsonb) from public;
grant execute on function public.list_orders_summary(jsonb) to anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. No driver for a pickup order
-- ----------------------------------------------------------------------------

create or replace function public.set_driver_location(
  p_order_id  uuid,
  p_latitude  numeric,
  p_longitude numeric
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status public.order_status;
  v_type   text;
begin
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_location';
  end if;

  select status, order_type into v_status, v_type from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found';
  end if;
  if v_type = 'pickup' then
    raise exception 'pickup_order';
  end if;
  if v_status <> 'out_for_delivery' then
    raise exception 'not_out_for_delivery';
  end if;

  insert into public.order_driver_locations (order_id, latitude, longitude, updated_at)
  values (p_order_id, round(p_latitude, 6), round(p_longitude, 6), now())
  on conflict (order_id) do update
    set latitude   = excluded.latitude,
        longitude  = excluded.longitude,
        updated_at = excluded.updated_at;
end;
$$;

revoke all on function public.set_driver_location(uuid, numeric, numeric) from public, anon, authenticated;
grant execute on function public.set_driver_location(uuid, numeric, numeric) to service_role;

notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select * from public.store_settings;                                       -- 1 row
--   select count(*) from pg_proc where proname = 'place_order';                -- 1
--   select order_type, count(*) from public.orders group by 1;                 -- all 'delivery' so far
-- ----------------------------------------------------------------------------
