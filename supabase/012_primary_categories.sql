-- ============================================================================
-- Aswaq Altaibat - consolidate the 39 POS categories into 13 primary ones
--
-- Builds on schema.sql + 011. Safe to re-run (one transaction; create-if-missing
-- / fill-blanks-only). ASCII-only on purpose (Arabic as SQL Unicode escapes).
--
-- WHY
--   The POS export has 39 "item groups" - many near-duplicates (a category and
--   'category 2', singular/plural spellings). Shoppers need a short, scannable
--   list. This folds them into 13 primary categories.
--
-- WHAT IT DOES (nothing is deleted)
--   1. Creates the 13 primary categories (only if missing; display_order 1..13,
--      each starts with a placeholder photo that the dashboard can replace).
--   2. category_aliases: old POS category name -> primary category. The product
--      import (scripts/import_products.py) reads it so a re-import keeps filing
--      products under the primary category instead of recreating the old ones.
--      Admin-only: no grants for the app keys.
--   3. Moves every product from its old category to the primary one, remembering
--      where it came from in products.legacy_category_id (set once, never
--      overwritten, so the first run's original is always kept).
--   4. Hides the old categories (is_active = false). They stay in the table, so
--      the move can be undone - see the ROLLBACK note at the bottom.
-- ============================================================================

begin;

alter table public.products
  add column if not exists legacy_category_id uuid references public.categories (id) on delete set null;
comment on column public.products.legacy_category_id is
  'The POS category this product was filed under before migration 012 folded it into a primary category.';

create table if not exists public.category_aliases (
  alias_name_ar text primary key,
  category_id   uuid not null references public.categories (id) on delete cascade
);
alter table public.category_aliases enable row level security;
revoke all on public.category_aliases from anon, authenticated;

-- 1. The primary categories (never overwrites an existing one)
insert into public.categories (name, name_ar, display_order, image_url, is_active)
select v.name_ar, v.name_ar, v.ord, v.url, true
  from (values
  (U&'\0623\0644\0628\0627\0646 \0648\0623\062C\0628\0627\0646 \0648\0628\064A\0636', 1, 'https://images.pexels.com/photos/5946742/pexels-photo-5946742.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0627\0644\0644\062D\0648\0645 \0648\0627\0644\062F\0648\0627\062C\0646', 2, 'https://images.pexels.com/photos/5892851/pexels-photo-5892851.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0645\062C\0645\062F\0627\062A \0648\0622\064A\0633 \0643\0631\064A\0645', 3, 'https://images.pexels.com/photos/6823362/pexels-photo-6823362.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0645\062E\0628\0648\0632\0627\062A \0648\062D\0644\0648\064A\0627\062A', 4, 'https://images.pexels.com/photos/1383908/pexels-photo-1383908.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0623\0631\0632 \0648\062D\0628\0648\0628', 5, 'https://images.pexels.com/photos/6187598/pexels-photo-6187598.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A', 6, 'https://images.pexels.com/photos/9395018/pexels-photo-9395018.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0632\064A\0648\062A \0648\0628\0647\0627\0631\0627\062A', 7, 'https://images.pexels.com/photos/1340116/pexels-photo-1340116.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0627\0644\0645\0634\0631\0648\0628\0627\062A', 8, 'https://images.pexels.com/photos/16404143/pexels-photo-16404143.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0642\0647\0648\0629 \0648\0634\0627\064A', 9, 'https://images.pexels.com/photos/2642842/pexels-photo-2642842.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631', 10, 'https://images.pexels.com/photos/8023869/pexels-photo-8023869.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644', 11, 'https://images.pexels.com/photos/5217900/pexels-photo-5217900.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0627\0644\062A\0628\063A \0648\0627\0644\0645\0639\0633\0644', 12, 'https://images.pexels.com/photos/12007437/pexels-photo-12007437.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop'),
  (U&'\0645\0646\062A\062C\0627\062A \0645\062A\0646\0648\0639\0629', 13, 'https://images.pexels.com/photos/8805182/pexels-photo-8805182.jpeg?auto=compress&cs=tinysrgb&w=600&h=600&fit=crop')
  ) as v(name_ar, ord, url)
 where not exists (select 1 from public.categories c where c.name_ar = v.name_ar);

-- 2. Old POS category -> primary category
insert into public.category_aliases (alias_name_ar, category_id)
select v.alias, p.id
  from (values
  (U&'\0627\0644\0623\0644\0628\0627\0646', U&'\0623\0644\0628\0627\0646 \0648\0623\062C\0628\0627\0646 \0648\0628\064A\0636'),
  (U&'\0627\062C\0628\0627\0646 \0648\0627\0644\0628\0627\0646 \0648\0645\0634\062A\0642\0627\062A\0647\0627', U&'\0623\0644\0628\0627\0646 \0648\0623\062C\0628\0627\0646 \0648\0628\064A\0636'),
  (U&'\062D\0644\064A\0628 \0648\0645\0634\062A\0642\0627\062A\0647', U&'\0623\0644\0628\0627\0646 \0648\0623\062C\0628\0627\0646 \0648\0628\064A\0636'),
  (U&'\0628\064A\0636', U&'\0623\0644\0628\0627\0646 \0648\0623\062C\0628\0627\0646 \0648\0628\064A\0636'),
  (U&'\0645\0634\062A\0642\0627\062A \0627\0644\0645\064A\0632\0627\0646', U&'\0623\0644\0628\0627\0646 \0648\0623\062C\0628\0627\0646 \0648\0628\064A\0636'),
  (U&'\0644\062D\0648\0645', U&'\0627\0644\0644\062D\0648\0645 \0648\0627\0644\062F\0648\0627\062C\0646'),
  (U&'\062F\062C\0627\062C', U&'\0627\0644\0644\062D\0648\0645 \0648\0627\0644\062F\0648\0627\062C\0646'),
  (U&'\0644\0648\0627\0632\0645 \0627\0644\0634\0648\0627\0621', U&'\0627\0644\0644\062D\0648\0645 \0648\0627\0644\062F\0648\0627\062C\0646'),
  (U&'\0645\062C\0645\062F\0627\062A', U&'\0645\062C\0645\062F\0627\062A \0648\0622\064A\0633 \0643\0631\064A\0645'),
  (U&'\0627\064A\0633 \0643\0631\064A\0645 \0648\0627\0644\0628\0648\0638\0647', U&'\0645\062C\0645\062F\0627\062A \0648\0622\064A\0633 \0643\0631\064A\0645'),
  (U&'\0627\0644\062E\0628\0632 \0648\0627\0644\0643\0639\0643 \0628\0627\0646\0648\0627\0639\0647', U&'\0645\062E\0628\0648\0632\0627\062A \0648\062D\0644\0648\064A\0627\062A'),
  (U&'\062E\0644\064A\0637 \0627\0644\0643\064A\0643 \0648\0627\0644\062D\0644\0648\064A\0627\062A \0648\0645\0634\062A\0642\0627\062A\0647\0627', U&'\0645\062E\0628\0648\0632\0627\062A \0648\062D\0644\0648\064A\0627\062A'),
  (U&'\062F\064A\0644\064A \0627\0644\0637\064A\0628\0627\062A', U&'\0645\062E\0628\0648\0632\0627\062A \0648\062D\0644\0648\064A\0627\062A'),
  (U&'\062D\0628\0648\0628 \0648\0645\0634\062A\0642\0627\062A\0647\0627', U&'\0623\0631\0632 \0648\062D\0628\0648\0628'),
  (U&'\0627\0644\0645\0639\0644\0628\0627\062A', U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A'),
  (U&'\0645\0639\0644\0628\0627\062A', U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A'),
  (U&'\0631\0628 \0627\0644\0628\0646\062F\0648\0631\0629', U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A'),
  (U&'\0637\062D\064A\0646\0629', U&'\0645\0639\0644\0628\0627\062A \0648\0645\0639\062C\0646\0627\062A'),
  (U&'\0627\0644\0632\064A\0648\062A \0648\0645\0634\062A\0642\0627\062A\0647\0627', U&'\0632\064A\0648\062A \0648\0628\0647\0627\0631\0627\062A'),
  (U&'\0627\0644\0628\0647\0627\0631\0627\062A', U&'\0632\064A\0648\062A \0648\0628\0647\0627\0631\0627\062A'),
  (U&'\0627\0644\0628\0647\0627\0631\062A \0627\0644\0639\0627\0645\0647', U&'\0632\064A\0648\062A \0648\0628\0647\0627\0631\0627\062A'),
  (U&'\0639\0635\0627\0626\0631', U&'\0627\0644\0645\0634\0631\0648\0628\0627\062A'),
  (U&'\0645\0634\0631\0648\0628\0627\062A \063A\0627\0632\064A\0629', U&'\0627\0644\0645\0634\0631\0648\0628\0627\062A'),
  (U&'\0627\0644\0645\064A\0627\0647 \0627\0644\0645\0639\062F\0646\064A\0629', U&'\0627\0644\0645\0634\0631\0648\0628\0627\062A'),
  (U&'\0627\0644\0642\0647\0648\0629 \0648\0627\0644\0634\0627\064A \0648\0645\0634\062A\0642\0627\062A\0647\0627', U&'\0642\0647\0648\0629 \0648\0634\0627\064A'),
  (U&'\0634\064A\0628\0633', U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631'),
  (U&'\0646\062B\0631\0628\0627\062A', U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631'),
  (U&'\0627\0644\0633\0643\0627\0643\0631 \0648\0645\0634\062A\0642\0627\062A\0647\0627', U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631'),
  (U&'\0633\0643\0627\0643\0631', U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631'),
  (U&'\0639\0633\0644', U&'\0633\0646\0627\0643\0633 \0648\0633\0643\0627\0643\0631'),
  (U&'\0627\0644\0645\0646\0638\0641\0627\062A', U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644'),
  (U&'\0645\0646\0638\0641\0627\062A', U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644'),
  (U&'\0627\0644\0648\0631\0642\064A\0627\062A \0648\0627\0644\0641\0648\0637 \0648\062A\0648\0627\0628\0639\0647\0627', U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644'),
  (U&'\0645\0648\0627\062F \0645\0646\0632\0644\064A\0629', U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644'),
  (U&'\0627\062F\0648\0627\062A \0645\0646\0632\0644\064A\0629', U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644'),
  (U&'\0628\0637\0627\0631\064A\0627\062A \0648\0643\0634\0627\0641\0627\062A', U&'\0645\0646\0638\0641\0627\062A \0648\0645\0633\062A\0644\0632\0645\0627\062A \0627\0644\0645\0646\0632\0644'),
  (U&'\062F\062E\0627\0646 \0648\0645\0639\0633\0644', U&'\0627\0644\062A\0628\063A \0648\0627\0644\0645\0639\0633\0644'),
  (U&'\0627\062E\0631\0649', U&'\0645\0646\062A\062C\0627\062A \0645\062A\0646\0648\0639\0629'),
  (U&'\063A\064A\0631 \0645\0635\0646\0641', U&'\0645\0646\062A\062C\0627\062A \0645\062A\0646\0648\0639\0629')
  ) as v(alias, primary_name)
  join public.categories p on p.name_ar = v.primary_name
on conflict (alias_name_ar) do update set category_id = excluded.category_id;

-- 3. File the products under their primary category
update public.products pr
   set legacy_category_id = coalesce(pr.legacy_category_id, pr.category_id),
       category_id        = a.category_id
  from public.categories old
  join public.category_aliases a on a.alias_name_ar = old.name_ar
 where pr.category_id = old.id
   and old.id <> a.category_id;

-- 4. Hide the old categories
update public.categories c
   set is_active = false
  from public.category_aliases a
 where c.name_ar = a.alias_name_ar
   and c.id <> a.category_id
   and c.is_active;

notify pgrst, 'reload schema';

commit;

-- ----------------------------------------------------------------------------
-- Verify after running:
--   select count(*) from public.categories where is_active;                       -- 13
--   select count(*) from public.products where legacy_category_id is not null;    -- = number of products moved
--
-- ROLLBACK (undo the move; run only if you really want the 39 back):
--   update public.products set category_id = legacy_category_id, legacy_category_id = null
--    where legacy_category_id is not null;
--   update public.categories set is_active = true
--    where name_ar in (select alias_name_ar from public.category_aliases);
--   update public.categories set is_active = false
--    where id in (select category_id from public.category_aliases);
-- ----------------------------------------------------------------------------
