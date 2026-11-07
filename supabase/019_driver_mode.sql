-- ============================================================================
-- Aswaq Altaibat - driver mode
--
-- Builds on 009 (tracking broadcast), 015 (store_settings, order_type) and 016
-- (orders.driver_name / driver_phone). Safe to re-run (one transaction;
-- add-if-missing / create-or-replace). ASCII-only.
--
-- WHAT IT DOES
--   1. profiles.role ('customer' | 'driver' | 'admin', default customer) and
--      profiles.is_available, plus paused_for_delivery (set when a pick-up turned
--      availability off automatically, so delivering the last order can turn it
--      back on without overriding a driver who switched off on purpose).
--   2. Closes a hole: the app could UPDATE any column of its own profile row,
--      loyalty_points included (and, with this migration, role). App keys may now
--      update only full_name, phone_number, avatar_url and default_address.
--      The admin dashboard (service_role) is unaffected.
--   3. orders.driver_id (must be a driver), picked_up_at, delivered_at, paid_at.
--   4. store_settings.points_per_jod: loyalty points per whole JOD of the order's
--      goods (subtotal minus discount; delivery fee excluded). Default 1.
--   5. Driver functions (signed-in drivers only; SECURITY DEFINER, RLS untouched):
--        driver_set_available(bool)      -> the toggle the admin sees live
--        driver_assigned_orders()        -> my delivery orders not yet delivered/cancelled
--        driver_pick_up(order)           -> out_for_delivery (customer's tracking
--                                           screen updates through 009's broadcast)
--        driver_mark_delivered(order)    -> delivered, paid_at, loyalty points
--   6. A best-effort Realtime ping on channel 'driver:<driver id>' (event
--      'orders', empty payload) whenever an order is assigned to / taken from a
--      driver or changes status, so the driver's list refreshes by itself.
--
-- Errors are raised as plain codes (message = code): not_signed_in,
-- not_a_driver, order_not_found, not_a_delivery, invalid_status.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Roles and availability on profiles
-- ----------------------------------------------------------------------------

alter table public.profiles
  add column if not exists role                 text not null default 'customer',
  add column if not exists is_available         boolean not null default false,
  add column if not exists paused_for_delivery  boolean not null default false,
  add column if not exists available_changed_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_role_valid') then
    alter table public.profiles add constraint profiles_role_valid
      check (role in ('customer', 'driver', 'admin'));
  end if;
end $$;

create index if not exists idx_profiles_drivers on public.profiles (is_available) where role = 'driver';

-- ----------------------------------------------------------------------------
-- 2. The app may only edit its own contact fields
-- ----------------------------------------------------------------------------

revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone_number, avatar_url, default_address) on public.profiles to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Driver assignment and delivery timestamps on orders
-- ----------------------------------------------------------------------------

alter table public.orders
  add column if not exists driver_id    uuid references public.profiles (id) on delete set null,
  add column if not exists picked_up_at timestamptz,
  add column if not exists delivered_at timestamptz,
  add column if not exists paid_at      timestamptz;

create index if not exists idx_orders_driver_active on public.orders (driver_id)
  where driver_id is not null and status not in ('delivered', 'cancelled');

create or replace function public.check_order_driver()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.driver_id is not null
     and (tg_op = 'INSERT' or new.driver_id is distinct from old.driver_id)
     and not exists (select 1 from public.profiles where id = new.driver_id and role = 'driver') then
    raise exception 'not_a_driver';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_check_driver on public.orders;
create trigger trg_orders_check_driver
  before insert or update of driver_id on public.orders
  for each row execute function public.check_order_driver();

-- ----------------------------------------------------------------------------
-- 4. Loyalty rate
-- ----------------------------------------------------------------------------

alter table public.store_settings
  add column if not exists points_per_jod numeric(6, 2) not null default 1;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'store_settings_points_rate') then
    alter table public.store_settings add constraint store_settings_points_rate
      check (points_per_jod between 0 and 100);
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 5. Driver functions
-- ----------------------------------------------------------------------------

