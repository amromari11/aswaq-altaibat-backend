-- ============================================================================
-- Aswaq Altaibat - live driver location for order tracking
--
-- Builds on 009. Safe to re-run (one transaction; create-if-missing /
-- create-or-replace / drop-and-recreate). ASCII-only on purpose.
--
-- WHAT IT DOES
--   * order_driver_locations: the driver's last known position for an order
--     (one row per order). Written only by the admin side (service_role) via
--     set_driver_location(); no grants for the app keys.
--   * Every position update is broadcast on the order's Realtime channel
--     'order:<token>' as event 'driver' (same channel and best-effort rules as
--     the status broadcast in 009), so the customer's map moves live.
--   * get_order_tracking() now also returns the delivery pin
--     (delivery_lat / delivery_lng) and, ONLY while the order is
--     out_for_delivery, the driver's position. Once the order moves on
--     (delivered / cancelled / back to preparing) the position is deleted, so a
--     customer can never see where a driver is outside an active delivery.
--
-- A future driver app can call set_driver_location() (grant it to a driver
-- role then); today the admin dashboard does.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. The driver's last known position, one row per order
-- ----------------------------------------------------------------------------

create table if not exists public.order_driver_locations (
  order_id   uuid primary key references public.orders (id) on delete cascade,
  latitude   numeric(9, 6) not null check (latitude  between -90  and 90),
  longitude  numeric(9, 6) not null check (longitude between -180 and 180),
  updated_at timestamptz not null default now()
);

-- Admin-only: RLS on with no policies, and no grants for the app keys.
alter table public.order_driver_locations enable row level security;
revoke all on public.order_driver_locations from anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. set_driver_location(order, lat, lng) - the single way to move the driver
--    Error codes (message = code): invalid_location, order_not_found,
--    not_out_for_delivery.
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
begin
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_location';
  end if;

  select status into v_status from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found';
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

-- Admin side only. The app keys can't move a driver.
revoke all on function public.set_driver_location(uuid, numeric, numeric) from public, anon, authenticated;
grant execute on function public.set_driver_location(uuid, numeric, numeric) to service_role;

-- ----------------------------------------------------------------------------
-- 3. Broadcast each position update on the order's channel (best effort)
-- ----------------------------------------------------------------------------

create or replace function public.broadcast_driver_location()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_token uuid;
begin
  begin
    select tracking_token into v_token from public.orders where id = new.order_id;
    if v_token is not null then
      perform realtime.send(
        jsonb_build_object(
          'order_id',   new.order_id,
          'latitude',   new.latitude,
          'longitude',  new.longitude,
          'updated_at', new.updated_at
        ),
        'driver',
        'order:' || v_token::text,
        false                                   -- public channel; the token is the secret
      );
    end if;
  exception when others then
    null;   -- never fail a location update because a notification failed
  end;
  return new;
end;
$$;

drop trigger if exists trg_driver_location_broadcast on public.order_driver_locations;
create trigger trg_driver_location_broadcast
  after insert or update on public.order_driver_locations
  for each row execute function public.broadcast_driver_location();

-- ----------------------------------------------------------------------------
-- 4. The driver's position only lives while the order is out for delivery
-- ----------------------------------------------------------------------------

create or replace function public.clear_driver_location()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.order_driver_locations where order_id = new.id;
  return new;
end;
$$;

drop trigger if exists trg_orders_clear_driver on public.orders;
create trigger trg_orders_clear_driver
  after update of status on public.orders
  for each row
  when (new.status <> 'out_for_delivery' and old.status is distinct from new.status)
  execute function public.clear_driver_location();

-- ----------------------------------------------------------------------------
-- 5. get_order_tracking: add the delivery pin and (while out for delivery) the
--    driver. Same signature and return type as 009, so create-or-replace.
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
           -- Only while the order is actually out for delivery.
           'driver', case when o.status = 'out_for_delivery' then (
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

-- Make PostgREST see the new objects immediately.
notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select to_regclass('public.order_driver_locations'),
--          to_regprocedure('public.set_driver_location(uuid,numeric,numeric)');                  -- both non-null
--   select count(*) from pg_trigger
--    where tgname in ('trg_driver_location_broadcast', 'trg_orders_clear_driver');               -- 2
-- ----------------------------------------------------------------------------
