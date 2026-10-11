-- ============================================================================
-- Aswaq Altaibat — push notifications
-- Builds on schema.sql; run this after it. Adds a device-token registry and
-- a log of every notification composed from the admin dashboard.
-- ============================================================================

create type public.notification_audience as enum ('all', 'weekly_offer_subscribers', 'single_user');
create type public.notification_status as enum ('queued', 'sent', 'failed');

-- One row per device the mobile app has registered for push (FCM/APNs/Expo).
-- Empty until the mobile app exists and starts registering tokens.
create table public.push_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  token       text not null unique,
  platform    text not null default 'unknown', -- 'ios', 'android'
  created_at  timestamptz not null default now()
);

create index idx_push_tokens_user_id on public.push_tokens (user_id);

-- Every notification composed from the dashboard, whether or not a real push
-- provider is wired up yet to actually deliver it.
create table public.notifications (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  body            text not null,
  audience        public.notification_audience not null default 'all',
  target_user_id  uuid references public.profiles (id) on delete set null,
  status          public.notification_status not null default 'queued',
  recipient_count integer not null default 0,
  error_message   text,
  created_at      timestamptz not null default now(),
  sent_at         timestamptz
);

create index idx_notifications_created_at on public.notifications (created_at desc);

alter table public.push_tokens enable row level security;
alter table public.notifications enable row level security;

-- No public policies: only the service_role key (admin dashboard) touches
-- these two tables today. Add a policy here once the mobile app registers
-- its own device token, e.g.:
--
--   create policy "Users manage their own push token"
--     on public.push_tokens for all
--     using (auth.uid() = user_id)
--     with check (auth.uid() = user_id);
