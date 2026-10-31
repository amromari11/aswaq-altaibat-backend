-- ============================================================================
-- Aswaq Altaibat - best sellers, and the driver's name and phone
--
-- Builds on 015 (re-creates get_order_tracking). Safe to re-run (one
-- transaction; add-if-missing / create-or-replace). ASCII-only.
--
-- WHAT IT DOES
--   1. public.best_sellers(p_limit): the products customers buy most, for the
--      app's "best sellers" shelf. Ranked by units sold in the last 30 days
--      (cancelled orders and old orders do not count); products with no sales
--      qualify only if they are currently on offer, so until real orders exist
--      the shelf shows the discounted products, and it stays empty when there is
--      nothing to show. Active, in-stock products only; at most 50 rows.
--      Callable by the app (anon / signed-in): it exposes nothing the catalog
--      does not already show.
--   2. orders.driver_name / orders.driver_phone, set from the admin dashboard
--      when an order goes out for delivery. The phone must be a Jordanian mobile
--      (+9627XXXXXXXX): the app turns it into call / WhatsApp buttons.
--   3. get_order_tracking returns them as 'driver_info' - only while the order is
--      out for delivery (a customer never sees a driver's number before or after),
--      and a Realtime 'status' ping is sent when they change, so the customer's
--      tracking screen shows the driver card without a manual refresh.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. best_sellers
-- ----------------------------------------------------------------------------

create or replace function public.best_sellers(p_limit integer default 20)
returns setof public.products
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with sold as (
    select oi.product_id, sum(oi.quantity) as units
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where o.status <> 'cancelled'
       and o.created_at >= now() - interval '30 days'
     group by oi.product_id
  ),
  ranked as (
    select p.id,
           row_number() over (
             order by coalesce(s.units, 0) desc,
                      (p.discount_price is not null and p.discount_price < p.price) desc,
                      p.is_weekly_offer desc,
                      p.created_at desc,
                      p.id
           ) as rn
      from public.products p
      left join sold s on s.product_id = p.id
     where p.is_active
       and p.stock_status <> 'out_of_stock'
       and (coalesce(s.units, 0) > 0 or (p.discount_price is not null and p.discount_price < p.price))
  )
  select p.*
    from ranked r
    join public.products p on p.id = r.id
   where r.rn <= greatest(least(coalesce(p_limit, 20), 50), 1)
   order by r.rn;
$$;

revoke all on function public.best_sellers(integer) from public;
grant execute on function public.best_sellers(integer) to anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. Driver details on the order
-- ----------------------------------------------------------------------------

alter table public.orders
  add column if not exists driver_name  text,
  add column if not exists driver_phone text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_driver_name_len') then
    alter table public.orders add constraint orders_driver_name_len
      check (driver_name is null or char_length(btrim(driver_name)) between 2 and 60);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'orders_driver_phone_fmt') then
    alter table public.orders add constraint orders_driver_phone_fmt
      check (driver_phone is null or driver_phone ~ '^\+9627[789][0-9]{7}$');
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 3. Tracking returns them (only while out for delivery)
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
           -- Name and phone of the driver, only while the delivery is on its way.
           'driver_info', case when o.status = 'out_for_delivery' and o.order_type = 'delivery'
                                and (o.driver_name is not null or o.driver_phone is not null)
                               then jsonb_build_object('name', o.driver_name, 'phone', o.driver_phone) end,
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

-- A changed name or phone pings the order's channel, like a status change does,
-- so the customer's screen reloads. Best effort: a failed ping never fails the update.
create or replace function public.broadcast_driver_details()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object('order_id', new.id, 'status', new.status::text, 'updated_at', now()),
      'status',
      'order:' || new.tracking_token::text,
      false
    );
  exception when others then
    null;
  end;
  return new;
end;
$$;

drop trigger if exists trg_orders_broadcast_driver on public.orders;
create trigger trg_orders_broadcast_driver
  after update of driver_name, driver_phone on public.orders
  for each row
  when (old.driver_name is distinct from new.driver_name or old.driver_phone is distinct from new.driver_phone)
  execute function public.broadcast_driver_details();

notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select count(*) from public.best_sellers(10);                                  -- 0 or more, no error
--   select column_name from information_schema.columns
--    where table_schema = 'public' and table_name = 'orders' and column_name like 'driver_%';   -- 2 rows
--   select count(*) from pg_trigger where tgname = 'trg_orders_broadcast_driver';  -- 1
-- ----------------------------------------------------------------------------
