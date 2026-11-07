-- ============================================================================
-- Aswaq Altaibat - the driver's phone feeds the live map
--
-- Builds on 010/015 (order_driver_locations + the 'driver' Realtime broadcast)
-- and 019/020 (require_driver). Safe to re-run (create-or-replace). ASCII-only.
--
-- Until now only the admin dashboard (service_role) could move a driver on the
-- customer's map. driver_update_location() lets a signed-in driver (or admin
-- in driver mode) report their GPS position for an order that is THEIR
-- delivery and is out for delivery; the existing trigger then broadcasts it to
-- the customer's tracking screen and 010 still deletes it once the order moves
-- on. Errors (message = code): not_signed_in, not_a_driver, invalid_location,
-- order_not_found, not_out_for_delivery.
-- ============================================================================

begin;

create or replace function public.driver_update_location(
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
  v_uid   uuid := public.require_driver();
  v_order public.orders%rowtype;
begin
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_location';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found or v_order.driver_id is distinct from v_uid
     or coalesce(v_order.order_type, 'delivery') <> 'delivery' then
    raise exception 'order_not_found';
  end if;
  if v_order.status <> 'out_for_delivery' then
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

revoke all on function public.driver_update_location(uuid, numeric, numeric) from public, anon;
grant execute on function public.driver_update_location(uuid, numeric, numeric) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;

-- After running:
--   select to_regprocedure('public.driver_update_location(uuid,numeric,numeric)');  -- not null
