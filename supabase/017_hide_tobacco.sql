-- ============================================================================
-- Aswaq Altaibat - take the tobacco category off the app
--
-- Builds on 012. Safe to re-run (one transaction; idempotent). ASCII-only.
--
-- WHAT IT DOES
--   1. Hides the primary category "tobacco and shisha" (is_active = false), so the
--      app's category row, the Categories tab and the admin's active lists no
--      longer show it. It is hidden, not deleted, on purpose: the POS import maps
--      the old POS group to it by name (category_aliases), so deleting it would
--      make the next import quietly create an active tobacco category again.
--   2. Hides the products already in it (is_active = false): they are no longer
--      listed, searched, shown as best sellers, or accepted by place_order.
--      Nothing is lost - they stay in the table (and in any order history).
--   3. A product that sits in a hidden category is forced hidden by a trigger on
--      insert and on a change of category / active flag - so a later POS import
--      (which upserts products by SKU) cannot bring them back. To sell them again:
--      make the category active in the dashboard, then activate the products.
-- ============================================================================

begin;

-- 1. Hide the category
update public.categories
   set is_active = false
 where name_ar = U&'\0627\0644\062A\0628\063A \0648\0627\0644\0645\0639\0633\0644'
   and is_active;

-- 2. A product in a hidden category is hidden too
create or replace function public.products_follow_category()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.is_active
     and exists (select 1 from public.categories c where c.id = new.category_id and not c.is_active) then
    new.is_active := false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_products_follow_category on public.products;
create trigger trg_products_follow_category
  before insert or update of category_id, is_active on public.products
  for each row execute function public.products_follow_category();

-- 3. Hide the tobacco products that are already there
update public.products
   set is_active = false
 where is_active
   and category_id in (select id from public.categories where name_ar = U&'\0627\0644\062A\0628\063A \0648\0627\0644\0645\0639\0633\0644');

notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select is_active from public.categories where name_ar = U&'\0627\0644\062A\0628\063A \0648\0627\0644\0645\0639\0633\0644';              -- false
--   select count(*) from public.products p join public.categories c on c.id = p.category_id
--    where not c.is_active and p.is_active;                                       -- 0
--   select count(*) from pg_trigger where tgname = 'trg_products_follow_category'; -- 1
-- ----------------------------------------------------------------------------
