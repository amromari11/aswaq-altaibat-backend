"""Test SQL migrations against a throwaway local Postgres shaped like the live
Supabase project (auth schema + roles stubbed, schema.sql, 004, the live
delivery_zones/user_addresses shape, 007) - so a migration is proven BEFORE it
touches production.

Setup (once; pgserver ships Postgres inside a pip package and needs Python 3.9-3.12):
    python3.9 -m venv /tmp/pgenv && /tmp/pgenv/bin/pip install pgserver

Usage (from anywhere):
    run_local.py reset [008 009 ...]         # rebuild the baseline, then apply those migrations (by number prefix)
    run_local.py run  supabase/008_*.sql     # apply a migration (fails loudly on any ERROR)
    run_local.py test supabase/tests/008_guest_checkout.test.sql   # one rolled-back transaction
    run_local.py q "select 1"                # ad-hoc query

Note SET LOCAL ROLE only works inside an explicit transaction, which is why
`test` wraps the file in BEGIN ... ROLLBACK.
"""
import os, sys, tempfile
import pgserver

HERE = os.path.dirname(os.path.abspath(__file__))
B = os.path.dirname(HERE) + '/'          # .../supabase/
db = pgserver.get_server(os.path.join(tempfile.gettempdir(), 'aswaq_pgtest_data'), cleanup_mode=None)
STUBS = """
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb, is_anonymous boolean default false);
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema public, auth to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
"""
# Live zones/addresses came from other SQL (see 007); recreate that shape, then apply 007 on top.
LIVE = """
create table public.delivery_zones (id uuid primary key default gen_random_uuid(), name_ar text not null, name_en text,
  delivery_fee numeric(10,3) not null, min_order_amount numeric(10,3) not null default 0, is_active boolean not null default true,
  created_at timestamptz not null default now());
create table public.user_addresses (id uuid primary key default gen_random_uuid(), user_id uuid, zone_id uuid, address_line text,
  latitude numeric, longitude numeric, is_default boolean default false, created_at timestamptz default now(), updated_at timestamptz default now());
insert into public.delivery_zones (name_ar,name_en,delivery_fee,min_order_amount) values
 ('A','Alpha',1.0,5.0),('B','Beta',1.5,7.0),('C','Gamma',1.25,6.0);
"""
import re
def run(sql, label=''):
    # test DB lacks pgcrypto; gen_random_uuid() is built in since PG13 so nothing needs it
    sql = re.sub(r'create extension[^;]*pgcrypto[^;]*;', '', sql, flags=re.I)
    out = db.psql(sql)
    errs = [l for l in out.splitlines() if l.startswith('ERROR:')]
    if errs:
        print('!!', label, *errs[:3], sep='\n   ')
        sys.exit(1)
    return out
cmd = sys.argv[1]
if cmd == 'reset':
    run("drop schema if exists tst cascade; drop schema if exists public cascade; drop schema if exists auth cascade; create schema public; grant all on schema public to public;")
    run(STUBS,'stubs')
    run(open(B+'schema.sql').read(),'schema')
    run(open(B+'004_jod_precision.sql').read(),'004')
    run(LIVE,'live stubs')
    run(open(B+'007_align_live_zones_addresses.sql').read(),'007')
    import glob
    for number in sys.argv[2:]:
        (path,) = glob.glob(B + number + '_*.sql')
        run(open(path).read(), os.path.basename(path))
    print('reset ok')
elif cmd == 'test':
    # one explicit transaction so SET LOCAL ROLE / set_config take effect; rolled back after
    print(run('begin;\n' + open(sys.argv[2]).read() + '\nrollback;', sys.argv[2]))
elif cmd == 'run':
    print(run(open(sys.argv[2]).read(), sys.argv[2]))
elif cmd == 'q':
    print(run(sys.argv[2]))
