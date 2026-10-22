-- ============================================================================
-- Aswaq Altaibat — Jordanian Dinar needs 3 decimal places, not 2
-- Builds on schema.sql; run after it (and independently of 002/003).
--
-- schema.sql defined every money column as numeric(10,2), a reasonable
-- generic default at the time. The app targets Zarqa, Jordan — JOD prices
-- are commonly expressed to the fils (1 JOD = 1000 fils), e.g. 1.250 JOD —
-- and numeric(10,2) silently rounds that to 1.25, losing real money on
-- every price that isn't a round 10-fils amount. Widen precision instead.
-- ============================================================================

alter table public.products
  alter column price type numeric(10, 3),
  alter column discount_price type numeric(10, 3);

alter table public.orders
  alter column subtotal type numeric(10, 3),
  alter column delivery_fee type numeric(10, 3),
  alter column discount_amount type numeric(10, 3),
  alter column total_price type numeric(10, 3);

alter table public.order_items
  alter column unit_price type numeric(10, 3),
  alter column line_total type numeric(10, 3);
