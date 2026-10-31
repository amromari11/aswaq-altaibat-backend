-- Tests for 018_push_registration.sql (run_local.py reset 008 009 010).
set local check_function_bodies = off;
create schema tst; grant usage on schema tst to anon, authenticated, service_role;
create table tst.log (ok boolean, name text, detail text);
grant all on tst.log to anon, authenticated, service_role;
create function tst.check(n text, cond boolean, d text default '') returns void language plpgsql as $$
begin insert into tst.log values (coalesce(cond,false), n, d); end $$;
create function tst.expect_err(n text, q text, code text) returns void language plpgsql as $$
declare m text;
begin
  begin execute q; m := 'NO ERROR'; exception when others then m := sqlerrm; end;
  insert into tst.log values (m = code, n, 'wanted ' || code || ' got ' || m);
end $$;
grant execute on all functions in schema tst to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;

-- @include 002_notifications.sql

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'anon-no-profile@example.com');
-- a trigger creates profiles; the third user simulates an anonymous session without one
delete from public.profiles where id = '33333333-3333-3333-3333-333333333333';
grant all on all tables in schema public to service_role;

-- @include 018_push_registration.sql

-- ---- a guest registers ----
set local role anon;
select public.register_push_token('guest-token-aaaaaaaaaaaaaaaaaaaa', 'ios');
reset role;
select tst.check('a guest device is stored with no user',
  (select user_id is null and platform = 'ios' and weekly_offers from public.push_tokens where token = 'guest-token-aaaaaaaaaaaaaaaaaaaa'));

-- ---- the app can neither read nor write the table directly ----
set local role anon;
select tst.check('the app cannot list tokens', (select count(*) = 0 from public.push_tokens));
select tst.expect_err('the app cannot insert a token directly', $q$insert into public.push_tokens (token) values ('direct-insert-token-aaaaaaaaaaaa')$q$, 'new row violates row-level security policy for table "push_tokens"');
delete from public.push_tokens;
reset role;
select tst.check('...and a delete from the app removes nothing', (select count(*) = 1 from public.push_tokens));

-- ---- signing in takes the same device over, without a duplicate row ----
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.register_push_token('guest-token-aaaaaaaaaaaaaaaaaaaa', 'ios', false);
reset role;
select tst.check('same token: one row, now owned by the account, with its offers choice',
  (select count(*) = 1 and bool_and(user_id = '11111111-1111-1111-1111-111111111111') and bool_and(not weekly_offers)
     from public.push_tokens where token = 'guest-token-aaaaaaaaaaaaaaaaaaaa'));

-- ---- another account on the same device (sign-out then sign-in) moves it ----
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.register_push_token('guest-token-aaaaaaaaaaaaaaaaaaaa', 'ios');
reset role;
select tst.check('the device follows the newest account', (select user_id = '22222222-2222-2222-2222-222222222222' from public.push_tokens where token = 'guest-token-aaaaaaaaaaaaaaaaaaaa'));

-- ---- signing out hands it back to a guest ----
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select public.register_push_token('guest-token-aaaaaaaaaaaaaaaaaaaa', 'ios');
reset role;
select tst.check('after sign-out it belongs to nobody', (select user_id is null from public.push_tokens where token = 'guest-token-aaaaaaaaaaaaaaaaaaaa'));

-- ---- an auth user without a profile (anonymous session) still registers ----
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.register_push_token('android-token-bbbbbbbbbbbbbbbbbbbb', 'android');
reset role;
select tst.check('no profile row: stored as a guest, no foreign-key error',
  (select user_id is null and platform = 'android' from public.push_tokens where token = 'android-token-bbbbbbbbbbbbbbbbbbbb'));

-- ---- bad input ----
set local role anon;
select tst.expect_err('too short', $q$select public.register_push_token('short', 'ios')$q$, 'invalid_token');
select tst.expect_err('empty', $q$select public.register_push_token('', 'ios')$q$, 'invalid_token');
select tst.expect_err('null', $q$select public.register_push_token(null, 'ios')$q$, 'invalid_token');
select tst.expect_err('whitespace inside', $q$select public.register_push_token('token with spaces inside it here', 'ios')$q$, 'invalid_token');
select tst.expect_err('absurdly long', format($q$select public.register_push_token(%L, 'ios')$q$, repeat('x', 4097)), 'invalid_token');
select public.register_push_token('  padded-token-cccccccccccccccccc  ', 'WEB');
select public.register_push_token('weird-platform-dddddddddddddddd', 'symbian');
reset role;
select tst.check('surrounding spaces trimmed, platform lower-cased', (select platform = 'web' from public.push_tokens where token = 'padded-token-cccccccccccccccccc'));
select tst.check('unknown platform stored as unknown', (select platform = 'unknown' from public.push_tokens where token = 'weird-platform-dddddddddddddddd'));

-- ---- the dashboard (service role) can read and prune ----
set local role service_role;
select tst.check('service role sees every token', (select count(*) = 4 from public.push_tokens));
delete from public.push_tokens where token = 'weird-platform-dddddddddddddddd';
select tst.check('service role can delete a dead token', (select count(*) = 3 from public.push_tokens));
update public.notifications set failed_count = 1 where false;
reset role;

-- ---- deleting an account removes its devices; guests' devices stay ----
insert into public.push_tokens (user_id, token) values ('11111111-1111-1111-1111-111111111111', 'user-a-token-eeeeeeeeeeeeeeeeee');
delete from auth.users where id = '11111111-1111-1111-1111-111111111111';
select tst.check('account deletion cascades to its tokens', (select count(*) = 0 from public.push_tokens where token = 'user-a-token-eeeeeeeeeeeeeeeeee'));
select tst.check('guest tokens are unaffected', (select count(*) = 3 from public.push_tokens));

-- ---- running it again changes nothing ----
-- @include 018_push_registration.sql
select tst.check('re-run keeps the data', (select count(*) = 3 from public.push_tokens));
select tst.check('exactly one register_push_token', (select count(*) = 1 from pg_proc where proname = 'register_push_token'));
select tst.check('the app may call it',
  has_function_privilege('anon', 'public.register_push_token(text,text,boolean)', 'execute'));
select tst.check('but "public" cannot', not exists (
  select 1 from pg_proc p, aclexplode(p.proacl) a where p.proname = 'register_push_token' and a.grantee = 0));
select tst.check('notifications has failed_count', exists (select 1 from information_schema.columns where table_name = 'notifications' and column_name = 'failed_count'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '   -> ' || detail end as result from tst.log order by ok, name;