-- The caller's id if they are a signed-in driver; raises otherwise.
create or replace function public.require_driver()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_signed_in';
  end if;
  if not exists (select 1 from public.profiles where id = v_uid and role = 'driver') then
    raise exception 'not_a_driver';
  end if;
  return v_uid;
end;
$$;

revoke all on function public.require_driver() from public, anon, authenticated;

create or replace function public.driver_set_available(p_available boolean)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_driver();
begin
  update public.profiles
     set is_available = coalesce(p_available, false),
         paused_for_delivery = false,          -- a manual choice always wins
         available_changed_at = now()
   where id = v_uid;
  return coalesce(p_available, false);
end;
$$;

drop function if exists public.driver_assigned_orders();
create function public.driver_assigned_orders()
returns table (
  id uuid, status text, order_type text, created_at timestamptz, scheduled_time timestamptz,
  picked_up_at timestamptz, customer_name text, customer_phone text, delivery_address text,
  delivery_lat numeric, delivery_lng numeric, zone_name_ar text, notes text,
  subtotal numeric, delivery_fee numeric, discount_amount numeric, total_price numeric,
  payment_method text, loyalty_points_redeemed integer, item_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_driver();
begin
  return query
  select o.id, o.status::text, o.order_type, o.created_at, o.scheduled_time,
         o.picked_up_at, o.customer_name, o.customer_phone, o.delivery_address,
         o.delivery_lat, o.delivery_lng, z.name_ar, o.notes,
         o.subtotal, o.delivery_fee, o.discount_amount, o.total_price,
         o.payment_method, o.loyalty_points_redeemed,
         (select coalesce(sum(oi.quantity), 0) from public.order_items oi where oi.order_id = o.id)::bigint
    from public.orders o
    left join public.delivery_zones z on z.id = o.zone_id
   where o.driver_id = v_uid
     and o.status not in ('delivered', 'cancelled')
     and coalesce(o.order_type, 'delivery') = 'delivery'
   order by (o.status = 'out_for_delivery') desc, coalesce(o.scheduled_time, o.created_at), o.id;
end;
$$;

create or replace function public.driver_pick_up(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.require_driver();
  v_order public.orders%rowtype;
  v_prof  public.profiles%rowtype;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.driver_id is distinct from v_uid then
    raise exception 'order_not_found';
  end if;
  if coalesce(v_order.order_type, 'delivery') <> 'delivery' then
    raise exception 'not_a_delivery';
  end if;
  if v_order.status = 'out_for_delivery' then
    return 'out_for_delivery';                -- already picked up; a double tap is harmless
  end if;
  if v_order.status not in ('pending', 'confirmed', 'preparing') then
    raise exception 'invalid_status';
  end if;

  select * into v_prof from public.profiles where id = v_uid;

  -- The customer's tracking screen shows driver_name / driver_phone (016); fill
  -- them from the driver's profile unless the shop already set them, and only
  -- with values that pass 016's checks.
  update public.orders
     set status       = 'out_for_delivery',
         picked_up_at = now(),
         driver_name  = coalesce(driver_name,
                          case when char_length(btrim(coalesce(v_prof.full_name, ''))) between 2 and 60
                               then btrim(v_prof.full_name) end),
         driver_phone = coalesce(driver_phone,
                          case when v_prof.phone_number ~ '^\+9627[789][0-9]{7}$'
                               then v_prof.phone_number end)
   where id = p_order_id;

  -- On a delivery now: pause availability, remembering it was automatic.
  update public.profiles
     set is_available = false, paused_for_delivery = true, available_changed_at = now()
   where id = v_uid and is_available;

  return 'out_for_delivery';
end;
$$;

create or replace function public.driver_mark_delivered(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.require_driver();
  v_order  public.orders%rowtype;
  v_rate   numeric;
  v_points integer := 0;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.driver_id is distinct from v_uid then
    raise exception 'order_not_found';
  end if;
  if v_order.status = 'delivered' then
    return jsonb_build_object('points_awarded', 0, 'already_delivered', true,
                              'available', (select is_available from public.profiles where id = v_uid));
  end if;
  if v_order.status <> 'out_for_delivery' then
    raise exception 'invalid_status';
  end if;

  -- Points go to a signed-in customer's account, once per order. Guests have no
  -- account to hold them.
  if v_order.user_id is not null and v_order.loyalty_points_earned = 0 then
    select coalesce(points_per_jod, 1) into v_rate from public.store_settings limit 1;
    v_points := floor(greatest(v_order.subtotal - v_order.discount_amount, 0) * coalesce(v_rate, 1))::integer;
  end if;

  update public.orders
     set status = 'delivered',
         delivered_at = now(),
         paid_at = coalesce(paid_at, now()),
         loyalty_points_earned = loyalty_points_earned + v_points
   where id = p_order_id;

  if v_points > 0 then
    update public.profiles set loyalty_points = loyalty_points + v_points where id = v_order.user_id;
  end if;

  -- Last active order done: switch back on, but only if a pick-up switched off.
  -- (Same set as driver_assigned_orders: a stray pickup order never blocks it.)
  if not exists (select 1 from public.orders
                  where driver_id = v_uid and status not in ('delivered', 'cancelled')
                    and coalesce(order_type, 'delivery') = 'delivery') then
    update public.profiles
       set is_available = true, paused_for_delivery = false, available_changed_at = now()
     where id = v_uid and paused_for_delivery;
  end if;

  return jsonb_build_object('points_awarded', v_points, 'already_delivered', false,
                            'available', (select is_available from public.profiles where id = v_uid));
end;
$$;

revoke all on function public.driver_set_available(boolean) from public, anon;
revoke all on function public.driver_assigned_orders()      from public, anon;
revoke all on function public.driver_pick_up(uuid)          from public, anon;
revoke all on function public.driver_mark_delivered(uuid)   from public, anon;
grant execute on function public.driver_set_available(boolean) to authenticated, service_role;
grant execute on function public.driver_assigned_orders()      to authenticated, service_role;
grant execute on function public.driver_pick_up(uuid)          to authenticated, service_role;
grant execute on function public.driver_mark_delivered(uuid)   to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 6. "Your orders changed" ping for the driver's screen
-- ----------------------------------------------------------------------------

create or replace function public.broadcast_driver_orders()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_driver uuid;
begin
  if tg_op = 'UPDATE'
     and new.driver_id is not distinct from old.driver_id
     and new.status is not distinct from old.status then
    return new;
  end if;
  foreach v_driver in array array[new.driver_id, case when tg_op = 'UPDATE' then old.driver_id end] loop
    if v_driver is not null then
      begin
        perform realtime.send('{}'::jsonb, 'orders', 'driver:' || v_driver::text, false);
      exception when others then
        null;   -- never fail an order change because a notification failed
      end;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_orders_broadcast_driver on public.orders;
create trigger trg_orders_broadcast_driver
  after insert or update of driver_id, status on public.orders
  for each row execute function public.broadcast_driver_orders();

notify pgrst, 'reload schema';

commit;

-- ============================================================================
-- After running:
--   select count(*) from information_schema.columns
--    where table_name = 'profiles' and column_name in ('role', 'is_available', 'paused_for_delivery');  -- 3
--   select count(*) from information_schema.columns
--    where table_name = 'orders' and column_name in ('driver_id', 'picked_up_at', 'delivered_at', 'paid_at');  -- 4
--   select proname from pg_proc where proname like 'driver\_%' order by 1;  -- 4 functions
--
-- Make someone a driver (they first sign in to the app once with Google):
--   update public.profiles set role = 'driver', full_name = 'Driver name', phone_number = '+9627XXXXXXXX'
--    where id = (select id from auth.users where email = 'driver@example.com');
-- Assign an order:
--   update public.orders set driver_id = '<driver profile id>' where id = '<order id>';
-- ============================================================================
