-- ============================================================================
-- Aswaq Altaibat - driver vehicle details on the customer's tracking card
--
-- Builds on 016 (driver_info in get_order_tracking) and 019 (orders.driver_id).
-- Safe to re-run (one transaction; add-if-missing / create-or-replace). ASCII-only.
--
-- WHAT IT DOES
--   1. profiles: full_name_ar, vehicle_type ('scooter' | 'car'), vehicle_model,
--      vehicle_color, plate_number (Jordanian plates are digits, e.g. 12-34567).
--      Edited from the admin dashboard (service_role); the app keys still cannot
--      update them (019 granted the app only its contact fields).
--   2. get_order_tracking: driver_info now also carries the vehicle and prefers
--      the driver's Arabic name. Same rule as before: only while the delivery
--      is out for delivery, so a customer never sees it before or after.
-- ============================================================================

begin;

alter table public.profiles
  add column if not exists full_name_ar  text,
  add column if not exists vehicle_type  text,
  add column if not exists vehicle_model text,
  add column if not exists vehicle_color text,
  add column if not exists plate_number  text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_full_name_ar_len') then
    alter table public.profiles add constraint profiles_full_name_ar_len
      check (full_name_ar is null or char_length(btrim(full_name_ar)) between 2 and 60);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_vehicle_type_valid') then
    alter table public.profiles add constraint profiles_vehicle_type_valid
      check (vehicle_type is null or vehicle_type in ('scooter', 'car'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_vehicle_model_len') then
    alter table public.profiles add constraint profiles_vehicle_model_len
      check (vehicle_model is null or char_length(btrim(vehicle_model)) between 1 and 40);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_vehicle_color_len') then
    alter table public.profiles add constraint profiles_vehicle_color_len
      check (vehicle_color is null or char_length(btrim(vehicle_color)) between 1 and 30);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_plate_number_fmt') then
    alter table public.profiles add constraint profiles_plate_number_fmt
      check (plate_number is null or plate_number ~ '^[0-9]{1,3}-?[0-9]{1,6}$');
  end if;
end $$;

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
           -- Who is bringing it and on what, only while the delivery is on its way.
           -- The Arabic name from the driver's profile wins over the order's
           -- snapshot; vehicle details come from the profile (021).
           'driver_info', case when o.status = 'out_for_delivery' and o.order_type = 'delivery'
                                and (o.driver_name is not null or o.driver_phone is not null or dp.id is not null)
                               then jsonb_build_object(
                                      'name',          coalesce(dp.full_name_ar, o.driver_name, dp.full_name),
                                      'phone',         o.driver_phone,
                                      'vehicle_type',  dp.vehicle_type,
                                      'vehicle_model', dp.vehicle_model,
                                      'vehicle_color', dp.vehicle_color,
                                      'plate_number',  dp.plate_number) end,
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
    left join public.profiles dp on dp.id = o.driver_id
   where o.id = p_order_id
     and o.tracking_token = p_token;
$$;

revoke all on function public.get_order_tracking(uuid, uuid) from public;
grant execute on function public.get_order_tracking(uuid, uuid) to anon, authenticated, service_role;

notify pgrst, 'reload schema';

commit;

-- After running:
--   select count(*) from information_schema.columns where table_name = 'profiles'
--      and column_name in ('full_name_ar', 'vehicle_type', 'vehicle_model', 'vehicle_color', 'plate_number');  -- 5
