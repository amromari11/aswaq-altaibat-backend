-- ----------------------------------------------------------------------------
-- 005_cart_items.sql
--
-- Server-side persisted cart for signed-in users, so a cart survives an app
-- restart and syncs across a customer's devices. Guests still use local-only
-- (in-memory) cart state in the Flutter app — RLS here requires auth.uid(),
-- same as orders/profiles, so there's nothing to sync until sign-in.
-- ----------------------------------------------------------------------------

create table public.cart_items (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  product_id  uuid not null references public.products (id) on delete cascade,
  quantity    integer not null check (quantity > 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, product_id)
);

create index idx_cart_items_user_id on public.cart_items (user_id);

-- Reuses the same updated_at trigger function as profiles/products/orders
-- (defined in schema.sql).
create trigger trg_cart_items_updated_at
  before update on public.cart_items
  for each row execute function public.set_updated_at();

alter table public.cart_items enable row level security;

create policy "Users can view their own cart items"
  on public.cart_items for select
  using (auth.uid() = user_id);

create policy "Users can insert their own cart items"
  on public.cart_items for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own cart items"
  on public.cart_items for update
  using (auth.uid() = user_id);

create policy "Users can delete their own cart items"
  on public.cart_items for delete
  using (auth.uid() = user_id);
