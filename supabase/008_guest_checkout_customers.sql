-- ============================================================================
-- Aswaq Altaibat - guest checkout, customers, and admin analytics
--
-- Builds on schema.sql, 004 and 007. Safe to re-run (one transaction;
-- everything is create-if-missing or create-or-replace). ASCII-only on
-- purpose: error codes below are English identifiers the app maps to Arabic,
-- so the file survives a clipboard that mangles non-ASCII.
--
-- WHY A FUNCTION: a guest has no auth account, but orders needed an auth user
-- (orders.user_id NOT NULL -> profiles -> auth.users) and RLS only lets a
-- signed-in user insert their own order. Instead of loosening RLS for
-- everyone, guests (and signed-in users alike) order through place_order(),
-- a SECURITY DEFINER function that validates the request, recomputes prices /
-- fee / minimum order from the database (never trusting the phone), upserts
-- the customer by phone number, and writes the order + its items in a single
-- transaction.
--
-- Phone numbers are NOT verified (no OTP, by decision). Anyone who types a
-- phone number can order under it; the name on a customer record is whatever
-- was typed last, and each order keeps its own name/phone snapshot.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. CUSTOMERS - one row per phone number (guest or Google account)
-- ----------------------------------------------------------------------------

create table if not exists public.customers (
  id            uuid primary key default gen_random_uuid(),
  phone_number  text not null unique
                check (phone_number ~ '^\+9627[789][0-9]{7}$'),   -- +9627XXXXXXXX
  full_name     text,
  -- Set when a signed-in (Google) user orders with this phone; stays null for
  -- pure guests.
  auth_user_id  uuid unique references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

drop trigger if exists trg_customers_updated_at on public.customers;
create trigger trg_customers_updated_at
  before update on public.customers
  for each row execute function public.set_updated_at();

-- Admin-only data: RLS on with no policies, and no grants for the app keys.
-- The dashboard uses service_role, which bypasses RLS.
alter table public.customers enable row level security;
revoke all on public.customers from anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. ORDERS - guests have no user_id; keep a name/phone snapshot per order
-- ----------------------------------------------------------------------------

alter table public.orders
  alter column user_id drop not null,
  add column if not exists customer_id    uuid references public.customers (id) on delete set null,
  add column if not exists customer_name  text,
  add column if not exists customer_phone text;

create index if not exists idx_orders_customer_id on public.orders (customer_id);
create index if not exists idx_orders_created_at  on public.orders (created_at);

-- Backfill customers from profiles that already have a valid saved phone, and
-- attach their existing orders.
insert into public.customers (phone_number, full_name, auth_user_id)
select p.phone_number, p.full_name, p.id
  from public.profiles p
 where p.phone_number ~ '^\+9627[789][0-9]{7}$'
on conflict (phone_number) do nothing;

update public.orders o
   set customer_id    = c.id,
       customer_name  = coalesce(o.customer_name, c.full_name),
       customer_phone = coalesce(o.customer_phone, c.phone_number)
  from public.customers c
 where c.auth_user_id = o.user_id
   and o.customer_id is null;

-- ----------------------------------------------------------------------------
-- 3. place_order() - the only way the app creates an order
--    p_items: [{"product_id": "<uuid>", "quantity": 2}, ...]
--    Errors are raised as plain codes (message = code):
--      invalid_name, invalid_phone, invalid_address, invalid_items,
--      invalid_zone, unknown_product, out_of_stock, insufficient_stock,
--      below_minimum, too_many_orders
-- ----------------------------------------------------------------------------

create or replace function public.place_order(
  p_customer_name    text,
  p_customer_phone   text,
  p_items            jsonb,
  p_delivery_address text,
  p_zone_id          uuid,
  p_address_id       uuid    default null,
  p_delivery_lat     numeric default null,
  p_delivery_lng     numeric default null,
  p_notes            text    default null
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
    payment_method, notes, zone_id, address_id
  ) values (
    v_user, v_customer, v_name, v_phone,
    v_subtotal, v_fee, v_subtotal + v_fee,
    v_address, p_delivery_lat, p_delivery_lng,
    'cash', v_notes, v_zone.id, v_address_id
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

revoke all on function public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text) from public;
grant execute on function public.place_order(text, text, jsonb, text, uuid, uuid, numeric, numeric, text)
  to anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. ADMIN ANALYTICS - read by the Streamlit dashboard (service_role) only.
--    Aggregated in SQL because PostgREST caps any response at ~1000 rows, which
--    would silently undercount client-side sums. "Sales" exclude cancelled
--    orders. Windows are [p_from, p_to).
-- ----------------------------------------------------------------------------

-- One row per customer: order count, total spend, first/last order.
create or replace view public.admin_customer_stats
with (security_invoker = true) as
select c.id            as customer_id,
       c.full_name,
       c.phone_number,
       (c.auth_user_id is not null) as has_google_account,
       c.created_at,
       count(o.id) filter (where o.status <> 'cancelled')                      as orders_count,
       count(o.id) filter (where o.status = 'cancelled')                       as cancelled_count,
       coalesce(sum(o.total_price) filter (where o.status <> 'cancelled'), 0)  as total_spend,
       min(o.created_at) as first_order_at,
       max(o.created_at) as last_order_at
  from public.customers c
  left join public.orders o on o.customer_id = c.id
 group by c.id;

create or replace function public.admin_top_products(
  p_from timestamptz, p_to timestamptz, p_limit int default 20
)
returns table (
  product_id uuid, name_ar text, name text, sku text,
  units_sold bigint, revenue numeric, orders_count bigint
)
language sql stable
as $$
  select p.id, p.name_ar, p.name, p.sku,
         sum(oi.quantity)::bigint,
         sum(oi.line_total),
         count(distinct oi.order_id)::bigint
    from public.order_items oi
    join public.orders o   on o.id = oi.order_id
    join public.products p on p.id = oi.product_id
   where o.created_at >= p_from and o.created_at < p_to
     and o.status <> 'cancelled'
   group by p.id
   order by sum(oi.quantity) desc, sum(oi.line_total) desc
   limit greatest(p_limit, 1);
$$;

create or replace function public.admin_order_insights(p_from timestamptz, p_to timestamptz)
returns table (
  orders_count bigint, total_sales numeric, avg_order_value numeric,
  cancelled_count bigint, unique_customers bigint
)
language sql stable
as $$
  select count(*) filter (where status <> 'cancelled')::bigint,
         coalesce(sum(total_price) filter (where status <> 'cancelled'), 0),
         coalesce(avg(total_price) filter (where status <> 'cancelled'), 0),
         count(*) filter (where status = 'cancelled')::bigint,
         count(distinct customer_id) filter (where status <> 'cancelled')::bigint
    from public.orders
   where created_at >= p_from and created_at < p_to;
$$;

create or replace function public.admin_top_zones(
  p_from timestamptz, p_to timestamptz, p_limit int default 10
)
returns table (zone_id uuid, zone_name_ar text, orders_count bigint, sales numeric)
language sql stable
as $$
  select o.zone_id, z.name_ar,
         count(*)::bigint,
         sum(o.total_price)
    from public.orders o
    left join public.delivery_zones z on z.id = o.zone_id
   where o.created_at >= p_from and o.created_at < p_to
     and o.status <> 'cancelled'
   group by o.zone_id, z.name_ar
   order by count(*) desc, sum(o.total_price) desc
   limit greatest(p_limit, 1);
$$;

-- Daily series for the sales chart, bucketed by Amman calendar day.
create or replace function public.admin_sales_by_day(p_from timestamptz, p_to timestamptz)
returns table (day date, orders_count bigint, sales numeric)
language sql stable
as $$
  select (o.created_at at time zone 'Asia/Amman')::date,
         count(*)::bigint,
         sum(o.total_price)
    from public.orders o
   where o.created_at >= p_from and o.created_at < p_to
     and o.status <> 'cancelled'
   group by 1
   order by 1;
$$;

-- Supabase auto-grants new objects to the app keys; the analytics are admin-only.
revoke all on public.admin_customer_stats from public, anon, authenticated;
grant select on public.admin_customer_stats to service_role;

revoke all on function public.admin_top_products(timestamptz, timestamptz, int)   from public, anon, authenticated;
revoke all on function public.admin_order_insights(timestamptz, timestamptz)      from public, anon, authenticated;
revoke all on function public.admin_top_zones(timestamptz, timestamptz, int)      from public, anon, authenticated;
revoke all on function public.admin_sales_by_day(timestamptz, timestamptz)        from public, anon, authenticated;
grant execute on function public.admin_top_products(timestamptz, timestamptz, int)   to service_role;
grant execute on function public.admin_order_insights(timestamptz, timestamptz)      to service_role;
grant execute on function public.admin_top_zones(timestamptz, timestamptz, int)      to service_role;
grant execute on function public.admin_sales_by_day(timestamptz, timestamptz)        to service_role;

-- Make PostgREST see the new objects immediately.
notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select to_regclass('public.customers'), to_regprocedure(
--     'public.place_order(text,text,jsonb,text,uuid,uuid,numeric,numeric,text)');   -- both non-null
--   select column_name from information_schema.columns
--    where table_name = 'orders' and column_name in ('customer_id','customer_name','customer_phone');  -- 3 rows
--   select is_nullable from information_schema.columns
--    where table_name = 'orders' and column_name = 'user_id';                                          -- YES
-- ----------------------------------------------------------------------------
