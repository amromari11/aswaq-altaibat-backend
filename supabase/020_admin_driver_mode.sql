-- ============================================================================
-- Aswaq Altaibat - admins can use driver mode too
--
-- Builds on 019. Safe to re-run (one transaction; create-or-replace). ASCII-only.
--
-- 019 let only role = 'driver' call the driver_* functions and be assigned an
-- order. An admin (role = 'admin') who opens driver mode in the app would get
-- not_a_driver everywhere. Both checks now accept 'driver' or 'admin'; the
-- functions, grants and error codes are otherwise unchanged. Customers are
-- still refused (not_a_driver).
-- ============================================================================

begin;

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
  if not exists (select 1 from public.profiles where id = v_uid and role in ('driver', 'admin')) then
    raise exception 'not_a_driver';
  end if;
  return v_uid;
end;
$$;

revoke all on function public.require_driver() from public, anon, authenticated;

create or replace function public.check_order_driver()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.driver_id is not null
     and (tg_op = 'INSERT' or new.driver_id is distinct from old.driver_id)
     and not exists (select 1 from public.profiles where id = new.driver_id and role in ('driver', 'admin')) then
    raise exception 'not_a_driver';
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';

commit;

-- After running:
--   select prosrc like '%''admin''%' from pg_proc where proname = 'require_driver';      -- true
--   select prosrc like '%''admin''%' from pg_proc where proname = 'check_order_driver';  -- true
-- Make someone an admin (they first sign in to the app once with Google):
--   update public.profiles set role = 'admin'
--    where id = (select id from auth.users where email = 'admin@example.com');
