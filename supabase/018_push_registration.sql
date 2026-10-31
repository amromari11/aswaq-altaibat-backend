-- ============================================================================
-- 018 - push notification device registration.
--
-- The customer app registers its FCM token through register_push_token(), for
-- signed-in customers AND guests (guest checkout has no account, so user_id is
-- now optional). The admin dashboard (service_role) reads the table to send,
-- and deletes tokens FCM reports as dead. Re-runnable. Needs 002.
-- ============================================================================

begin;

alter table public.push_tokens alter column user_id drop not null;
alter table public.push_tokens add column if not exists weekly_offers boolean not null default true;
alter table public.push_tokens add column if not exists updated_at timestamptz not null default now();

alter table public.push_tokens drop constraint if exists push_tokens_token_length;
alter table public.push_tokens add constraint push_tokens_token_length
  check (char_length(token) between 20 and 4096);
alter table public.push_tokens drop constraint if exists push_tokens_platform_known;
alter table public.push_tokens add constraint push_tokens_platform_known
  check (platform in ('ios', 'android', 'web', 'unknown'));

create index if not exists idx_push_tokens_weekly_offers on public.push_tokens (weekly_offers) where weekly_offers;

-- Devices FCM refused (dead token) are counted separately from the ones reached.
alter table public.notifications add column if not exists failed_count integer not null default 0;

-- The only way for the app to write a token: one row per token, re-pointed at whoever is
-- signed in now (a guest, after sign-out, takes the device back from the old account).
create or replace function public.register_push_token(
  p_token text,
  p_platform text default 'unknown',
  p_weekly_offers boolean default true
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_token    text := btrim(coalesce(p_token, ''));
  v_platform text := lower(coalesce(p_platform, 'unknown'));
  v_uid      uuid := auth.uid();
begin
  if char_length(v_token) < 20 or char_length(v_token) > 4096 or v_token ~ '\s' then
    raise exception 'invalid_token';
  end if;
  if v_platform not in ('ios', 'android', 'web') then
    v_platform := 'unknown';
  end if;
  -- an anonymous or half-created session has no profile row to point at
  if v_uid is not null and not exists (select 1 from public.profiles where id = v_uid) then
    v_uid := null;
  end if;

  insert into public.push_tokens (user_id, token, platform, weekly_offers)
  values (v_uid, v_token, v_platform, coalesce(p_weekly_offers, true))
  on conflict (token) do update
    set user_id       = excluded.user_id,
        platform      = excluded.platform,
        weekly_offers = excluded.weekly_offers,
        updated_at    = now();
end;
$$;

revoke all on function public.register_push_token(text, text, boolean) from public;
grant execute on function public.register_push_token(text, text, boolean) to anon, authenticated;

notify pgrst, 'reload schema';

commit;

-- Verify (anon key):  POST /rest/v1/rpc/register_push_token {"p_token": "<20+ chars>", "p_platform": "ios"}
--   -> 204.  GET /rest/v1/push_tokens -> [] (no policies: tokens are never readable by the app).
