-- ============================================================================
-- Aswaq Altaibat - order tracking (guest-friendly, live status updates)
--
-- Builds on 008. Safe to re-run (one transaction; create-if-missing /
-- create-or-replace / drop-and-recreate). ASCII-only on purpose.
--
-- THE PROBLEM: a guest has no account, and RLS only lets an order's owner read
-- it - so a guest could neither see their order nor receive Realtime row
-- changes (Realtime follows the same RLS).
--
-- THE DESIGN: every order gets a random secret tracking_token. The app makes
-- one up when placing the order and keeps {order id, token} on the device.
--   * get_order_tracking(id, token) / list_orders_summary(refs) return an
--     order's details only to someone who holds BOTH id and token.
--   * A trigger broadcasts each status change on the Realtime channel
--     'order:<token>'. The token is unguessable (a random uuid) and known only
--     to the device that placed the order (and the admin), so it works as the
--     channel's secret. Public (non-private) channels are enabled on this
--     project (verified).
--   * The app also re-checks every ~20s, so tracking still works if Realtime
--     is down; nothing here depends on it.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. orders.tracking_token  (existing orders get a fresh random token too)
-- ----------------------------------------------------------------------------

alter table public.orders
  add column if not exists tracking_token uuid not null default gen_random_uuid();

create unique index if not exists uq_orders_tracking_token on public.orders (tracking_token);

-- ----------------------------------------------------------------------------
-- 2. place_order() - same as 008, plus p_tracking_token
--    The old 9-argument version is dropped first: keeping both would make a
--    call without p_tracking_token ambiguous. Callers that don't pass a token
--    (older app builds) still work - the database makes one up.
-- ----------------------------------------------------------------------------

drop function if exists public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text);

create or replace function public.place_order(
  p_customer_name    text,
  p_customer_phone   text,
  p_items            jsonb,
  p_delivery_address text,
  p_zone_id          uuid,
  p_address_id       uuid    default null,
  p_delivery_lat     numeric default null,
  p_delivery_lng     numeric default null,
  p_notes            text    default null,
  p_tracking_token   uuid    default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- Mirrors AppConfig.freeDeliveryThresholdJod in the Flutter app.
  free_delivery_threshold constant numeric := 20;

  v_uid      uuid := auth.uid();
  v_name     text := btrim(coalesce(p_customer_name, ''));
  v_phone    text := regexp_replace(coalesce(p_customer_phone, ''), '[\s-]', '', 'g');
  v_address  text := btrim(coalesce(p_delivery_address, ''));
  v_notes    text := nullif(btrim(coalesce(p_notes, '')), '');
  v_zone     public.delivery_zones%rowtype;
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
  if char_length(v_name) < 2 or char_length(v_name) > 100 then
    raise exception 'invalid_name';
  end if;
  if v_phone !~ '^\+9627[789][0-9]{7}$' then
    raise exception 'invalid_phone';
  end if;
  if char_length(v_address) < 3 or char_length(v_address) > 500 then
    raise exception 'invalid_address';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
    raise exception 'invalid_items';
  end if;

  select * into v_zone from public.delivery_zones where id = p_zone_id and is_active;
  if not found then
    raise exception 'invalid_zone';
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

  if v_subtotal < v_zone.min_order_amount then
    raise exception 'below_minimum';
  end if;
  v_fee := case when v_subtotal >= free_delivery_threshold then 0 else v_zone.delivery_fee end;

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
  select id into v_address_id from public.user_addresses
   where id = p_address_id and user_id = v_uid;

  insert into public.orders (
    user_id, customer_id, customer_name, customer_phone,
    subtotal, delivery_fee, total_price,
    delivery_address, delivery_lat, delivery_lng,
    payment_method, notes, zone_id, address_id, tracking_token
  ) values (
    v_user, v_customer, v_name, v_phone,
    v_subtotal, v_fee, v_subtotal + v_fee,
    v_address, p_delivery_lat, p_delivery_lng,
    'cash', v_notes, v_zone.id, v_address_id, coalesce(p_tracking_token, gen_random_uuid())
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

revoke all on function public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text, uuid) from public;
grant execute on function public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text, uuid)
  to anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. get_order_tracking(order id, token) -> one order, or NULL
--    NULL (never an error) for a wrong id or token, so nothing can be probed.
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
           'customer_name',    o.customer_name,
           'zone_name_ar',     z.name_ar,
           'eta_minutes',      z.eta_minutes,
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

-- ----------------------------------------------------------------------------
-- 4. list_orders_summary(refs) - the orders list
--    p_refs: [{"id": "<uuid>", "token": "<uuid>"}, ...]  (max 50). Entries that
--    are malformed, or whose token doesn't match, are silently skipped.
-- ----------------------------------------------------------------------------

create or replace function public.list_orders_summary(p_refs jsonb)
returns table (
  id uuid, status text, created_at timestamptz, updated_at timestamptz,
  subtotal numeric, delivery_fee numeric, total_price numeric,
  item_count bigint, zone_name_ar text, eta_minutes int
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
         z.name_ar, z.eta_minutes
    from refs r
    join public.orders o on o.id = r.id and o.tracking_token = r.token
    left join public.delivery_zones z on z.id = o.zone_id
   order by o.created_at desc;
$$;

revoke all on function public.get_order_tracking(uuid, uuid) from public;
revoke all on function public.list_orders_summary(jsonb) from public;
grant execute on function public.get_order_tracking(uuid, uuid) to anon, authenticated, service_role;
grant execute on function public.list_orders_summary(jsonb)     to anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. Live status broadcast
--    On every status change, publish to the Realtime channel 'order:<token>'.
--    The broadcast is best-effort: it is wrapped so that if Realtime is
--    missing or misbehaving, the admin's status update STILL succeeds.
-- ----------------------------------------------------------------------------

create or replace function public.broadcast_order_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    begin
      perform realtime.send(
        jsonb_build_object('order_id', new.id, 'status', new.status::text, 'updated_at', new.updated_at),
        'status',
        'order:' || new.tracking_token::text,
        false                                   -- public channel; the token is the secret
      );
    exception when others then
      null;   -- never fail the status change because a notification failed
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_broadcast_status on public.orders;
create trigger trg_orders_broadcast_status
  after update of status on public.orders
  for each row execute function public.broadcast_order_status();

-- Make PostgREST see the new objects immediately.
notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select to_regprocedure('public.get_order_tracking(uuid,uuid)'),
--          to_regprocedure('public.list_orders_summary(jsonb)'),
--          to_regprocedure('public.place_order(text,text,jsonb,text,uuid,uuid,numeric,numeric,text,uuid)');  -- all non-null
--   select count(*) from pg_proc where proname = 'place_order';                                             -- 1 (old version dropped)
--   select count(*) from pg_trigger where tgname = 'trg_orders_broadcast_status';                           -- 1
-- ----------------------------------------------------------------------------
