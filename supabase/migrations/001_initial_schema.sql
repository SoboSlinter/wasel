-- =========================================================
-- WASEL MVP — Initial schema (v2, security-reviewed)
-- Run once on a NEW Supabase project: SQL Editor -> New query.
--
-- Security model in one paragraph:
--   * Everything is denied by default (REVOKE ALL), then we grant back
--     only what each role needs, down to the column.
--   * Users can never write role / status / price / commission / rating.
--   * Sensitive changes go through small SECURITY DEFINER functions
--     (register_provider, transition_booking, admin_*), which check
--     who is calling and what they are allowed to do.
-- =========================================================

create extension if not exists "pgcrypto";

-- =========================================================
-- ENUMS
-- =========================================================

create type public.user_role           as enum ('customer', 'provider', 'admin');
create type public.provider_status     as enum ('pending', 'approved', 'suspended');
create type public.service_status      as enum ('draft', 'active', 'inactive');
create type public.booking_status      as enum ('pending', 'confirmed', 'in_progress', 'completed', 'cancelled', 'declined');
create type public.payment_status      as enum ('pending', 'paid', 'failed', 'refunded', 'cancelled');
create type public.subscription_status as enum ('trialing', 'active', 'past_due', 'cancelled', 'incomplete');

-- =========================================================
-- TABLES
-- =========================================================

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  role        public.user_role not null default 'customer',
  avatar_url  text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.provider_profiles (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null unique references public.profiles(id) on delete cascade,
  business_name    text not null,
  description      text,
  phone            text,
  email            text,
  address          text,
  city             text,
  state            text default 'TX',
  zip_code         text,
  latitude         numeric(10,7),
  longitude        numeric(10,7),
  status           public.provider_status not null default 'pending',
  commission_rate  numeric(5,2) not null default 10.00
                   check (commission_rate between 0 and 100),
  rating           numeric(3,2) not null default 0,
  review_count     integer not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table public.services (
  id                uuid primary key default gen_random_uuid(),
  provider_id       uuid not null references public.provider_profiles(id) on delete cascade,
  name              text not null,
  description       text,
  category          text not null default 'car_detailing',
  price             numeric(10,2) not null check (price >= 0),
  duration_minutes  integer not null default 60 check (duration_minutes > 0),
  status            public.service_status not null default 'draft',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table public.service_photos (
  id            uuid primary key default gen_random_uuid(),
  service_id    uuid not null references public.services(id) on delete cascade,
  storage_path  text not null,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now()
);

create table public.bookings (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null references public.profiles(id),
  service_id           uuid not null references public.services(id),
  provider_id          uuid not null references public.provider_profiles(id),
  scheduled_at         timestamptz not null,
  customer_address     text not null,
  customer_city        text,
  customer_state       text default 'TX',
  customer_zip_code    text,
  customer_notes       text,
  service_price        numeric(10,2) not null check (service_price >= 0),
  platform_commission  numeric(10,2) not null default 0 check (platform_commission >= 0),
  provider_payout      numeric(10,2) not null default 0 check (provider_payout >= 0),
  status               public.booking_status not null default 'pending',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table public.payments (
  id                        uuid primary key default gen_random_uuid(),
  booking_id                uuid not null unique references public.bookings(id) on delete cascade,
  customer_id               uuid not null references public.profiles(id),
  amount                    numeric(10,2) not null check (amount >= 0),
  platform_fee              numeric(10,2) not null default 0 check (platform_fee >= 0),
  provider_amount           numeric(10,2) not null default 0 check (provider_amount >= 0),
  status                    public.payment_status not null default 'pending',
  stripe_payment_intent_id  text,
  stripe_transfer_id        text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create table public.reviews (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null unique references public.bookings(id) on delete cascade,
  customer_id  uuid not null references public.profiles(id),
  provider_id  uuid not null references public.provider_profiles(id),
  rating       integer not null check (rating between 1 and 5),
  comment      text,
  created_at   timestamptz not null default now()
);

create table public.subscriptions (
  id                      uuid primary key default gen_random_uuid(),
  provider_id             uuid not null unique references public.provider_profiles(id) on delete cascade,
  plan_name               text not null default 'basic',
  status                  public.subscription_status not null default 'incomplete',
  stripe_customer_id      text,
  stripe_subscription_id  text unique,
  current_period_start    timestamptz,
  current_period_end      timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- =========================================================
-- INDEXES
-- =========================================================

create index idx_services_provider          on public.services(provider_id);
create index idx_services_status            on public.services(status);
create index idx_services_category          on public.services(category);
create index idx_service_photos_service     on public.service_photos(service_id);
create index idx_provider_profiles_status   on public.provider_profiles(status);
create index idx_bookings_customer          on public.bookings(customer_id);
create index idx_bookings_provider          on public.bookings(provider_id);
create index idx_bookings_service           on public.bookings(service_id);
create index idx_bookings_scheduled         on public.bookings(scheduled_at);
create index idx_payments_customer          on public.payments(customer_id);
create index idx_reviews_provider           on public.reviews(provider_id);

-- =========================================================
-- updated_at
-- =========================================================

create or replace function public.set_updated_at()
returns trigger language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_updated_at          before update on public.profiles          for each row execute function public.set_updated_at();
create trigger provider_profiles_updated_at before update on public.provider_profiles for each row execute function public.set_updated_at();
create trigger services_updated_at          before update on public.services          for each row execute function public.set_updated_at();
create trigger bookings_updated_at          before update on public.bookings          for each row execute function public.set_updated_at();
create trigger payments_updated_at          before update on public.payments          for each row execute function public.set_updated_at();
create trigger subscriptions_updated_at     before update on public.subscriptions     for each row execute function public.set_updated_at();

-- =========================================================
-- Auto-create a profile when someone signs up
-- (role is ALWAYS 'customer'; nothing the client sends can change that)
-- =========================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, new.raw_user_meta_data ->> 'full_name', 'customer');
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- =========================================================
-- Admin check (lives in a private schema, so the API never exposes it).
-- Policies call it as the logged-in user, so that role needs EXECUTE.
-- (The USAGE grant on the schema is not strictly required for policies
-- to work, but is the documented convention, so we keep it.)
-- =========================================================

create schema if not exists private;

create or replace function private.is_admin()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.profiles
    where id = (select auth.uid())
      and role = 'admin'
      and is_active = true
  );
$$;

revoke execute on function private.is_admin() from public;
grant usage on schema private to authenticated;
grant execute on function private.is_admin() to authenticated;

-- =========================================================
-- BOOKINGS: the database decides price, commission, provider, status
-- =========================================================

create or replace function public.prepare_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  s record;
begin
  select sv.price, sv.provider_id, p.commission_rate, p.user_id as provider_user_id
    into s
  from public.services sv
  join public.provider_profiles p on p.id = sv.provider_id
  where sv.id = new.service_id
    and sv.status = 'active'
    and p.status  = 'approved';

  if not found then
    raise exception 'Service is not available for booking';
  end if;

  if s.provider_user_id = new.customer_id then
    raise exception 'You cannot book your own service';
  end if;

  if new.scheduled_at <= now() then
    raise exception 'Booking time must be in the future';
  end if;

  new.provider_id         := s.provider_id;
  new.service_price       := s.price;
  new.platform_commission := round(s.price * s.commission_rate / 100, 2);
  new.provider_payout     := s.price - new.platform_commission;
  new.status              := 'pending';
  return new;
end;
$$;

create trigger bookings_prepare
before insert on public.bookings
for each row execute function public.prepare_booking();

-- Status changes: provider confirms/declines/starts/completes, customer cancels.
create or replace function public.transition_booking(
  p_booking_id uuid,
  p_new_status public.booking_status
)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  b           public.bookings;
  uid         uuid := (select auth.uid());
  is_provider boolean;
  is_customer boolean;
  allowed     boolean := false;
begin
  if uid is null then
    raise exception 'Not signed in';
  end if;

  select * into b from public.bookings where id = p_booking_id for update;
  if not found then
    raise exception 'Booking not found';
  end if;

  is_customer := (b.customer_id = uid);
  is_provider := exists (
    select 1 from public.provider_profiles p
    where p.id = b.provider_id and p.user_id = uid
  );

  if is_provider then
    allowed := (b.status = 'pending'     and p_new_status in ('confirmed', 'declined'))
            or (b.status = 'confirmed'   and p_new_status in ('in_progress', 'cancelled'))
            or (b.status = 'in_progress' and p_new_status = 'completed');
  elsif is_customer then
    allowed := (b.status in ('pending', 'confirmed') and p_new_status = 'cancelled');
  else
    raise exception 'Not allowed';
  end if;

  if not allowed then
    raise exception 'Cannot change booking from % to %', b.status, p_new_status;
  end if;

  update public.bookings set status = p_new_status
  where id = p_booking_id
  returning * into b;

  return b;
end;
$$;

-- =========================================================
-- REVIEWS: only the customer of a COMPLETED booking, once.
-- Rating / review_count on the provider are recalculated here.
-- =========================================================

create or replace function public.prepare_review()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
begin
  select * into b from public.bookings where id = new.booking_id;
  if not found or b.status <> 'completed' then
    raise exception 'You can only review a completed booking';
  end if;

  new.customer_id := b.customer_id;   -- RLS then checks it equals the caller
  new.provider_id := b.provider_id;
  return new;
end;
$$;

create trigger reviews_prepare
before insert on public.reviews
for each row execute function public.prepare_review();

create or replace function public.refresh_provider_rating()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.provider_profiles p
  set rating       = coalesce((select round(avg(r.rating), 2) from public.reviews r where r.provider_id = new.provider_id), 0),
      review_count = (select count(*) from public.reviews r where r.provider_id = new.provider_id)
  where p.id = new.provider_id;
  return null;
end;
$$;

create trigger reviews_refresh_rating
after insert on public.reviews
for each row execute function public.refresh_provider_rating();

-- =========================================================
-- PROVIDER ONBOARDING (customers cannot insert provider_profiles directly)
-- =========================================================

create or replace function public.register_provider(
  p_business_name text,
  p_description   text default null,
  p_phone         text default null,
  p_email         text default null,
  p_address       text default null,
  p_city          text default null,
  p_state         text default 'TX',
  p_zip_code      text default null
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  row public.provider_profiles;
begin
  if uid is null then
    raise exception 'Not signed in';
  end if;
  if p_business_name is null or btrim(p_business_name) = '' then
    raise exception 'Business name is required';
  end if;

  insert into public.provider_profiles
    (user_id, business_name, description, phone, email, address, city, state, zip_code)
  values
    (uid, btrim(p_business_name), p_description, p_phone, p_email, p_address, p_city, p_state, p_zip_code)
  returning * into row;

  -- never downgrade an admin
  update public.profiles set role = 'provider'
  where id = uid and role = 'customer';

  return row;
end;
$$;

-- =========================================================
-- ADMIN ACTIONS (called from the admin dashboard, no service_role in the browser)
-- =========================================================

create or replace function public.admin_set_provider_status(
  p_provider_id uuid,
  p_status public.provider_status
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  row public.provider_profiles;
begin
  if not (select private.is_admin()) then
    raise exception 'Admins only';
  end if;

  update public.provider_profiles set status = p_status
  where id = p_provider_id
  returning * into row;

  if not found then
    raise exception 'Provider not found';
  end if;
  return row;
end;
$$;

create or replace function public.admin_set_user_role(
  p_user_id uuid,
  p_role public.user_role
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  row public.profiles;
begin
  if not (select private.is_admin()) then
    raise exception 'Admins only';
  end if;
  if p_user_id = (select auth.uid()) then
    raise exception 'You cannot change your own role';
  end if;

  update public.profiles set role = p_role
  where id = p_user_id
  returning * into row;

  if not found then
    raise exception 'User not found';
  end if;
  return row;
end;
$$;

-- =========================================================
-- ROW LEVEL SECURITY
-- =========================================================

alter table public.profiles          enable row level security;
alter table public.provider_profiles enable row level security;
alter table public.services          enable row level security;
alter table public.service_photos    enable row level security;
alter table public.bookings          enable row level security;
alter table public.payments          enable row level security;
alter table public.reviews           enable row level security;
alter table public.subscriptions     enable row level security;

-- =========================================================
-- PRIVILEGES: deny everything, then grant back the minimum.
-- RLS decides WHICH ROWS; these grants decide WHICH COLUMNS.
-- =========================================================

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- Public (not signed in) can browse
grant select on public.provider_profiles, public.services,
                public.service_photos,    public.reviews
  to anon;

-- Signed-in users can read (RLS filters rows)
grant select on all tables in schema public to authenticated;

-- profiles: only these columns are editable (NOT role, is_active)
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;

-- provider_profiles: no INSERT (use register_provider);
-- NOT status, commission_rate, rating, review_count, user_id
grant update (business_name, description, phone, email, address, city,
              state, zip_code, latitude, longitude)
  on public.provider_profiles to authenticated;

-- services
grant insert (provider_id, name, description, category, price, duration_minutes, status)
  on public.services to authenticated;
grant update (name, description, category, price, duration_minutes, status)
  on public.services to authenticated;
grant delete on public.services to authenticated;

-- service_photos
grant insert, update, delete on public.service_photos to authenticated;

-- bookings: customer supplies only these; price/provider/status are set by trigger.
-- No UPDATE/DELETE: status changes go through transition_booking().
grant insert (customer_id, service_id, scheduled_at, customer_address,
              customer_city, customer_state, customer_zip_code, customer_notes)
  on public.bookings to authenticated;

-- reviews: customer supplies only these; the rest is set by trigger
grant insert (booking_id, rating, comment) on public.reviews to authenticated;

-- payments, subscriptions: read-only for users. Written by the server (Stripe webhook) later.

-- Functions the app may call
grant execute on function public.register_provider(text, text, text, text, text, text, text, text) to authenticated;
grant execute on function public.transition_booking(uuid, public.booking_status)                   to authenticated;
grant execute on function public.admin_set_provider_status(uuid, public.provider_status)           to authenticated;
grant execute on function public.admin_set_user_role(uuid, public.user_role)                       to authenticated;

-- =========================================================
-- POLICIES
-- =========================================================

-- ---------- profiles ----------
create policy "Users can view own profile"
on public.profiles for select to authenticated
using (id = (select auth.uid()));

create policy "Users can update own profile"
on public.profiles for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy "Providers can view customers of their bookings"
on public.profiles for select to authenticated
using (
  exists (
    select 1
    from public.bookings b
    join public.provider_profiles p on p.id = b.provider_id
    where b.customer_id = profiles.id
      and p.user_id = (select auth.uid())
  )
);

create policy "Admins can view all profiles"
on public.profiles for select to authenticated
using ((select private.is_admin()));

-- ---------- provider_profiles ----------
create policy "Approved providers are publicly visible"
on public.provider_profiles for select to anon, authenticated
using (status = 'approved');

create policy "Provider can view own provider profile"
on public.provider_profiles for select to authenticated
using (user_id = (select auth.uid()));

create policy "Provider can update own provider profile"
on public.provider_profiles for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy "Admins can view all provider profiles"
on public.provider_profiles for select to authenticated
using ((select private.is_admin()));

-- ---------- services ----------
create policy "Active services are publicly visible"
on public.services for select to anon, authenticated
using (
  status = 'active'
  and exists (
    select 1 from public.provider_profiles p
    where p.id = services.provider_id and p.status = 'approved'
  )
);

create policy "Provider can view own services"
on public.services for select to authenticated
using (
  exists (
    select 1 from public.provider_profiles p
    where p.id = services.provider_id and p.user_id = (select auth.uid())
  )
);

create policy "Provider can create own services"
on public.services for insert to authenticated
with check (
  exists (
    select 1 from public.provider_profiles p
    where p.id = provider_id
      and p.user_id = (select auth.uid())
      and p.status = 'approved'
  )
);

create policy "Provider can update own services"
on public.services for update to authenticated
using (
  exists (
    select 1 from public.provider_profiles p
    where p.id = services.provider_id and p.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1 from public.provider_profiles p
    where p.id = services.provider_id and p.user_id = (select auth.uid())
  )
);

create policy "Provider can delete own services"
on public.services for delete to authenticated
using (
  exists (
    select 1 from public.provider_profiles p
    where p.id = services.provider_id and p.user_id = (select auth.uid())
  )
);

create policy "Admins can view all services"
on public.services for select to authenticated
using ((select private.is_admin()));

-- ---------- service_photos ----------
create policy "Photos of active services are publicly visible"
on public.service_photos for select to anon, authenticated
using (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id
      and s.status = 'active'
      and p.status = 'approved'
  )
);

create policy "Provider can view own service photos"
on public.service_photos for select to authenticated
using (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
);

create policy "Provider can add own service photos"
on public.service_photos for insert to authenticated
with check (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
);

create policy "Provider can update own service photos"
on public.service_photos for update to authenticated
using (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
);

create policy "Provider can delete own service photos"
on public.service_photos for delete to authenticated
using (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
);

create policy "Admins can view all service photos"
on public.service_photos for select to authenticated
using ((select private.is_admin()));

-- ---------- bookings ----------
create policy "Customers can create own bookings"
on public.bookings for insert to authenticated
with check (customer_id = (select auth.uid()));

create policy "Customers can view own bookings"
on public.bookings for select to authenticated
using (customer_id = (select auth.uid()));

create policy "Providers can view their bookings"
on public.bookings for select to authenticated
using (
  exists (
    select 1 from public.provider_profiles p
    where p.id = bookings.provider_id and p.user_id = (select auth.uid())
  )
);

create policy "Admins can view all bookings"
on public.bookings for select to authenticated
using ((select private.is_admin()));

-- ---------- payments ----------
create policy "Customers can view own payments"
on public.payments for select to authenticated
using (customer_id = (select auth.uid()));

create policy "Admins can view all payments"
on public.payments for select to authenticated
using ((select private.is_admin()));

-- ---------- reviews ----------
create policy "Reviews are publicly visible"
on public.reviews for select to anon, authenticated
using (true);

create policy "Customers can review their completed bookings"
on public.reviews for insert to authenticated
with check (customer_id = (select auth.uid()));

-- ---------- subscriptions ----------
create policy "Providers can view own subscription"
on public.subscriptions for select to authenticated
using (
  exists (
    select 1 from public.provider_profiles p
    where p.id = subscriptions.provider_id and p.user_id = (select auth.uid())
  )
);

create policy "Admins can view all subscriptions"
on public.subscriptions for select to authenticated
using ((select private.is_admin()));
