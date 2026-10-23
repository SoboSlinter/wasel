-- ==========================================================
-- WASEL — full database schema (migrations 001-024 merged, in order).
-- Run ONCE on a NEW, EMPTY Supabase project (SQL Editor, or as one migration).
-- The separate files in migrations/ stay as the history; this is the same SQL in one file.
-- ==========================================================

-- ########## 001_initial_schema.sql ##########
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


-- ########## 002_storage.sql ##########
-- =========================================================
-- WASEL MVP — Storage for service photos
-- Run AFTER 001_initial_schema.sql.
--
-- Upload path convention (the first folder MUST be the provider's user id):
--   <auth user id>/<service id>/<filename>
-- e.g.  3f2a.../9c1b.../before-after.jpg
-- =========================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'service-photos',
  'service-photos',
  true,                                   -- photos are shown publicly
  5242880,                                -- 5 MB
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

create policy "Service photos are publicly readable"
on storage.objects for select
using (bucket_id = 'service-photos');

create policy "Providers can upload to their own folder"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Providers can update files in their own folder"
on storage.objects for update to authenticated
using (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Providers can delete files in their own folder"
on storage.objects for delete to authenticated
using (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);


-- ########## 003_booking_visibility.sql ##########
-- =========================================================
-- WASEL MVP — Let customers keep seeing what they booked
-- Run AFTER 001 and 002.
--
-- Problem: a customer can only see ACTIVE services of APPROVED providers.
-- If a provider later deactivates a service (or is suspended), the customer's
-- booking history would lose the service name and provider.
-- Fix: customers may also see the service/provider of their own bookings.
--
-- The checks live in small SECURITY DEFINER functions so the policies do not
-- loop back through each other (Postgres would report "infinite recursion").
-- =========================================================

create or replace function private.is_my_booked_service(p_service_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bookings b
    where b.service_id = p_service_id
      and b.customer_id = (select auth.uid())
  );
$$;

create or replace function private.is_my_booked_provider(p_provider_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bookings b
    where b.provider_id = p_provider_id
      and b.customer_id = (select auth.uid())
  );
$$;

revoke execute on function private.is_my_booked_service(uuid)  from public;
revoke execute on function private.is_my_booked_provider(uuid) from public;
grant  execute on function private.is_my_booked_service(uuid)  to authenticated;
grant  execute on function private.is_my_booked_provider(uuid) to authenticated;

create policy "Customers can view services they booked"
on public.services for select to authenticated
using ((select private.is_my_booked_service(id)));

create policy "Customers can view providers they booked"
on public.provider_profiles for select to authenticated
using ((select private.is_my_booked_provider(id)));


-- ########## 004_photo_rules.sql ##########
-- =========================================================
-- WASEL MVP — Rules for service photos
-- Run AFTER 001, 002 and 003.
--
-- 1) A photo row must point at a file inside the provider's OWN storage folder
--    (<their user id>/...). Otherwise a provider could point a row at someone
--    else's file.
-- 2) At most 5 photos per service.
-- =========================================================

alter policy "Provider can add own service photos"
on public.service_photos
with check (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
  and split_part(storage_path, '/', 1) = (select auth.uid())::text
);

alter policy "Provider can update own service photos"
on public.service_photos
with check (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
  and split_part(storage_path, '/', 1) = (select auth.uid())::text
);

create or replace function public.limit_service_photos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.service_photos where service_id = new.service_id) >= 5 then
    raise exception 'A service can have at most 5 photos';
  end if;
  return new;
end;
$$;

create trigger service_photos_limit
before insert on public.service_photos
for each row execute function public.limit_service_photos();


-- ########## 005_payments.sql ##########
-- =========================================================
-- WASEL MVP — Card payments for bookings (Stripe Checkout)
-- Run AFTER 004. These functions are for the SERVER ONLY (Edge Functions
-- using the service_role key). Browsers/users cannot call them.
-- =========================================================

alter table public.payments
  add column if not exists stripe_checkout_session_id text unique;

-- Step 1 (called by create-checkout): validate the booking and make sure there is a
-- pending payment row with the amount taken from the DATABASE, never from the browser.
create or replace function public.start_booking_payment(p_booking_id uuid, p_customer_id uuid)
returns table (payment_id uuid, amount numeric, service_name text)
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
  existing public.payments%rowtype;
  sname text;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or b.customer_id <> p_customer_id then
    raise exception 'Booking not found';
  end if;
  if b.status not in ('confirmed', 'in_progress', 'completed') then
    raise exception 'The provider must confirm the booking before you can pay';
  end if;
  select * into existing from public.payments where booking_id = b.id;
  if found and existing.status = 'paid' then
    raise exception 'This booking is already paid';
  end if;
  if b.service_price <= 0 then
    raise exception 'Nothing to pay for this booking';
  end if;

  select name into sname from public.services where id = b.service_id;

  insert into public.payments (booking_id, customer_id, amount, platform_fee, provider_amount, status)
  values (b.id, b.customer_id, b.service_price, b.platform_commission, b.provider_payout, 'pending')
  on conflict (booking_id) do update
    set amount = excluded.amount, platform_fee = excluded.platform_fee,
        provider_amount = excluded.provider_amount, status = 'pending'
  returning id into payment_id;

  amount := b.service_price;
  service_name := coalesce(sname, 'Service');
  return next;
end $$;

-- Step 2 (called by create-checkout): remember which Stripe session belongs to the payment.
create or replace function public.attach_checkout_session(p_payment_id uuid, p_session_id text)
returns void language sql security definer set search_path = '' as $$
  update public.payments set stripe_checkout_session_id = p_session_id
  where id = p_payment_id and status = 'pending';
$$;

-- Step 3 (called by stripe-webhook): idempotent result. Amount must match exactly.
create or replace function public.record_payment_result(
  p_session_id text, p_payment_intent text, p_amount_paid numeric, p_outcome text)
returns text language plpgsql security definer set search_path = '' as $$
declare pay public.payments%rowtype;
begin
  select * into pay from public.payments where stripe_checkout_session_id = p_session_id for update;
  if not found then return 'unknown_session'; end if;
  if pay.status = 'paid' then return 'already_paid'; end if;

  if p_outcome = 'paid' then
    if p_amount_paid is distinct from pay.amount then
      update public.payments set status = 'failed', stripe_payment_intent_id = p_payment_intent
      where id = pay.id;
      return 'amount_mismatch';
    end if;
    update public.payments set status = 'paid', stripe_payment_intent_id = p_payment_intent
    where id = pay.id;
    return 'paid';
  elsif p_outcome = 'expired' then
    update public.payments set status = 'cancelled' where id = pay.id;
    return 'cancelled';
  else
    update public.payments set status = 'failed' where id = pay.id;
    return 'failed';
  end if;
end $$;

revoke all on function public.start_booking_payment(uuid, uuid)                 from public, anon, authenticated;
revoke all on function public.attach_checkout_session(uuid, text)               from public, anon, authenticated;
revoke all on function public.record_payment_result(text, text, numeric, text)  from public, anon, authenticated;
grant execute on function public.start_booking_payment(uuid, uuid)                to service_role;
grant execute on function public.attach_checkout_session(uuid, text)              to service_role;
grant execute on function public.record_payment_result(text, text, numeric, text) to service_role;


-- ########## 006_provider_payouts.sql ##########
-- =========================================================
-- WASEL MVP — Provider payouts (Stripe Connect Express)
-- Run AFTER 005. Money rule: the provider's share is sent when the booking is
-- COMPLETED and the customer has PAID. Whichever happens last triggers the payout.
-- =========================================================

alter table public.payments
  add column if not exists payout_status text not null default 'none'
    check (payout_status in ('none', 'processing', 'sent', 'failed')),
  add column if not exists payout_at timestamptz;

-- Stripe account ids live in their own table: provider_profiles is publicly readable,
-- and these must never be. RLS on with NO policies = nobody but the server can read it.
create table public.provider_payout_accounts (
  provider_id        uuid primary key references public.provider_profiles(id) on delete cascade,
  stripe_account_id  text not null unique,
  payouts_enabled    boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
alter table public.provider_payout_accounts enable row level security;
revoke all on public.provider_payout_accounts from public, anon, authenticated;
create trigger provider_payout_accounts_updated_at before update on public.provider_payout_accounts
  for each row execute function public.set_updated_at();

-- ---------- what a provider may see about their own payouts ----------
create or replace function public.my_payout_status()
returns table (connected boolean, payouts_enabled boolean)
language sql stable security definer set search_path = '' as $$
  select (a.provider_id is not null), coalesce(a.payouts_enabled, false)
  from public.provider_profiles p
  left join public.provider_payout_accounts a on a.provider_id = p.id
  where p.user_id = (select auth.uid());
$$;

create or replace function public.my_booking_payouts()
returns table (booking_id uuid, paid boolean, payout_status text)
language sql stable security definer set search_path = '' as $$
  select b.id, (pay.status = 'paid'), pay.payout_status
  from public.bookings b
  join public.provider_profiles p on p.id = b.provider_id
  join public.payments pay on pay.booking_id = b.id
  where p.user_id = (select auth.uid());
$$;

-- ---------- server-only helpers (Edge Functions with the service_role key) ----------
create or replace function public.payout_account_for_user(p_user_id uuid)
returns table (provider_id uuid, business_name text, email text, stripe_account_id text)
language plpgsql security definer set search_path = '' as $$
begin
  return query
    select p.id, p.business_name, p.email, a.stripe_account_id
    from public.provider_profiles p
    left join public.provider_payout_accounts a on a.provider_id = p.id
    where p.user_id = p_user_id and p.status = 'approved';
  if not found then raise exception 'Only approved providers can set up payouts'; end if;
end $$;

create or replace function public.save_payout_account(p_provider_id uuid, p_account_id text)
returns void language sql security definer set search_path = '' as $$
  insert into public.provider_payout_accounts (provider_id, stripe_account_id)
  values (p_provider_id, p_account_id)
  on conflict (provider_id) do nothing;
$$;

create or replace function public.set_payout_account_status(p_account_id text, p_enabled boolean)
returns uuid language sql security definer set search_path = '' as $$
  update public.provider_payout_accounts set payouts_enabled = p_enabled
  where stripe_account_id = p_account_id
  returning provider_id;
$$;

create or replace function public.find_payment(p_booking_id uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.payments where booking_id = p_booking_id;
$$;

create or replace function public.find_payment_by_session(p_session_id text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.payments where stripe_checkout_session_id = p_session_id;
$$;

create or replace function public.payments_awaiting_payout(p_account_id text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select pay.id
  from public.payments pay
  join public.bookings b on b.id = pay.booking_id
  join public.provider_payout_accounts a on a.provider_id = b.provider_id
  where a.stripe_account_id = p_account_id
    and pay.status = 'paid' and pay.payout_status in ('none', 'failed')
    and b.status = 'completed';
$$;

-- Decide whether a payout may go out now, and lock it (status -> processing).
-- p_caller = the signed-in provider asking, or null when the server itself decides.
create or replace function public.claim_payout(p_payment_id uuid, p_caller uuid)
returns table (code text, amount numeric, account_id text, payment_intent text, booking_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  b public.bookings%rowtype;
  owner uuid;
  acct public.provider_payout_accounts%rowtype;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  select * into b from public.bookings where id = pay.booking_id;
  select user_id into owner from public.provider_profiles where id = b.provider_id;
  if p_caller is not null and owner is distinct from p_caller then
    raise exception 'Payment not found';
  end if;

  booking_id := b.id; payment_intent := pay.stripe_payment_intent_id; amount := pay.provider_amount;
  if pay.payout_status = 'sent'
     or (pay.payout_status = 'processing' and pay.payout_at > now() - interval '10 minutes') then
    code := 'already';
  elsif pay.status <> 'paid' then code := 'not_paid';
  elsif b.status <> 'completed' then code := 'not_completed';
  else
    select * into acct from public.provider_payout_accounts where provider_id = b.provider_id;
    if not found or not acct.payouts_enabled then
      code := 'no_account';
    elsif pay.provider_amount <= 0 or pay.stripe_payment_intent_id is null then
      code := 'nothing_to_pay';
    else
      update public.payments set payout_status = 'processing', payout_at = now() where id = pay.id;
      code := 'ok'; account_id := acct.stripe_account_id;
    end if;
  end if;
  return next;
end $$;

create or replace function public.finish_payout(p_payment_id uuid, p_transfer_id text)
returns void language sql security definer set search_path = '' as $$
  update public.payments set payout_status = 'sent', stripe_transfer_id = p_transfer_id, payout_at = now()
  where id = p_payment_id and payout_status <> 'sent';
$$;

create or replace function public.fail_payout(p_payment_id uuid)
returns void language sql security definer set search_path = '' as $$
  update public.payments set payout_status = 'failed' where id = p_payment_id and payout_status = 'processing';
$$;

-- ---------- who may call what ----------
revoke all on function public.my_payout_status()                       from public, anon, authenticated;
revoke all on function public.my_booking_payouts()                     from public, anon, authenticated;
grant execute on function public.my_payout_status()                    to authenticated;
grant execute on function public.my_booking_payouts()                  to authenticated;

revoke all on function public.payout_account_for_user(uuid)            from public, anon, authenticated;
revoke all on function public.save_payout_account(uuid, text)          from public, anon, authenticated;
revoke all on function public.set_payout_account_status(text, boolean) from public, anon, authenticated;
revoke all on function public.find_payment(uuid)                       from public, anon, authenticated;
revoke all on function public.find_payment_by_session(text)            from public, anon, authenticated;
revoke all on function public.payments_awaiting_payout(text)           from public, anon, authenticated;
revoke all on function public.claim_payout(uuid, uuid)                 from public, anon, authenticated;
revoke all on function public.finish_payout(uuid, text)                from public, anon, authenticated;
revoke all on function public.fail_payout(uuid)                        from public, anon, authenticated;
grant execute on function public.payout_account_for_user(uuid)            to service_role;
grant execute on function public.save_payout_account(uuid, text)          to service_role;
grant execute on function public.set_payout_account_status(text, boolean) to service_role;
grant execute on function public.find_payment(uuid)                       to service_role;
grant execute on function public.find_payment_by_session(text)            to service_role;
grant execute on function public.payments_awaiting_payout(text)           to service_role;
grant execute on function public.claim_payout(uuid, uuid)                 to service_role;
grant execute on function public.finish_payout(uuid, text)                to service_role;
grant execute on function public.fail_payout(uuid)                        to service_role;


-- ########## 007_service_areas.sql ##########
-- =========================================================
-- WASEL MVP — Service areas
-- Providers choose where they work (cities and/or ZIP codes).
-- Customers search by city or ZIP and only see providers who serve that place.
-- Run AFTER 006.
-- =========================================================

create table public.provider_service_areas (
  id           uuid primary key default gen_random_uuid(),
  provider_id  uuid not null references public.provider_profiles(id) on delete cascade,
  kind         text not null check (kind in ('zip', 'city')),
  label        text not null check (char_length(label) between 2 and 60),   -- "75038" or "Irving"
  created_at   timestamptz not null default now(),
  check ((kind = 'zip'  and label ~ '^[0-9]{5}$')
      or (kind = 'city' and label ~ '^[A-Za-z][A-Za-z .''-]{1,59}$'))
);
create unique index uq_service_area on public.provider_service_areas (provider_id, lower(label));
create index idx_service_area_label on public.provider_service_areas (lower(label));

alter table public.provider_service_areas enable row level security;
revoke all on public.provider_service_areas from public, anon, authenticated;
grant select on public.provider_service_areas to anon, authenticated;     -- writes only through set_service_areas()

-- Whoever can see a provider can see where that provider works.
create policy "Areas follow provider visibility"
on public.provider_service_areas for select to anon, authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id));

-- Replace my service areas with this list. Each entry is a 5-digit ZIP or a city name.
create or replace function public.set_service_areas(p_areas text[])
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  pid uuid;
  item text;
  clean text;
  kind text;
  seen text[] := '{}';
  n integer := 0;
begin
  select id into pid from public.provider_profiles where user_id = (select auth.uid());
  if pid is null then raise exception 'Only providers can set service areas'; end if;

  delete from public.provider_service_areas where provider_id = pid;

  foreach item in array coalesce(p_areas, '{}') loop
    clean := regexp_replace(btrim(coalesce(item, '')), '\s+', ' ', 'g');
    clean := regexp_replace(clean, ',\s*(tx|texas)$', '', 'i');           -- "Irving, TX" -> "Irving"
    if clean = '' then continue; end if;
    if clean ~ '^[0-9]{5}$' then kind := 'zip';
    elsif clean ~ '^[A-Za-z][A-Za-z .''-]{1,59}$' then
      kind := 'city';
      -- all-lower or ALL-CAPS typing is tidied ("irving" -> "Irving"); mixed case like "McKinney" is kept as typed
      if clean = lower(clean) or clean = upper(clean) then clean := initcap(lower(clean)); end if;
    else raise exception 'Not a valid city or ZIP code: %', left(clean, 40);
    end if;
    if lower(clean) = any (seen) then continue; end if;
    seen := seen || lower(clean);
    n := n + 1;
    if n > 30 then raise exception 'You can list at most 30 areas'; end if;
    insert into public.provider_service_areas (provider_id, kind, label) values (pid, kind, clean);
  end loop;
  return n;
end $$;

-- Which services work in this place? Uses the caller's own visibility (RLS), so
-- customers only ever get active services of approved providers.
create or replace function public.services_in_area(p_place text)
returns setof uuid
language sql stable security invoker set search_path = '' as $$
  with q as (
    select case
      when btrim(p_place) ~ '^[0-9]{5}(-[0-9]{4})?$' then left(btrim(p_place), 5)
      else lower(regexp_replace(regexp_replace(btrim(p_place), '\s+', ' ', 'g'), ',\s*(tx|texas)$', '', 'i'))
    end as place
  )
  select s.id
  from public.services s
  join public.provider_service_areas a on a.provider_id = s.provider_id, q
  where lower(a.label) = q.place
  limit 500;
$$;

revoke all on function public.set_service_areas(text[]) from public, anon, authenticated;
grant execute on function public.set_service_areas(text[]) to authenticated;
revoke all on function public.services_in_area(text) from public, anon, authenticated;
grant execute on function public.services_in_area(text) to anon, authenticated;


-- ########## 008_refunds.sql ##########
-- =========================================================
-- WASEL MVP — Refunds
-- Rule: if a booking is cancelled AFTER the customer paid, the customer gets the
-- full amount back. (Only pending/confirmed bookings can be cancelled, so the
-- provider has never been paid for them.) Run AFTER 007.
-- =========================================================

alter table public.payments
  add column if not exists refund_status text not null default 'none'
    check (refund_status in ('none', 'requested', 'processing', 'done', 'failed')),
  add column if not exists stripe_refund_id text,
  add column if not exists refund_at timestamptz;

-- 1) A booking is cancelled/declined and was paid -> a refund is requested automatically.
create or replace function public.request_refund_on_cancel()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('cancelled', 'declined') and old.status is distinct from new.status then
    update public.payments set refund_status = 'requested', refund_at = now()
    where booking_id = new.id and status = 'paid' and refund_status = 'none';
  end if;
  return new;
end $$;
revoke all on function public.request_refund_on_cancel() from public, anon, authenticated;

create trigger bookings_request_refund
after update of status on public.bookings
for each row execute function public.request_refund_on_cancel();

-- 2) Same payment function as 005, plus: money that arrives for an already-cancelled booking is refunded.
create or replace function public.record_payment_result(
  p_session_id text, p_payment_intent text, p_amount_paid numeric, p_outcome text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  bstatus public.booking_status;
begin
  select * into pay from public.payments where stripe_checkout_session_id = p_session_id for update;
  if not found then return 'unknown_session'; end if;
  if pay.status in ('paid', 'refunded') then return 'already_paid'; end if;

  if p_outcome = 'paid' then
    if p_amount_paid is distinct from pay.amount then
      update public.payments set status = 'failed', stripe_payment_intent_id = p_payment_intent
      where id = pay.id;
      return 'amount_mismatch';
    end if;
    update public.payments set status = 'paid', stripe_payment_intent_id = p_payment_intent
    where id = pay.id;
    select status into bstatus from public.bookings where id = pay.booking_id;
    if bstatus in ('cancelled', 'declined') then
      update public.payments set refund_status = 'requested', refund_at = now() where id = pay.id;
      return 'paid_cancelled';
    end if;
    return 'paid';
  elsif p_outcome = 'expired' then
    update public.payments set status = 'cancelled' where id = pay.id;
    return 'cancelled';
  else
    update public.payments set status = 'failed' where id = pay.id;
    return 'failed';
  end if;
end $$;
revoke all on function public.record_payment_result(text, text, numeric, text) from public, anon, authenticated;
grant execute on function public.record_payment_result(text, text, numeric, text) to service_role;

-- 3) Decide whether a refund may go out now, and lock it (status -> processing).
-- p_caller = the signed-in customer/provider asking, or null when the server itself decides.
create or replace function public.claim_refund(p_payment_id uuid, p_caller uuid)
returns table (code text, amount numeric, payment_intent text, booking_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  b public.bookings%rowtype;
  owner uuid;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  select * into b from public.bookings where id = pay.booking_id;
  select user_id into owner from public.provider_profiles where id = b.provider_id;
  if p_caller is not null and p_caller is distinct from b.customer_id and p_caller is distinct from owner then
    raise exception 'Payment not found';
  end if;

  booking_id := b.id; payment_intent := pay.stripe_payment_intent_id; amount := pay.amount;
  if pay.refund_status = 'done' or pay.status = 'refunded'
     or (pay.refund_status = 'processing' and pay.refund_at > now() - interval '10 minutes') then
    code := 'already';
  elsif pay.status <> 'paid' then code := 'not_paid';
  elsif b.status not in ('cancelled', 'declined') then code := 'not_cancelled';
  elsif pay.stripe_payment_intent_id is null then code := 'nothing_to_refund';
  else
    update public.payments set refund_status = 'processing', refund_at = now() where id = pay.id;
    code := 'ok';
  end if;
  return next;
end $$;

create or replace function public.finish_refund(p_payment_id uuid, p_refund_id text)
returns void language sql security definer set search_path = '' as $$
  update public.payments
  set status = 'refunded', refund_status = 'done', stripe_refund_id = coalesce(p_refund_id, stripe_refund_id), refund_at = now()
  where id = p_payment_id and refund_status <> 'done';
$$;

create or replace function public.fail_refund(p_payment_id uuid)
returns void language sql security definer set search_path = '' as $$
  update public.payments set refund_status = 'failed' where id = p_payment_id and refund_status = 'processing';
$$;

-- Stripe tells us a charge was refunded (also covers refunds made by hand in the Stripe dashboard).
create or replace function public.record_refund_event(p_payment_intent text, p_refund_id text)
returns text language plpgsql security definer set search_path = '' as $$
declare pay public.payments%rowtype;
begin
  select * into pay from public.payments where stripe_payment_intent_id = p_payment_intent for update;
  if not found then return 'unknown_payment'; end if;
  if pay.refund_status = 'done' then return 'already_refunded'; end if;
  update public.payments
  set status = 'refunded', refund_status = 'done', stripe_refund_id = coalesce(p_refund_id, stripe_refund_id), refund_at = now()
  where id = pay.id;
  return 'refunded';
end $$;

revoke all on function public.claim_refund(uuid, uuid)               from public, anon, authenticated;
revoke all on function public.finish_refund(uuid, text)              from public, anon, authenticated;
revoke all on function public.fail_refund(uuid)                      from public, anon, authenticated;
revoke all on function public.record_refund_event(text, text)        from public, anon, authenticated;
grant execute on function public.claim_refund(uuid, uuid)               to service_role;
grant execute on function public.finish_refund(uuid, text)              to service_role;
grant execute on function public.fail_refund(uuid)                      to service_role;
grant execute on function public.record_refund_event(text, text)        to service_role;


-- ########## 009_disputes.sql ##########
-- =========================================================
-- WASEL MVP — Disputes (chargebacks)
-- A dispute is when the customer asks their bank to take the money back.
-- Rules: while a payment is disputed (or after it is lost) the provider is NOT paid
-- and it cannot be refunded by us (the bank holds the money). If the dispute is won,
-- everything goes back to normal. Run AFTER 008.
-- =========================================================

alter table public.payments
  add column if not exists dispute_status text not null default 'none'
    check (dispute_status in ('none', 'open', 'won', 'lost')),
  add column if not exists stripe_dispute_id text,
  add column if not exists dispute_at timestamptz;

create index if not exists idx_payments_dispute on public.payments(dispute_status) where dispute_status <> 'none';

-- Stripe tells us about a dispute. p_kind: 'created' | 'closed'. p_outcome (closed only): 'won' | 'lost'.
-- Returns: 'opened' | 'won' | 'lost' | 'already' | 'unknown_payment' | 'ignored'
create or replace function public.record_dispute_event(
  p_payment_intent text, p_dispute_id text, p_kind text, p_outcome text)
returns text language plpgsql security definer set search_path = '' as $$
declare pay public.payments%rowtype;
begin
  select * into pay from public.payments where stripe_payment_intent_id = p_payment_intent for update;
  if not found then return 'unknown_payment'; end if;

  if p_kind = 'created' then
    if pay.dispute_status in ('open', 'lost') then return 'already'; end if;
    update public.payments set dispute_status = 'open', stripe_dispute_id = p_dispute_id, dispute_at = now()
    where id = pay.id;
    return 'opened';
  elsif p_kind = 'closed' and p_outcome in ('won', 'lost') then
    if pay.dispute_status = p_outcome then return 'already'; end if;
    update public.payments
    set dispute_status = p_outcome, stripe_dispute_id = coalesce(p_dispute_id, stripe_dispute_id), dispute_at = now()
    where id = pay.id;
    return p_outcome;
  end if;
  return 'ignored';
end $$;

-- Payout: not while disputed / after a lost dispute. (Same as 006 plus the 'disputed' code.)
create or replace function public.claim_payout(p_payment_id uuid, p_caller uuid)
returns table (code text, amount numeric, account_id text, payment_intent text, booking_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  b public.bookings%rowtype;
  owner uuid;
  acct public.provider_payout_accounts%rowtype;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  select * into b from public.bookings where id = pay.booking_id;
  select user_id into owner from public.provider_profiles where id = b.provider_id;
  if p_caller is not null and owner is distinct from p_caller then
    raise exception 'Payment not found';
  end if;

  booking_id := b.id; payment_intent := pay.stripe_payment_intent_id; amount := pay.provider_amount;
  if pay.payout_status = 'sent'
     or (pay.payout_status = 'processing' and pay.payout_at > now() - interval '10 minutes') then
    code := 'already';
  elsif pay.status <> 'paid' then code := 'not_paid';
  elsif pay.dispute_status in ('open', 'lost') then code := 'disputed';
  elsif b.status <> 'completed' then code := 'not_completed';
  else
    select * into acct from public.provider_payout_accounts where provider_id = b.provider_id;
    if not found or not acct.payouts_enabled then
      code := 'no_account';
    elsif pay.provider_amount <= 0 or pay.stripe_payment_intent_id is null then
      code := 'nothing_to_pay';
    else
      update public.payments set payout_status = 'processing', payout_at = now() where id = pay.id;
      code := 'ok'; account_id := acct.stripe_account_id;
    end if;
  end if;
  return next;
end $$;

-- The "waiting for payout" list also skips disputed payments.
create or replace function public.payments_awaiting_payout(p_account_id text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select pay.id
  from public.payments pay
  join public.bookings b on b.id = pay.booking_id
  join public.provider_payout_accounts a on a.provider_id = b.provider_id
  where a.stripe_account_id = p_account_id
    and pay.status = 'paid' and pay.payout_status in ('none', 'failed')
    and pay.dispute_status in ('none', 'won')
    and b.status = 'completed';
$$;

-- Refund: Stripe will not refund money the bank is holding.
create or replace function public.claim_refund(p_payment_id uuid, p_caller uuid)
returns table (code text, amount numeric, payment_intent text, booking_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  b public.bookings%rowtype;
  owner uuid;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  select * into b from public.bookings where id = pay.booking_id;
  select user_id into owner from public.provider_profiles where id = b.provider_id;
  if p_caller is not null and p_caller is distinct from b.customer_id and p_caller is distinct from owner then
    raise exception 'Payment not found';
  end if;

  booking_id := b.id; payment_intent := pay.stripe_payment_intent_id; amount := pay.amount;
  if pay.refund_status = 'done' or pay.status = 'refunded'
     or (pay.refund_status = 'processing' and pay.refund_at > now() - interval '10 minutes') then
    code := 'already';
  elsif pay.status <> 'paid' then code := 'not_paid';
  elsif pay.dispute_status in ('open', 'lost') then code := 'disputed';
  elsif b.status not in ('cancelled', 'declined') then code := 'not_cancelled';
  elsif pay.stripe_payment_intent_id is null then code := 'nothing_to_refund';
  else
    update public.payments set refund_status = 'processing', refund_at = now() where id = pay.id;
    code := 'ok';
  end if;
  return next;
end $$;

-- Admin list. Only admins get rows. A payout that was already sent for a lost dispute is flagged.
create or replace function public.admin_disputes()
returns table (payment_id uuid, booking_id uuid, service_name text, provider_name text, customer_name text,
               amount numeric, dispute_status text, disputed_at timestamptz, payout_status text, payout_already_sent boolean)
language sql stable security definer set search_path = '' as $$
  select pay.id, b.id, s.name, pp.business_name, c.full_name,
         pay.amount, pay.dispute_status, pay.dispute_at, pay.payout_status,
         (pay.payout_status = 'sent' and pay.dispute_status in ('open', 'lost'))
  from public.payments pay
  join public.bookings b on b.id = pay.booking_id
  join public.services s on s.id = b.service_id
  join public.provider_profiles pp on pp.id = b.provider_id
  left join public.profiles c on c.id = b.customer_id
  where pay.dispute_status <> 'none'
    and exists (select 1 from public.profiles me where me.id = (select auth.uid()) and me.role = 'admin')
  order by pay.dispute_at desc;
$$;

-- Provider's per-booking payout list now also says if the payment is disputed.
drop function if exists public.my_booking_payouts();
create or replace function public.my_booking_payouts()
returns table (booking_id uuid, paid boolean, payout_status text, dispute_status text)
language sql stable security definer set search_path = '' as $$
  select b.id, (pay.status = 'paid'), pay.payout_status, pay.dispute_status
  from public.bookings b
  join public.provider_profiles p on p.id = b.provider_id
  join public.payments pay on pay.booking_id = b.id
  where p.user_id = (select auth.uid());
$$;

revoke all on function public.record_dispute_event(text, text, text, text) from public, anon, authenticated;
revoke all on function public.claim_payout(uuid, uuid)                      from public, anon, authenticated;
revoke all on function public.payments_awaiting_payout(text)                from public, anon, authenticated;
revoke all on function public.claim_refund(uuid, uuid)                      from public, anon, authenticated;
revoke all on function public.admin_disputes()                              from public, anon, authenticated;
revoke all on function public.my_booking_payouts()                          from public, anon, authenticated;
grant execute on function public.record_dispute_event(text, text, text, text) to service_role;
grant execute on function public.claim_payout(uuid, uuid)                      to service_role;
grant execute on function public.payments_awaiting_payout(text)                to service_role;
grant execute on function public.claim_refund(uuid, uuid)                      to service_role;
grant execute on function public.admin_disputes()                              to authenticated;
grant execute on function public.my_booking_payouts()                          to authenticated;

create or replace function public.find_payment_by_intent(p_payment_intent text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.payments where stripe_payment_intent_id = p_payment_intent;
$$;
revoke all on function public.find_payment_by_intent(text) from public, anon, authenticated;
grant execute on function public.find_payment_by_intent(text) to service_role;


-- ########## 010_subscriptions.sql ##########
-- =========================================================
-- WASEL MVP — Provider subscriptions ("Wasel Pro")
-- Free plan: 10% platform fee.  Pro plan ($19/month, set in Stripe): 5% fee and listed first in search.
-- The fee is copied onto a booking when it is created, so changing plan never changes old bookings.
-- Run AFTER 009.
-- =========================================================

alter table public.provider_profiles
  add column if not exists is_pro boolean not null default false;   -- public: used to sort search and show the badge

-- one place that says what each plan costs (percent)
create or replace function public.plan_commission(p_pro boolean)
returns numeric language sql immutable set search_path = '' as $$ select case when p_pro then 5.00 else 10.00 end $$;

-- Server: may this user start a subscription? Returns the provider and any saved Stripe customer.
create or replace function public.subscription_context(p_user_id uuid)
returns table (provider_id uuid, business_name text, email text, stripe_customer_id text, already_pro boolean)
language plpgsql security definer set search_path = '' as $$
declare p public.provider_profiles%rowtype;
begin
  select * into p from public.provider_profiles where user_id = p_user_id;
  if not found then raise exception 'Only providers can subscribe'; end if;
  if p.status <> 'approved' then raise exception 'Your provider account must be approved first'; end if;
  return query
    select p.id, p.business_name, p.email, s.stripe_customer_id, p.is_pro
    from (select 1) x left join public.subscriptions s on s.provider_id = p.id;
end $$;

create or replace function public.save_subscription_customer(p_provider_id uuid, p_customer_id text)
returns void language sql security definer set search_path = '' as $$
  insert into public.subscriptions (provider_id, stripe_customer_id) values (p_provider_id, p_customer_id)
  on conflict (provider_id) do update set stripe_customer_id = coalesce(public.subscriptions.stripe_customer_id, excluded.stripe_customer_id);
$$;

-- Stripe says the subscription is now in state p_status. The customer id must be the one WE saved for that provider.
-- Returns 'pro' | 'free' | 'unknown_provider' | 'customer_mismatch'
create or replace function public.apply_subscription_state(
  p_provider_id uuid, p_customer_id text, p_subscription_id text, p_status text,
  p_period_start timestamptz, p_period_end timestamptz)
returns text language plpgsql security definer set search_path = '' as $$
declare sub public.subscriptions%rowtype; pro boolean; st public.subscription_status;
begin
  select * into sub from public.subscriptions where provider_id = p_provider_id for update;
  if not found then return 'unknown_provider'; end if;
  if sub.stripe_customer_id is distinct from p_customer_id then return 'customer_mismatch'; end if;

  -- an older subscription of the same customer must not overwrite a newer one
  if sub.stripe_subscription_id is not null and sub.stripe_subscription_id <> p_subscription_id
     and sub.status in ('active', 'trialing', 'past_due') and p_status not in ('active', 'trialing') then
    return case when (select is_pro from public.provider_profiles where id = p_provider_id) then 'pro' else 'free' end;
  end if;

  st := case p_status
          when 'active' then 'active' when 'trialing' then 'trialing' when 'past_due' then 'past_due'
          when 'incomplete' then 'incomplete' else 'cancelled' end;
  -- past_due keeps Pro while Stripe retries the card; unpaid/cancelled/incomplete_expired/etc. drop to free
  pro := st in ('active', 'trialing', 'past_due');

  update public.subscriptions
  set plan_name = case when pro then 'pro' else 'basic' end, status = st,
      stripe_subscription_id = p_subscription_id,
      current_period_start = p_period_start, current_period_end = p_period_end
  where provider_id = p_provider_id;

  update public.provider_profiles
  set is_pro = pro, commission_rate = public.plan_commission(pro)
  where id = p_provider_id;
  return case when pro then 'pro' else 'free' end;
end $$;

-- Provider: my plan
create or replace function public.my_subscription()
returns table (is_pro boolean, status text, current_period_end timestamptz, commission_rate numeric, has_customer boolean)
language sql stable security definer set search_path = '' as $$
  select p.is_pro, coalesce(s.status::text, 'none'), s.current_period_end, p.commission_rate, s.stripe_customer_id is not null
  from public.provider_profiles p left join public.subscriptions s on s.provider_id = p.id
  where p.user_id = (select auth.uid());
$$;

revoke all on function public.plan_commission(boolean)                                   from public, anon, authenticated;
revoke all on function public.subscription_context(uuid)                                 from public, anon, authenticated;
revoke all on function public.save_subscription_customer(uuid, text)                     from public, anon, authenticated;
revoke all on function public.apply_subscription_state(uuid, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.my_subscription()                                          from public, anon, authenticated;
grant execute on function public.subscription_context(uuid)                              to service_role;
grant execute on function public.save_subscription_customer(uuid, text)                  to service_role;
grant execute on function public.apply_subscription_state(uuid, text, text, text, timestamptz, timestamptz) to service_role;
grant execute on function public.plan_commission(boolean)                                to service_role;
grant execute on function public.my_subscription()                                       to authenticated;


-- ########## 011_provider_details.sql ##########
-- =========================================================
-- WASEL MVP — Richer provider sign-up
-- New PUBLIC fields on the provider page: business type, categories, years of experience, languages, website.
-- New PRIVATE fields (owner + admins only): license / insurance info, how they found us, when they accepted the terms.
-- register_provider now REQUIRES: business type, at least one category, a phone number and accepting the terms.
-- Run AFTER 010.
-- =========================================================

alter table public.provider_profiles
  add column if not exists business_type    text check (business_type in ('individual', 'company')),
  add column if not exists categories       text[] check (cardinality(categories) between 1 and 10),
  add column if not exists years_experience smallint check (years_experience between 0 and 60),
  add column if not exists languages        text[] check (cardinality(languages) <= 8),
  add column if not exists website          text check (website ~ '^https?://[^[:space:]]{3,190}$' and length(website) <= 200);

-- private details: NOT readable by the public (provider_profiles is public, so these live in their own table)
create table if not exists public.provider_private (
  provider_id       uuid primary key references public.provider_profiles(id) on delete cascade,
  license_info      text check (length(license_info) <= 300),
  referral_source   text check (referral_source in ('friend', 'social', 'search', 'flyer', 'other')),
  terms_accepted_at timestamptz,
  terms_version     text
);
alter table public.provider_private enable row level security;
revoke all on public.provider_private from public, anon, authenticated;
grant select on public.provider_private to authenticated;
grant update (license_info) on public.provider_private to authenticated;

create policy "Owner reads own private details" on public.provider_private for select to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Admins read private details" on public.provider_private for select to authenticated
using ((select private.is_admin()));
create policy "Owner edits own license info" on public.provider_private for update to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())))
with check (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));

-- providers may edit the new public fields later (never the private audit fields)
grant update (business_type, categories, years_experience, languages, website) on public.provider_profiles to authenticated;

-- replace the old register_provider (it allowed missing phone / terms)
drop function if exists public.register_provider(text, text, text, text, text, text, text, text);

create or replace function public.register_provider(
  p_business_name    text,
  p_business_type    text,
  p_categories       text[],
  p_phone            text,
  p_accept_terms     boolean,
  p_description      text default null,
  p_email            text default null,
  p_address          text default null,
  p_city             text default null,
  p_state            text default 'TX',
  p_zip_code         text default null,
  p_years_experience int  default null,
  p_license_info     text default null,
  p_languages        text[] default null,
  p_website          text default null,
  p_referral_source  text default null
)
returns public.provider_profiles
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  row public.provider_profiles;
  cats text[];
  langs text[];
  digits text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_business_name is null or btrim(p_business_name) = '' then raise exception 'Business name is required'; end if;
  if length(btrim(p_business_name)) > 120 then raise exception 'Business name is too long'; end if;
  if p_accept_terms is distinct from true then raise exception 'You must accept the Terms and Privacy Policy'; end if;
  if p_business_type is null or p_business_type not in ('individual', 'company') then
    raise exception 'Choose whether you are an individual or a company';
  end if;

  select coalesce(array_agg(distinct c order by c), '{}') into cats from unnest(coalesce(p_categories, '{}')) c;
  if cardinality(cats) = 0 then raise exception 'Choose at least one category'; end if;
  if exists (select 1 from unnest(cats) c where c not in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair')) then
    raise exception 'Unknown category';
  end if;

  digits := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  if length(digits) < 10 or length(digits) > 11 or (length(digits) = 11 and left(digits, 1) <> '1') then
    raise exception 'Enter a valid US phone number';
  end if;

  if p_years_experience is not null and (p_years_experience < 0 or p_years_experience > 60) then
    raise exception 'Years of experience must be between 0 and 60';
  end if;
  if p_description is not null and length(p_description) > 1000 then raise exception 'The description is too long (1000 characters max)'; end if;
  if p_website is not null and btrim(p_website) <> '' and btrim(p_website) !~ '^https?://[^[:space:]]{3,190}$' then
    raise exception 'The website must start with http:// or https://';
  end if;
  if p_license_info is not null and length(p_license_info) > 300 then raise exception 'License / insurance info is too long (300 characters max)'; end if;
  if p_referral_source is not null and p_referral_source not in ('friend', 'social', 'search', 'flyer', 'other') then
    raise exception 'Unknown option for how you heard about us';
  end if;

  select array_agg(l order by l) into langs from (
    select distinct left(btrim(x), 30) as l from unnest(coalesce(p_languages, '{}')) x where btrim(x) <> '' limit 8) s;

  insert into public.provider_profiles
    (user_id, business_name, description, phone, email, address, city, state, zip_code,
     business_type, categories, years_experience, languages, website)
  values
    (uid, btrim(p_business_name), nullif(btrim(p_description), ''), btrim(p_phone), nullif(btrim(p_email), ''),
     nullif(btrim(p_address), ''), nullif(btrim(p_city), ''), nullif(upper(btrim(p_state)), ''), nullif(btrim(p_zip_code), ''),
     p_business_type, cats, p_years_experience::smallint, langs, nullif(btrim(p_website), ''))
  returning * into row;

  insert into public.provider_private (provider_id, license_info, referral_source, terms_accepted_at, terms_version)
  values (row.id, nullif(btrim(p_license_info), ''), p_referral_source, now(), '2026-10');

  update public.profiles set role = 'provider' where id = uid and role = 'customer'; -- never downgrade an admin
  return row;
end $$;

revoke all on function public.register_provider(text, text, text[], text, boolean, text, text, text, text, text, text, int, text, text[], text, text) from public, anon, authenticated;
grant execute on function public.register_provider(text, text, text[], text, boolean, text, text, text, text, text, text, int, text, text[], text, text) to authenticated;


-- ########## 012_email_notifications.sql ##########
-- =========================================================
-- WASEL MVP — Email notifications (outbox)
-- New booking -> provider. Confirmed / declined -> customer.
-- Cancelled -> the other side. Refund issued -> customer.
-- The database only WRITES a queue row (email_outbox); the `send-emails` Edge Function
-- sends it. If email is down or not set up yet, bookings still work and the queue waits.
-- Run AFTER 011.
-- =========================================================

create table if not exists public.email_outbox (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done')),
  booking_id      uuid not null references public.bookings(id) on delete cascade,
  to_user         uuid not null references auth.users(id) on delete cascade,
  status          text not null default 'pending' check (status in ('pending','sending','sent','failed','skipped')),
  attempts        int  not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  sent_at         timestamptz,
  last_error      text,
  created_at      timestamptz not null default now()
);
-- one email of each kind per booking per person, no matter how many times a trigger fires
create unique index if not exists email_outbox_once on public.email_outbox (kind, booking_id, to_user);
create index if not exists email_outbox_due on public.email_outbox (next_attempt_at) where status in ('pending','sending');

alter table public.email_outbox enable row level security;           -- no policies: nobody but service_role
revoke all on public.email_outbox from public, anon, authenticated;

create or replace function public.queue_email(p_kind text, p_booking uuid, p_to uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.email_outbox(kind, booking_id, to_user) values (p_kind, p_booking, p_to)
  on conflict do nothing;
$$;
revoke all on function public.queue_email(text, uuid, uuid) from public, anon, authenticated;

-- 1) new booking -> provider
create or replace function public.email_on_booking_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid;
begin
  select user_id into pu from public.provider_profiles where id = new.provider_id;
  if pu is not null then perform public.queue_email('booking_new', new.id, pu); end if;
  return new;
end $$;
revoke all on function public.email_on_booking_insert() from public, anon, authenticated;
drop trigger if exists bookings_email_insert on public.bookings;
create trigger bookings_email_insert after insert on public.bookings
for each row execute function public.email_on_booking_insert();

-- 2) status changes
create or replace function public.email_on_booking_status()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid; actor uuid := (select auth.uid());
begin
  if new.status is not distinct from old.status then return new; end if;
  select user_id into pu from public.provider_profiles where id = new.provider_id;
  if new.status = 'confirmed' then
    perform public.queue_email('booking_confirmed', new.id, new.customer_id);
  elsif new.status = 'declined' then
    perform public.queue_email('booking_declined', new.id, new.customer_id);
  elsif new.status = 'cancelled' then
    if actor is not distinct from new.customer_id then
      if pu is not null then perform public.queue_email('booking_cancelled', new.id, pu); end if;
    elsif actor is not distinct from pu then
      perform public.queue_email('booking_cancelled', new.id, new.customer_id);
    else                                   -- admin / system: tell both
      perform public.queue_email('booking_cancelled', new.id, new.customer_id);
      if pu is not null then perform public.queue_email('booking_cancelled', new.id, pu); end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.email_on_booking_status() from public, anon, authenticated;
drop trigger if exists bookings_email_status on public.bookings;
create trigger bookings_email_status after update of status on public.bookings
for each row execute function public.email_on_booking_status();

-- 3) refund finished (our own refund, or one made by hand in the Stripe dashboard)
create or replace function public.email_on_refund_done()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.refund_status = 'done' and old.refund_status is distinct from 'done' then
    perform public.queue_email('refund_done', new.booking_id, new.customer_id);
  end if;
  return new;
end $$;
revoke all on function public.email_on_refund_done() from public, anon, authenticated;
drop trigger if exists payments_email_refund on public.payments;
create trigger payments_email_refund after update of refund_status on public.payments
for each row execute function public.email_on_refund_done();

-- 4) the sender: take a batch (safe to run twice at once) ...
create or replace function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric
) language plpgsql security definer set search_path = '' as $$
begin
  -- recipients that can't be emailed (no address / switched off) are skipped, not retried forever
  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         (pp.user_id = upd.to_user), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, b.service_price, pay.amount
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  join public.bookings b on b.id = upd.booking_id
  join public.services sv on sv.id = b.service_id
  join public.provider_profiles pp on pp.id = b.provider_id
  join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id;
end $$;

-- ... and report the result
create or replace function public.finish_email(p_id uuid, p_ok boolean, p_error text default null, p_permanent boolean default false)
returns void language sql security definer set search_path = '' as $$
  update public.email_outbox o set
    status          = case when p_ok then 'sent' when p_permanent or o.attempts >= 5 then 'failed' else 'pending' end,
    sent_at         = case when p_ok then now() else o.sent_at end,
    last_error      = case when p_ok then null else left(coalesce(p_error, 'error'), 300) end,
    next_attempt_at = case when p_ok or p_permanent or o.attempts >= 5 then o.next_attempt_at
                           else now() + o.attempts * interval '5 minutes' end,
    locked_at       = null
  where o.id = p_id and o.status = 'sending';
$$;

revoke all on function public.claim_emails(int)                          from public, anon, authenticated;
revoke all on function public.finish_email(uuid, boolean, text, boolean) from public, anon, authenticated;
grant execute on function public.claim_emails(int)                          to service_role;
grant execute on function public.finish_email(uuid, boolean, text, boolean) to service_role;


-- ########## 013_completion_confirmation.sql ##########
-- =========================================================
-- WASEL MVP — Job completion confirmation + public reviews
-- Provider marks the job "completed". The CUSTOMER then confirms it (or reports a problem).
-- The provider's payout waits for that confirmation. If the customer does nothing for
-- 72 hours the job counts as confirmed. A reported problem holds the payout until an admin
-- resolves it. Run AFTER 012.
-- =========================================================

alter table public.bookings
  add column if not exists completed_at   timestamptz,
  add column if not exists confirmed_at   timestamptz,
  add column if not exists problem_status text not null default 'none' check (problem_status in ('none','open','resolved')),
  add column if not exists problem_note   text check (problem_note is null or char_length(problem_note) between 5 and 1000),
  add column if not exists problem_at     timestamptz;

-- jobs that were already completed before this change are treated as confirmed (nobody's payout gets stuck)
update public.bookings set completed_at = coalesce(completed_at, updated_at), confirmed_at = coalesce(confirmed_at, updated_at)
where status = 'completed';

create or replace function public.stamp_completed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then new.completed_at := now(); end if;
  return new;
end $$;
revoke all on function public.stamp_completed() from public, anon, authenticated;
drop trigger if exists bookings_stamp_completed on public.bookings;
create trigger bookings_stamp_completed before update of status on public.bookings
for each row execute function public.stamp_completed();

-- Is the provider's money free to be sent?  completed + no open problem + (confirmed OR 72 h passed)
create or replace function public.payout_released(b public.bookings)
returns boolean language sql stable set search_path = '' as $$
  select b.status = 'completed' and b.problem_status <> 'open'
     and (b.confirmed_at is not null or b.completed_at <= now() - interval '72 hours');
$$;
revoke all on function public.payout_released(public.bookings) from public, anon, authenticated;

-- ---------- customer actions ----------
create or replace function public.confirm_completion(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings; uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.customer_id <> uid then raise exception 'Booking not found'; end if;
  if b.status <> 'completed' then raise exception 'The provider has not marked this job as completed yet'; end if;
  if b.confirmed_at is not null then return 'already'; end if;
  update public.bookings set confirmed_at = now(),
         problem_status = case when problem_status = 'open' then 'resolved' else problem_status end
  where id = b.id;
  return 'ok';
end $$;

create or replace function public.report_problem(p_booking_id uuid, p_note text)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings; uid uuid := (select auth.uid()); n text := btrim(coalesce(p_note, ''));
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.customer_id <> uid then raise exception 'Booking not found'; end if;
  if b.status <> 'completed' then raise exception 'You can only report a problem on a completed job'; end if;
  if b.confirmed_at is not null then raise exception 'You already confirmed this job'; end if;
  if char_length(n) < 5 or char_length(n) > 1000 then raise exception 'Describe the problem in 5 to 1000 characters'; end if;
  if b.problem_status = 'open' then return 'already'; end if;
  update public.bookings set problem_status = 'open', problem_note = n, problem_at = now() where id = b.id;
  return 'ok';
end $$;

-- admin: the problem is sorted out (any refund is made by hand in Stripe) -> the payout is released
create or replace function public.admin_resolve_problem(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  update public.bookings set confirmed_at = coalesce(confirmed_at, now()), problem_status = 'resolved'
  where id = p_booking_id and status = 'completed' and problem_status = 'open';
  if not found then raise exception 'No open problem on this booking'; end if;
  return 'ok';
end $$;

create or replace function public.admin_problems()
returns table (booking_id uuid, service_name text, business_name text, customer_name text, price numeric, note text, reported_at timestamptz, paid boolean, payout_status text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select b.id, sv.name, pp.business_name, coalesce(cp.full_name, ''), b.service_price, b.problem_note, b.problem_at,
           coalesce(pay.status = 'paid', false), coalesce(pay.payout_status, 'none')
    from public.bookings b
    join public.services sv on sv.id = b.service_id
    join public.provider_profiles pp on pp.id = b.provider_id
    join public.profiles cp on cp.id = b.customer_id
    left join public.payments pay on pay.booking_id = b.id
    where b.problem_status = 'open'
    order by b.problem_at;
end $$;

revoke all on function public.confirm_completion(uuid)       from public, anon;
revoke all on function public.report_problem(uuid, text)     from public, anon;
revoke all on function public.admin_resolve_problem(uuid)    from public, anon;
revoke all on function public.admin_problems()               from public, anon;
grant execute on function public.confirm_completion(uuid)    to authenticated;
grant execute on function public.report_problem(uuid, text)  to authenticated;
grant execute on function public.admin_resolve_problem(uuid) to authenticated;
grant execute on function public.admin_problems()            to authenticated;

-- ---------- payout gate (same as 009 plus the confirmation rule) ----------
create or replace function public.claim_payout(p_payment_id uuid, p_caller uuid)
returns table (code text, amount numeric, account_id text, payment_intent text, booking_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  b public.bookings%rowtype;
  owner uuid;
  acct public.provider_payout_accounts%rowtype;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  select * into b from public.bookings where id = pay.booking_id;
  select user_id into owner from public.provider_profiles where id = b.provider_id;
  if p_caller is not null and owner is distinct from p_caller and p_caller is distinct from b.customer_id then
    raise exception 'Payment not found';
  end if;

  booking_id := b.id; payment_intent := pay.stripe_payment_intent_id; amount := pay.provider_amount;
  if pay.payout_status = 'sent'
     or (pay.payout_status = 'processing' and pay.payout_at > now() - interval '10 minutes') then
    code := 'already';
  elsif pay.status <> 'paid' then code := 'not_paid';
  elsif pay.dispute_status in ('open', 'lost') then code := 'disputed';
  elsif b.status <> 'completed' then code := 'not_completed';
  elsif b.problem_status = 'open' then code := 'problem_open';
  elsif not public.payout_released(b) then code := 'awaiting_confirmation';
  else
    select * into acct from public.provider_payout_accounts where provider_id = b.provider_id;
    if not found or not acct.payouts_enabled then
      code := 'no_account';
    elsif pay.provider_amount <= 0 or pay.stripe_payment_intent_id is null then
      code := 'nothing_to_pay';
    else
      update public.payments set payout_status = 'processing', payout_at = now() where id = pay.id;
      code := 'ok'; account_id := acct.stripe_account_id;
    end if;
  end if;
  return next;
end $$;

create or replace function public.payments_awaiting_payout(p_account_id text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select pay.id
  from public.payments pay
  join public.bookings b on b.id = pay.booking_id
  join public.provider_payout_accounts a on a.provider_id = b.provider_id
  where a.stripe_account_id = p_account_id
    and pay.status = 'paid' and pay.payout_status in ('none', 'failed')
    and pay.dispute_status in ('none', 'won')
    and public.payout_released(b);
$$;

-- for the scheduler: everything that is free to be paid out right now (72 h passed, or a retry)
create or replace function public.payments_due_for_release()
returns setof uuid language sql stable security definer set search_path = '' as $$
  select pay.id
  from public.payments pay
  join public.bookings b on b.id = pay.booking_id
  join public.provider_payout_accounts a on a.provider_id = b.provider_id and a.payouts_enabled
  where pay.status = 'paid' and pay.payout_status in ('none', 'failed')
    and pay.dispute_status in ('none', 'won')
    and public.payout_released(b)
  order by b.completed_at
  limit 50;
$$;
revoke all on function public.claim_payout(uuid, uuid)            from public, anon, authenticated;
revoke all on function public.payments_awaiting_payout(text)      from public, anon, authenticated;
revoke all on function public.payments_due_for_release()          from public, anon, authenticated;
grant execute on function public.claim_payout(uuid, uuid)         to service_role;
grant execute on function public.payments_awaiting_payout(text)   to service_role;
grant execute on function public.payments_due_for_release()       to service_role;

-- provider's own list now also says whether the customer confirmed
drop function if exists public.my_booking_payouts();
create or replace function public.my_booking_payouts()
returns table (booking_id uuid, paid boolean, payout_status text, dispute_status text, confirmed boolean, problem_status text, auto_release_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select b.id, (pay.status = 'paid'), pay.payout_status, pay.dispute_status,
         (b.confirmed_at is not null), b.problem_status, b.completed_at + interval '72 hours'
  from public.bookings b
  join public.provider_profiles p on p.id = b.provider_id
  join public.payments pay on pay.booking_id = b.id
  where p.user_id = (select auth.uid());
$$;
revoke all on function public.my_booking_payouts() from public, anon;
grant execute on function public.my_booking_payouts() to authenticated;

-- ---------- emails: completed (ask the customer), confirmed / problem (tell the provider) ----------
alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done','booking_completed','completion_confirmed','problem_reported'));

create or replace function public.email_on_completion()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid;
begin
  select user_id into pu from public.provider_profiles where id = new.provider_id;
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform public.queue_email('booking_completed', new.id, new.customer_id);
  end if;
  if new.confirmed_at is not null and old.confirmed_at is null and pu is not null and old.status = 'completed' then
    perform public.queue_email('completion_confirmed', new.id, pu);
  end if;
  if new.problem_status = 'open' and old.problem_status is distinct from 'open' and pu is not null then
    perform public.queue_email('problem_reported', new.id, pu);
  end if;
  return new;
end $$;
revoke all on function public.email_on_completion() from public, anon, authenticated;
drop trigger if exists bookings_email_completion on public.bookings;
create trigger bookings_email_completion after update of status, confirmed_at, problem_status on public.bookings
for each row execute function public.email_on_completion();

-- ---------- public reviews of a provider (first name + last initial only) ----------
create or replace function public.provider_reviews(p_provider_id uuid, p_limit int default 20)
returns table (rating int, comment text, created_at timestamptz, reviewer text)
language sql stable security definer set search_path = '' as $$
  select r.rating, r.comment, r.created_at,
         coalesce(nullif(initcap(split_part(btrim(p.full_name), ' ', 1)), '') ||
                  case when position(' ' in btrim(p.full_name)) > 0 then ' ' || upper(left(split_part(btrim(p.full_name), ' ', 2), 1)) || '.' else '' end,
                  'Customer')
  from public.reviews r
  join public.profiles p on p.id = r.customer_id
  join public.provider_profiles pp on pp.id = r.provider_id and pp.status = 'approved'
  where r.provider_id = p_provider_id
  order by r.created_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;
revoke all on function public.provider_reviews(uuid, int) from public;
grant execute on function public.provider_reviews(uuid, int) to anon, authenticated;

alter table public.reviews drop constraint if exists reviews_comment_len;
alter table public.reviews add constraint reviews_comment_len check (comment is null or char_length(comment) <= 1000);


-- ########## 014_completion_reminder.sql ##########
-- 014: one reminder email to the customer about 24 hours before a completed job is confirmed automatically.
-- No new scheduler: the reminders are queued by claim_emails(), which the existing every-minute email job already calls.

alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done',
                  'booking_completed','completion_confirmed','problem_reported','completion_reminder'));

-- Queue a reminder for every completed job that is 48 to 72 hours old and still waiting for the customer.
-- The unique index (kind, booking_id, to_user) makes this safe to run any number of times: one reminder per booking.
create or replace function public.queue_completion_reminders()
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  with q as (
    insert into public.email_outbox(kind, booking_id, to_user)
    select 'completion_reminder', b.id, b.customer_id
    from public.bookings b
    where b.status = 'completed'
      and b.confirmed_at is null
      and b.problem_status = 'none'
      and b.completed_at is not null
      and b.completed_at <= now() - interval '48 hours'
      and b.completed_at >  now() - interval '72 hours'
    on conflict do nothing
    returning 1
  )
  select count(*) into n from q;
  return n;
end $$;
revoke all on function public.queue_completion_reminders() from public, anon, authenticated;
grant execute on function public.queue_completion_reminders() to service_role;

-- claim_emails now also (1) queues due reminders, (2) drops reminders that no longer make sense, (3) returns completed_at.
drop function if exists public.claim_emails(int);
create function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric, completed_at timestamptz
) language plpgsql security definer set search_path = '' as $$
begin
  perform public.queue_completion_reminders();

  -- a reminder is pointless once the customer confirmed, reported a problem, or the job is no longer waiting
  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'completion_reminder' and o.status = 'pending'
    and (b.status <> 'completed' or b.confirmed_at is not null or b.problem_status <> 'none');

  -- recipients that can't be emailed (no address / switched off) are skipped, not retried forever
  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         (pp.user_id = upd.to_user), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, b.service_price, pay.amount, b.completed_at
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  join public.bookings b on b.id = upd.booking_id
  join public.services sv on sv.id = b.service_id
  join public.provider_profiles pp on pp.id = b.provider_id
  join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id;
end $$;
revoke all on function public.claim_emails(int) from public, anon, authenticated;
grant execute on function public.claim_emails(int) to service_role;


-- ########## 015_contact_messages.sql ##########
-- 015: "Contact us" messages. Anyone may send one (through a function that checks and rate-limits it);
-- only admins can read them. Nothing here is readable or writable by table access.

create table if not exists public.contact_messages (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete set null,
  name        text not null check (char_length(name) between 1 and 80),
  email       text not null check (char_length(email) between 5 and 200),
  topic       text not null check (topic in ('general','booking','payment','provider','account','privacy','other')),
  message     text not null check (char_length(message) between 10 and 2000),
  status      text not null default 'new' check (status in ('new','handled')),
  created_at  timestamptz not null default now(),
  handled_at  timestamptz
);
create index if not exists contact_messages_status_idx on public.contact_messages (status, created_at desc);
create index if not exists contact_messages_email_idx on public.contact_messages (lower(email), created_at desc);
alter table public.contact_messages enable row level security;           -- no policies: no direct access
revoke all on public.contact_messages from public, anon, authenticated;

create or replace function public.submit_contact(p_name text, p_email text, p_topic text, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_msg text := btrim(coalesce(p_message, ''));
  v_uid uuid := (select auth.uid());
begin
  if char_length(v_name) < 1 or char_length(v_name) > 80 then raise exception 'Please enter your name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 200 then raise exception 'Please enter a valid email address.'; end if;
  if coalesce(p_topic, '') not in ('general','booking','payment','provider','account','privacy','other') then raise exception 'Please choose a topic.'; end if;
  if char_length(v_msg) < 10 then raise exception 'Please write at least 10 characters.'; end if;
  if char_length(v_msg) > 2000 then raise exception 'Please keep your message under 2000 characters.'; end if;
  -- simple brakes against spam: per sender and overall
  if (select count(*) from public.contact_messages where lower(email) = v_email and created_at > now() - interval '1 hour') >= 5
     or (v_uid is not null and (select count(*) from public.contact_messages where user_id = v_uid and created_at > now() - interval '1 hour') >= 5) then
    raise exception 'You have sent several messages already. Please wait a while before sending another.';
  end if;
  if (select count(*) from public.contact_messages where created_at > now() - interval '1 hour') >= 200 then
    raise exception 'We are receiving a lot of messages right now. Please try again later.';
  end if;
  insert into public.contact_messages(user_id, name, email, topic, message) values (v_uid, v_name, v_email, p_topic, v_msg);
end $$;

create or replace function public.admin_contact_messages(p_status text default 'new')
returns table (id uuid, name text, email text, topic text, message text, status text, created_at timestamptz, is_member boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select m.id, m.name, m.email, m.topic, m.message, m.status, m.created_at, (m.user_id is not null)
    from public.contact_messages m
    where p_status = 'all' or m.status = p_status
    order by m.created_at desc
    limit 200;
end $$;

create or replace function public.admin_contact_handled(p_id uuid, p_handled boolean default true)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  update public.contact_messages set status = case when p_handled then 'handled' else 'new' end,
         handled_at = case when p_handled then now() else null end
  where id = p_id;
  if not found then raise exception 'Message not found'; end if;
end $$;

revoke all on function public.submit_contact(text, text, text, text)        from public;
revoke all on function public.admin_contact_messages(text)                  from public, anon;
revoke all on function public.admin_contact_handled(uuid, boolean)          from public, anon;
grant execute on function public.submit_contact(text, text, text, text)     to anon, authenticated;
grant execute on function public.admin_contact_messages(text)               to authenticated;
grant execute on function public.admin_contact_handled(uuid, boolean)       to authenticated;


-- ########## 016_admin_powers.sql ##########
-- 016: more admin powers, each one written to an audit log that nobody can edit.
--   * deactivate / reactivate an account (with teeth: a deactivated account cannot book, review, edit services or change bookings)
--   * hide / show a service
--   * remove a review (provider rating is recalculated)
--   * cancel a booking on behalf of the parties (the customer is refunded in full if they had paid)
--   * audit log for these and for the existing admin actions (provider status, user role, problem release)

-- ---------- audit log: append only ----------
create table if not exists public.admin_audit (
  id           uuid primary key default gen_random_uuid(),
  admin_id     uuid references auth.users(id) on delete set null,
  action       text not null,
  target_type  text not null,
  target_id    uuid,
  reason       text,
  details      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists admin_audit_created_idx on public.admin_audit (created_at desc);
alter table public.admin_audit enable row level security;                    -- no policies: only the functions below touch it
revoke all on public.admin_audit from public, anon, authenticated;

create or replace function private.audit_no_change() returns trigger language plpgsql as $$
begin raise exception 'The audit log cannot be changed'; end $$;
drop trigger if exists admin_audit_no_update on public.admin_audit;
create trigger admin_audit_no_update before update or delete on public.admin_audit
for each row execute function private.audit_no_change();
drop trigger if exists admin_audit_no_truncate on public.admin_audit;
create trigger admin_audit_no_truncate before truncate on public.admin_audit
for each statement execute function private.audit_no_change();

create or replace function private.log_admin(p_action text, p_type text, p_target uuid, p_reason text default null, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.admin_audit(admin_id, action, target_type, target_id, reason, details)
  values ((select auth.uid()), p_action, p_type, p_target, nullif(btrim(coalesce(p_reason, '')), ''), coalesce(p_details, '{}'::jsonb));
$$;
revoke all on function private.log_admin(text, text, uuid, text, jsonb) from public, anon, authenticated;

create or replace function private.need_reason(p_reason text) returns text language plpgsql immutable as $$
declare r text := btrim(coalesce(p_reason, ''));
begin
  if char_length(r) < 5 then raise exception 'Please write a reason (at least 5 characters).'; end if;
  if char_length(r) > 500 then raise exception 'Please keep the reason under 500 characters.'; end if;
  return r;
end $$;
revoke all on function private.need_reason(text) from public, anon, authenticated;

-- ---------- is this account switched on? ----------
create or replace function private.account_active() returns boolean
language sql security definer stable set search_path = '' as $$
  select coalesce((select is_active from public.profiles where id = (select auth.uid())), false);
$$;
revoke all on function private.account_active() from public, anon;
grant execute on function private.account_active() to authenticated;

-- a deactivated account cannot do new things (restrictive policies are ANDed with the existing ones)
drop policy if exists "Active accounts only (book)" on public.bookings;
create policy "Active accounts only (book)" on public.bookings as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (review)" on public.reviews;
create policy "Active accounts only (review)" on public.reviews as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (add service)" on public.services;
create policy "Active accounts only (add service)" on public.services as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (edit service)" on public.services;
create policy "Active accounts only (edit service)" on public.services as restrictive for update to authenticated using ((select private.account_active()));
drop policy if exists "Active accounts only (photos)" on public.service_photos;
create policy "Active accounts only (photos)" on public.service_photos as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (provider profile)" on public.provider_profiles;
create policy "Active accounts only (provider profile)" on public.provider_profiles as restrictive for update to authenticated using ((select private.account_active()));

-- booking changes (confirm, start, complete, cancel) are blocked too
create or replace function public.transition_booking(p_booking_id uuid, p_new_status public.booking_status)
returns public.bookings language plpgsql security definer set search_path = '' as $$
declare
  b           public.bookings;
  uid         uuid := (select auth.uid());
  is_provider boolean;
  is_customer boolean;
  allowed     boolean := false;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not private.account_active() then raise exception 'Your account is deactivated. Please contact us.'; end if;

  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;

  is_customer := (b.customer_id = uid);
  is_provider := exists (select 1 from public.provider_profiles p where p.id = b.provider_id and p.user_id = uid);

  if is_provider then
    allowed := (b.status = 'pending'     and p_new_status in ('confirmed', 'declined'))
            or (b.status = 'confirmed'   and p_new_status in ('in_progress', 'cancelled'))
            or (b.status = 'in_progress' and p_new_status = 'completed');
  elsif is_customer then
    allowed := (b.status in ('pending', 'confirmed') and p_new_status = 'cancelled');
  else
    raise exception 'Not allowed';
  end if;
  if not allowed then raise exception 'Cannot change booking from % to %', b.status, p_new_status; end if;

  update public.bookings set status = p_new_status where id = p_booking_id returning * into b;
  return b;
end $$;

-- ---------- existing admin actions now leave a trace ----------
create or replace function public.admin_set_provider_status(p_provider_id uuid, p_status public.provider_status)
returns public.provider_profiles language plpgsql security definer set search_path = '' as $$
declare row public.provider_profiles; old_status public.provider_status;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  select status into old_status from public.provider_profiles where id = p_provider_id;
  update public.provider_profiles set status = p_status where id = p_provider_id returning * into row;
  if not found then raise exception 'Provider not found'; end if;
  perform private.log_admin('provider_status', 'provider', p_provider_id, null, jsonb_build_object('from', old_status, 'to', p_status, 'business', row.business_name));
  return row;
end $$;

create or replace function public.admin_set_user_role(p_user_id uuid, p_role public.user_role)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare row public.profiles; old_role public.user_role;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own role'; end if;
  select role into old_role from public.profiles where id = p_user_id;
  update public.profiles set role = p_role where id = p_user_id returning * into row;
  if not found then raise exception 'User not found'; end if;
  perform private.log_admin('user_role', 'user', p_user_id, null, jsonb_build_object('from', old_role, 'to', p_role, 'name', row.full_name));
  return row;
end $$;

create or replace function public.admin_resolve_problem(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  update public.bookings set confirmed_at = coalesce(confirmed_at, now()), problem_status = 'resolved'
  where id = p_booking_id and status = 'completed' and problem_status = 'open';
  if not found then raise exception 'No open problem on this booking'; end if;
  perform private.log_admin('problem_released', 'booking', p_booking_id, null, '{}'::jsonb);
  return 'ok';
end $$;

-- ---------- 1) deactivate / reactivate an account ----------
create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; target public.profiles; suspended int := 0;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own account'; end if;
  select * into target from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  if target.role = 'admin' then raise exception 'Change this person''s role first. Admins cannot be deactivated directly.'; end if;
  if target.is_active = p_active then raise exception 'The account is already %', case when p_active then 'active' else 'deactivated' end; end if;

  update public.profiles set is_active = p_active where id = p_user_id;
  if not p_active then
    -- a deactivated provider disappears from search; reactivating does NOT approve them again
    update public.provider_profiles set status = 'suspended' where user_id = p_user_id and status <> 'suspended';
    get diagnostics suspended = row_count;
  end if;
  perform private.log_admin(case when p_active then 'user_reactivated' else 'user_deactivated' end, 'user', p_user_id, r,
                            jsonb_build_object('name', target.full_name, 'role', target.role, 'provider_suspended', suspended > 0));
end $$;

-- ---------- 2) hide / show a service ----------
create or replace function public.admin_set_service_status(p_service_id uuid, p_status public.service_status, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; s public.services;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_status = 'draft' then raise exception 'Use hidden (inactive) or active'; end if;
  select * into s from public.services where id = p_service_id;
  if not found then raise exception 'Service not found'; end if;
  if s.status = p_status then raise exception 'The service is already %', p_status; end if;
  update public.services set status = p_status where id = p_service_id;
  perform private.log_admin(case when p_status = 'active' then 'service_shown' else 'service_hidden' end, 'service', p_service_id, r,
                            jsonb_build_object('name', s.name, 'from', s.status, 'to', p_status));
end $$;

-- ---------- 3) remove a review ----------
create or replace function public.admin_remove_review(p_review_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; rv public.reviews;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into rv from public.reviews where id = p_review_id;
  if not found then raise exception 'Review not found'; end if;
  delete from public.reviews where id = p_review_id;
  update public.provider_profiles p
  set rating       = coalesce((select round(avg(x.rating), 2) from public.reviews x where x.provider_id = rv.provider_id), 0),
      review_count = (select count(*) from public.reviews x where x.provider_id = rv.provider_id)
  where p.id = rv.provider_id;
  perform private.log_admin('review_removed', 'review', p_review_id, r,
                            jsonb_build_object('rating', rv.rating, 'comment', left(coalesce(rv.comment, ''), 300), 'provider_id', rv.provider_id, 'booking_id', rv.booking_id));
end $$;

-- ---------- 4) cancel a booking on behalf of both sides ----------
create or replace function public.admin_cancel_booking(p_booking_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = '' as $$
declare r text; b public.bookings;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status not in ('pending', 'confirmed', 'in_progress') then
    raise exception 'Only a booking that is not finished can be cancelled (it is %). For a finished job use Problems.', b.status;
  end if;
  update public.bookings set status = 'cancelled' where id = p_booking_id;
  perform private.log_admin('booking_cancelled', 'booking', p_booking_id, r, jsonb_build_object('was', b.status, 'price', b.service_price));
  return 'ok';
end $$;

-- the refund step must accept an admin as the person asking (the customer is refunded in full)
create or replace function public.claim_refund(p_payment_id uuid, p_caller uuid)
returns table (code text, amount numeric, payment_intent text, booking_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  b public.bookings%rowtype;
  owner uuid;
  caller_is_admin boolean := false;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  select * into b from public.bookings where id = pay.booking_id;
  select user_id into owner from public.provider_profiles where id = b.provider_id;
  if p_caller is not null then
    caller_is_admin := exists (select 1 from public.profiles where id = p_caller and role = 'admin' and is_active);
  end if;
  if p_caller is not null and not caller_is_admin and p_caller is distinct from b.customer_id and p_caller is distinct from owner then
    raise exception 'Payment not found';
  end if;

  booking_id := b.id; payment_intent := pay.stripe_payment_intent_id; amount := pay.amount;
  if pay.refund_status = 'done' or pay.status = 'refunded'
     or (pay.refund_status = 'processing' and pay.refund_at > now() - interval '10 minutes') then
    code := 'already';
  elsif pay.status <> 'paid' then code := 'not_paid';
  elsif pay.dispute_status in ('open', 'lost') then code := 'disputed';
  elsif b.status not in ('cancelled', 'declined') then code := 'not_cancelled';
  elsif pay.stripe_payment_intent_id is null then code := 'nothing_to_refund';
  else
    update public.payments set refund_status = 'processing', refund_at = now() where id = pay.id;
    code := 'ok';
  end if;
  return next;
end $$;

-- ---------- 5) lists for the admin screens ----------
create or replace function public.admin_audit_log(p_limit int default 100)
returns table (id uuid, created_at timestamptz, admin_name text, action text, target_type text, target_id uuid, reason text, details jsonb)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select a.id, a.created_at, coalesce(p.full_name, 'Admin'), a.action, a.target_type, a.target_id, a.reason, a.details
    from public.admin_audit a left join public.profiles p on p.id = a.admin_id
    order by a.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;

create or replace function public.admin_content(p_limit int default 100)
returns table (kind text, id uuid, title text, subtitle text, body text, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    (select 'service'::text, s.id, s.name, pp.business_name || ' · $' || s.price::text, left(coalesce(s.description, ''), 300), s.status::text, s.created_at
       from public.services s join public.provider_profiles pp on pp.id = s.provider_id
       order by s.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 300)))
    union all
    (select 'review'::text, r.id, repeat('★', r.rating) || repeat('☆', 5 - r.rating), coalesce(cp.full_name, 'Customer') || ' → ' || pp.business_name, coalesce(r.comment, ''), 'visible'::text, r.created_at
       from public.reviews r join public.provider_profiles pp on pp.id = r.provider_id join public.profiles cp on cp.id = r.customer_id
       order by r.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 300)))
    order by 7 desc;
end $$;

-- ---------- grants ----------
revoke all on function public.admin_set_user_active(uuid, boolean, text)                     from public, anon;
revoke all on function public.admin_set_service_status(uuid, public.service_status, text)    from public, anon;
revoke all on function public.admin_remove_review(uuid, text)                                from public, anon;
revoke all on function public.admin_cancel_booking(uuid, text)                               from public, anon;
revoke all on function public.admin_audit_log(int)                                           from public, anon;
revoke all on function public.admin_content(int)                                             from public, anon;
grant execute on function public.admin_set_user_active(uuid, boolean, text)                  to authenticated;
grant execute on function public.admin_set_service_status(uuid, public.service_status, text) to authenticated;
grant execute on function public.admin_remove_review(uuid, text)                             to authenticated;
grant execute on function public.admin_cancel_booking(uuid, text)                            to authenticated;
grant execute on function public.admin_audit_log(int)                                        to authenticated;
grant execute on function public.admin_content(int)                                          to authenticated;


-- ########## 017_fees_approval_prices.sql ##########
-- 017: admin sets the fees and the Pro price, new services need the admin's approval, providers change their own prices.
--   * platform_settings: Free fee %, Pro fee %, Pro monthly price (one row, only changed through the admin functions below)
--   * admin_update_fees: changes the percentages for every provider from now on (old bookings keep the fee they were created with)
--   * admin_save_pro_price: called by the admin-set-pro-price Edge Function after it has created the new Stripe price
--   * services.approval: a new service starts as 'pending'; the admin approves or rejects it; customers only see approved ones
--   * editing a service's name, description or category sends it back to review; price, duration and visibility are free to change
--   * every admin decision is written to the audit log
-- Run AFTER 016.

-- ---------- 1) platform settings ----------
create table if not exists public.platform_settings (
  id                   boolean primary key default true check (id),     -- exactly one row
  free_fee_percent     numeric(5,2) not null default 10.00 check (free_fee_percent between 0 and 50),
  pro_fee_percent      numeric(5,2) not null default 5.00  check (pro_fee_percent  between 0 and 50),
  pro_price_cents      integer      not null default 1900  check (pro_price_cents between 100 and 100000),
  pro_stripe_price_id  text,
  updated_at           timestamptz  not null default now(),
  check (pro_fee_percent <= free_fee_percent)
);
insert into public.platform_settings (id) values (true) on conflict do nothing;
alter table public.platform_settings enable row level security;          -- no policies: read through public_settings(), write through admin functions
revoke all on public.platform_settings from public, anon, authenticated;

-- what everybody may know: the fees and the Pro price (never the Stripe price id)
create or replace function public.public_settings()
returns table (free_fee_percent numeric, pro_fee_percent numeric, pro_price_cents integer)
language sql stable security definer set search_path = '' as $$
  select free_fee_percent, pro_fee_percent, pro_price_cents from public.platform_settings where id;
$$;

-- the plans now read their percentage from the settings
create or replace function public.plan_commission(p_pro boolean)
returns numeric language sql stable security definer set search_path = '' as $$
  select case when p_pro then pro_fee_percent else free_fee_percent end from public.platform_settings where id
$$;

-- admin: change the percentages. Applies to every provider now; bookings that already exist keep their fee.
create or replace function public.admin_update_fees(p_free numeric, p_pro numeric, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare r text; old public.platform_settings; n integer;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_free is null or p_pro is null or p_free < 0 or p_free > 50 or p_pro < 0 or p_pro > 50 then
    raise exception 'Fees must be between 0%% and 50%%.';
  end if;
  if p_pro > p_free then raise exception 'The Pro fee cannot be higher than the Free fee.'; end if;
  select * into old from public.platform_settings where id for update;
  if old.free_fee_percent = round(p_free, 2) and old.pro_fee_percent = round(p_pro, 2) then
    raise exception 'These are already the current fees.';
  end if;
  update public.platform_settings set free_fee_percent = round(p_free, 2), pro_fee_percent = round(p_pro, 2), updated_at = now() where id;
  update public.provider_profiles set commission_rate = public.plan_commission(is_pro)
  where commission_rate is distinct from public.plan_commission(is_pro);
  get diagnostics n = row_count;
  perform private.log_admin('fees_changed', 'settings', null, r,
    jsonb_build_object('free_from', old.free_fee_percent, 'free_to', round(p_free, 2), 'pro_from', old.pro_fee_percent, 'pro_to', round(p_pro, 2), 'providers_updated', n));
  return n;
end $$;

-- Edge Function helpers (service role only)
create or replace function public.check_admin(p_user_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = p_user_id and role = 'admin' and is_active);
$$;

create or replace function public.platform_pro_price() returns text
language sql stable security definer set search_path = '' as $$
  select pro_stripe_price_id from public.platform_settings where id;
$$;

-- the Edge Function created a monthly Stripe price for p_cents; remember it. New subscribers pay it; current subscribers keep their old price.
create or replace function public.admin_save_pro_price(p_admin_id uuid, p_cents integer, p_price_id text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.platform_settings;
begin
  if not public.check_admin(p_admin_id) then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_cents is null or p_cents < 100 or p_cents > 100000 then raise exception 'The monthly price must be between $1 and $1,000.'; end if;
  if coalesce(p_price_id, '') !~ '^price_[A-Za-z0-9]+$' then raise exception 'Invalid Stripe price'; end if;
  select * into old from public.platform_settings where id for update;
  update public.platform_settings set pro_price_cents = p_cents, pro_stripe_price_id = p_price_id, updated_at = now() where id;
  insert into public.admin_audit (admin_id, action, target_type, reason, details)
  values (p_admin_id, 'pro_price_changed', 'settings', r, jsonb_build_object('from_cents', old.pro_price_cents, 'to_cents', p_cents, 'stripe_price', p_price_id));
end $$;

-- ---------- 2) services need approval ----------
alter table public.services
  add column if not exists approval      text not null default 'approved' check (approval in ('pending', 'approved', 'rejected')),
  add column if not exists approval_note text,
  add column if not exists reviewed_at   timestamptz,
  add column if not exists reviewed_by   uuid references auth.users(id) on delete set null;
-- (services that exist today stay approved; the default only applies to rows created by the system itself)
create index if not exists services_approval_idx on public.services (approval) where approval <> 'approved';

-- a provider's change: new services start as pending, approval fields can't be touched, price must be sensible
-- SECURITY INVOKER on purpose: when a signed-in user changes the table directly, current_user is 'authenticated' and the rules below apply;
-- when one of our own SECURITY DEFINER functions (admin review, resubmit, ...) or the service role does it, current_user is someone else and they do not.
create or replace function private.services_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.approval := 'pending'; new.approval_note := null; new.reviewed_at := null; new.reviewed_by := null;
    if new.price < 1 or new.price > 100000 then raise exception 'The price must be between $1 and $100,000.'; end if;
    return new;
  end if;
  -- update by the provider
  new.approval_note := old.approval_note; new.reviewed_at := old.reviewed_at; new.reviewed_by := old.reviewed_by;
  new.approval := old.approval;
  if new.price is distinct from old.price and (new.price < 1 or new.price > 100000) then
    raise exception 'The price must be between $1 and $100,000.';
  end if;
  -- changing what the service IS goes back to review (price, duration and visibility do not)
  if (new.name, new.description, new.category) is distinct from (old.name, old.description, old.category) and old.approval <> 'pending' then
    new.approval := 'pending'; new.approval_note := null; new.reviewed_at := null; new.reviewed_by := null;
  end if;
  return new;
end $$;
revoke all on function private.services_guard() from public, anon, authenticated;
drop trigger if exists services_guard on public.services;
create trigger services_guard before insert or update on public.services for each row execute function private.services_guard();

-- customers only see approved services; nobody can book an unapproved one
drop policy if exists "Active services are publicly visible" on public.services;
create policy "Active services are publicly visible"
on public.services for select to anon, authenticated
using (
  status = 'active' and approval = 'approved'
  and exists (select 1 from public.provider_profiles p where p.id = services.provider_id and p.status = 'approved')
);

drop policy if exists "Photos of active services are publicly visible" on public.service_photos;
create policy "Photos of active services are publicly visible"
on public.service_photos for select to anon, authenticated
using (
  exists (
    select 1 from public.services s join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and s.status = 'active' and s.approval = 'approved' and p.status = 'approved'
  )
);

-- the price the customer was looking at when they pressed "book": if the provider changed it in the meantime, the booking is refused
-- (otherwise the customer could be booked at a price they never saw)
alter table public.bookings add column if not exists quoted_price numeric(10,2) check (quoted_price is null or quoted_price >= 0);
grant insert (quoted_price) on public.bookings to authenticated;

create or replace function public.prepare_booking()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  select sv.price, sv.provider_id, p.commission_rate, p.user_id as provider_user_id
    into s
  from public.services sv
  join public.provider_profiles p on p.id = sv.provider_id
  where sv.id = new.service_id
    and sv.status = 'active'
    and sv.approval = 'approved'
    and p.status  = 'approved';

  if not found then raise exception 'Service is not available for booking'; end if;
  if s.provider_user_id = new.customer_id then raise exception 'You cannot book your own service'; end if;
  if new.scheduled_at <= now() then raise exception 'Booking time must be in the future'; end if;
  if new.quoted_price is not null and new.quoted_price <> s.price then
    raise exception 'The price changed to $%. Please check it and try again.', to_char(s.price, 'FM999999990.00');
  end if;

  new.provider_id         := s.provider_id;
  new.service_price       := s.price;
  new.platform_commission := round(s.price * s.commission_rate / 100, 2);
  new.provider_payout     := s.price - new.platform_commission;
  new.status              := 'pending';
  return new;
end $$;

-- admin: the waiting list
create or replace function public.admin_service_queue()
returns table (id uuid, name text, description text, category text, price numeric, duration_minutes integer,
               business_name text, provider_status text, photo_count bigint, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select s.id, s.name, s.description, s.category::text, s.price, s.duration_minutes, pp.business_name, pp.status::text,
           (select count(*) from public.service_photos ph where ph.service_id = s.id), s.created_at, s.updated_at
    from public.services s join public.provider_profiles pp on pp.id = s.provider_id
    where s.approval = 'pending'
    order by s.updated_at asc;
end $$;

-- admin: approve or reject (a rejection needs a reason, which the provider can read)
create or replace function public.admin_review_service(p_service_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services; r text;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  select * into s from public.services where id = p_service_id for update;
  if not found then raise exception 'Service not found'; end if;
  if s.approval <> 'pending' then raise exception 'This service is not waiting for review.'; end if;
  if p_approve then
    r := nullif(btrim(coalesce(p_note, '')), '');
    if r is not null and char_length(r) > 500 then raise exception 'Please keep the note under 500 characters.'; end if;
  else
    r := private.need_reason(p_note);
  end if;
  update public.services
  set approval = case when p_approve then 'approved' else 'rejected' end,
      approval_note = r, reviewed_at = now(), reviewed_by = (select auth.uid())
  where id = p_service_id;
  perform private.log_admin(case when p_approve then 'service_approved' else 'service_rejected' end, 'service', p_service_id, r,
    jsonb_build_object('name', s.name, 'price', s.price, 'provider_id', s.provider_id));
end $$;

-- provider: send a rejected service back for review after fixing it
create or replace function public.resubmit_service(p_service_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services;
begin
  if not private.account_active() then raise exception 'You cannot do this right now. If your account was deactivated, please contact us.'; end if;
  select sv.* into s from public.services sv join public.provider_profiles p on p.id = sv.provider_id
  where sv.id = p_service_id and p.user_id = (select auth.uid()) for update of sv;
  if not found then raise exception 'Service not found'; end if;
  if s.approval <> 'rejected' then raise exception 'Only a rejected service can be sent for review again.'; end if;
  update public.services set approval = 'pending', approval_note = null, reviewed_at = null, reviewed_by = null where id = p_service_id;
end $$;

-- the Content tab also shows the approval state
drop function if exists public.admin_content(int);
create or replace function public.admin_content(p_limit int default 100)
returns table (kind text, id uuid, title text, subtitle text, body text, status text, created_at timestamptz, approval text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    (select 'service'::text, s.id, s.name, pp.business_name || ' · $' || s.price::text, left(coalesce(s.description, ''), 300), s.status::text, s.created_at, s.approval
       from public.services s join public.provider_profiles pp on pp.id = s.provider_id
       order by s.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 300)))
    union all
    (select 'review'::text, r.id, repeat('★', r.rating) || repeat('☆', 5 - r.rating), coalesce(cp.full_name, 'Customer') || ' → ' || pp.business_name, coalesce(r.comment, ''), 'visible'::text, r.created_at, null::text
       from public.reviews r join public.provider_profiles pp on pp.id = r.provider_id join public.profiles cp on cp.id = r.customer_id
       order by r.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 300)))
    order by 7 desc;
end $$;

-- ---------- grants ----------
revoke all on function public.public_settings()                                     from public, anon, authenticated;
revoke all on function public.admin_update_fees(numeric, numeric, text)             from public, anon, authenticated;
revoke all on function public.check_admin(uuid)                                     from public, anon, authenticated;
revoke all on function public.platform_pro_price()                                  from public, anon, authenticated;
revoke all on function public.admin_save_pro_price(uuid, integer, text, text)       from public, anon, authenticated;
revoke all on function public.admin_service_queue()                                 from public, anon, authenticated;
revoke all on function public.admin_review_service(uuid, boolean, text)             from public, anon, authenticated;
revoke all on function public.resubmit_service(uuid)                                from public, anon, authenticated;
revoke all on function public.admin_content(int)                                    from public, anon, authenticated;
revoke all on function public.plan_commission(boolean)                              from public, anon, authenticated;
revoke all on function public.prepare_booking()                                     from public, anon, authenticated;
grant execute on function public.public_settings()                                  to anon, authenticated, service_role;
grant execute on function public.admin_update_fees(numeric, numeric, text)          to authenticated;
grant execute on function public.check_admin(uuid)                                  to service_role;
grant execute on function public.platform_pro_price()                               to service_role;
grant execute on function public.admin_save_pro_price(uuid, integer, text, text)    to service_role;
grant execute on function public.admin_service_queue()                              to authenticated;
grant execute on function public.admin_review_service(uuid, boolean, text)          to authenticated;
grant execute on function public.resubmit_service(uuid)                             to authenticated;
grant execute on function public.admin_content(int)                                 to authenticated;
grant execute on function public.plan_commission(boolean)                           to service_role;


-- ########## 018_admin_provider_emails.sql ##########
-- 018: more emails.
--   * a new or renamed service waiting for approval        -> every active admin
--   * a new contact message                                 -> every active admin
--   * the admin approved / rejected a service               -> the provider (a rejection includes the reason)
-- Same outbox as the booking emails: the database only writes a queue row, `send-emails` delivers it.
-- Run AFTER 017.

alter table public.email_outbox alter column booking_id drop not null;
alter table public.email_outbox
  add column if not exists service_id uuid references public.services(id) on delete cascade,
  add column if not exists contact_id uuid references public.contact_messages(id) on delete cascade,
  add column if not exists dedupe     text;
alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done',
                  'booking_completed','completion_confirmed','problem_reported','completion_reminder',
                  'service_pending','service_approved','service_rejected','contact_new'));
-- booking emails need a booking; the others need what they are about
alter table public.email_outbox drop constraint if exists email_outbox_subject_check;
alter table public.email_outbox add constraint email_outbox_subject_check
  check ((kind like 'service\_%' and service_id is not null) or (kind = 'contact_new' and contact_id is not null)
         or (kind not like 'service\_%' and kind <> 'contact_new' and booking_id is not null));
-- one email per submission per person (a service sent for review twice is two submissions)
create unique index if not exists email_outbox_once_dedupe on public.email_outbox (kind, dedupe, to_user) where dedupe is not null;

-- ---------- queue: services ----------
create or replace function public.email_on_service_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid; key text := new.id::text || ':' || extract(epoch from clock_timestamp())::text;
begin
  if new.approval = 'pending' and (tg_op = 'INSERT' or old.approval is distinct from 'pending') then
    insert into public.email_outbox(kind, service_id, to_user, dedupe)
    select 'service_pending', new.id, p.id, key from public.profiles p where p.role = 'admin' and p.is_active
    on conflict do nothing;
  elsif tg_op = 'UPDATE' and old.approval = 'pending' and new.approval in ('approved', 'rejected') then
    select user_id into pu from public.provider_profiles where id = new.provider_id;
    if pu is not null then
      insert into public.email_outbox(kind, service_id, to_user, dedupe)
      values (case when new.approval = 'approved' then 'service_approved' else 'service_rejected' end, new.id, pu, key)
      on conflict do nothing;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.email_on_service_review() from public, anon, authenticated;
drop trigger if exists services_email_review on public.services;
create trigger services_email_review after insert or update of approval on public.services
for each row execute function public.email_on_service_review();

-- ---------- queue: contact messages ----------
create or replace function public.email_on_contact()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.email_outbox(kind, contact_id, to_user, dedupe)
  select 'contact_new', new.id, p.id, new.id::text from public.profiles p where p.role = 'admin' and p.is_active
  on conflict do nothing;
  return new;
end $$;
revoke all on function public.email_on_contact() from public, anon, authenticated;
drop trigger if exists contact_email_new on public.contact_messages;
create trigger contact_email_new after insert on public.contact_messages
for each row execute function public.email_on_contact();

-- ---------- claim_emails: booking rows and the new kinds ----------
drop function if exists public.claim_emails(int);
create function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric, completed_at timestamptz,
  to_is_admin boolean, approval_note text, contact_name text, contact_email text, contact_topic text, contact_message text
) language plpgsql security definer set search_path = '' as $$
begin
  perform public.queue_completion_reminders();

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'completion_reminder' and o.status = 'pending'
    and (b.status <> 'completed' or b.confirmed_at is not null or b.problem_status <> 'none');

  -- a service email is pointless if the service is no longer in the state it describes
  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.services s
  where o.service_id = s.id and o.status = 'pending'
    and ((o.kind = 'service_pending' and s.approval <> 'pending')
      or (o.kind = 'service_approved' and s.approval <> 'approved')
      or (o.kind = 'service_rejected' and s.approval <> 'rejected'));

  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         coalesce(pp.user_id = upd.to_user, false), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, coalesce(b.service_price, sv.price), pay.amount, b.completed_at,
         (tp.role = 'admin'), sv.approval_note, cm.name, cm.email, cm.topic, cm.message
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  left join public.bookings b on b.id = upd.booking_id
  left join public.services sv on sv.id = coalesce(b.service_id, upd.service_id)
  left join public.provider_profiles pp on pp.id = coalesce(b.provider_id, sv.provider_id)
  left join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id
  left join public.contact_messages cm on cm.id = upd.contact_id;
end $$;
revoke all on function public.claim_emails(int) from public, anon, authenticated;
grant execute on function public.claim_emails(int) to service_role;


-- ########## 019_email_language.sql ##########
-- 019: emails in the language of the person who gets them (English or Spanish).
-- profiles.lang is set at sign-up (from the language the site was in) and changed only through set_my_language().

alter table public.profiles add column if not exists lang text not null default 'en';
alter table public.profiles drop constraint if exists profiles_lang_check;
alter table public.profiles add constraint profiles_lang_check check (lang in ('en','es'));

-- Only the person themselves can change their language, and only to a supported one.
-- (profiles has column-level grants: lang is deliberately not in them, so this function is the only way.)
create or replace function public.set_my_language(p_lang text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_lang is null or p_lang not in ('en','es') then raise exception 'Unsupported language'; end if;
  update public.profiles set lang = p_lang where id = auth.uid() and lang is distinct from p_lang;
end $$;
revoke all on function public.set_my_language(text) from public, anon;
grant execute on function public.set_my_language(text) to authenticated;

-- New accounts start in the language the visitor was using (anything unknown becomes English).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name, role, lang)
  values (new.id, new.raw_user_meta_data ->> 'full_name', 'customer',
          case when new.raw_user_meta_data ->> 'lang' = 'es' then 'es' else 'en' end);
  return new;
end $$;

-- ---------- claim_emails: same as before, plus the language of the person who gets the email ----------
drop function if exists public.claim_emails(int);
create function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric, completed_at timestamptz,
  to_is_admin boolean, approval_note text, contact_name text, contact_email text, contact_topic text, contact_message text,
  to_lang text
) language plpgsql security definer set search_path = '' as $$
begin
  perform public.queue_completion_reminders();

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'completion_reminder' and o.status = 'pending'
    and (b.status <> 'completed' or b.confirmed_at is not null or b.problem_status <> 'none');

  -- a service email is pointless if the service is no longer in the state it describes
  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.services s
  where o.service_id = s.id and o.status = 'pending'
    and ((o.kind = 'service_pending' and s.approval <> 'pending')
      or (o.kind = 'service_approved' and s.approval <> 'approved')
      or (o.kind = 'service_rejected' and s.approval <> 'rejected'));

  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         coalesce(pp.user_id = upd.to_user, false), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, coalesce(b.service_price, sv.price), pay.amount, b.completed_at,
         (tp.role = 'admin'), sv.approval_note, cm.name, cm.email, cm.topic, cm.message, tp.lang
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  left join public.bookings b on b.id = upd.booking_id
  left join public.services sv on sv.id = coalesce(b.service_id, upd.service_id)
  left join public.provider_profiles pp on pp.id = coalesce(b.provider_id, sv.provider_id)
  left join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id
  left join public.contact_messages cm on cm.id = upd.contact_id;
end $$;
revoke all on function public.claim_emails(int) from public, anon, authenticated;
grant execute on function public.claim_emails(int) to service_role;


-- ########## 020_documents_and_info_requests.sql ##########
-- =========================================================
-- WASEL MVP — Documents and "more information" requests
--
--   * A provider applying to join uploads documents: an ID, and a license OR proof of insurance.
--   * A provider adding a service uploads at least one supporting document for it.
--   * An admin reviewing an application (or a service) can APPROVE, REJECT (with a reason) or
--     ask for MORE INFORMATION / DOCUMENTS (with a message). The provider answers and sends it back.
--   * An application cannot be approved without its documents, and a service cannot be approved without one.
--   * Emails: the admins hear about each new / re-sent application; the provider hears about every decision.
--
-- Documents live in a PRIVATE bucket ("provider-docs"): only the owner and the admins can read them.
-- Upload path convention (the first folder MUST be the uploader's user id):  <auth user id>/<kind>/<random>-<file name>
-- Run AFTER 019.
-- =========================================================

-- ---------- 1) the state of a provider's application (kept private: the provider page is public) ----------
create table if not exists public.provider_applications (
  provider_id  uuid primary key references public.provider_profiles(id) on delete cascade,
  state        text not null default 'submitted' check (state in ('submitted', 'needs_info', 'rejected', 'approved')),
  note         text check (note is null or char_length(note) <= 500),   -- the admin's message to the provider
  submitted_at timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid references auth.users(id) on delete set null
);
alter table public.provider_applications enable row level security;
revoke all on public.provider_applications from public, anon, authenticated;
grant select on public.provider_applications to authenticated;     -- writes only through the functions below
create policy "Owner reads own application" on public.provider_applications for select to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Admins read applications" on public.provider_applications for select to authenticated
using ((select private.is_admin()));

-- providers that exist today keep the state they have; new ones start as "submitted"
insert into public.provider_applications (provider_id, state)
select p.id, case when p.status = 'pending' then 'submitted' else 'approved' end from public.provider_profiles p
on conflict do nothing;

create or replace function private.application_for_new_provider() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.provider_applications (provider_id, state)
  values (new.id, case when new.status = 'approved' then 'approved' else 'submitted' end)
  on conflict do nothing;
  return new;
end $$;
revoke all on function private.application_for_new_provider() from public, anon, authenticated;
drop trigger if exists provider_profiles_application on public.provider_profiles;
create trigger provider_profiles_application after insert on public.provider_profiles
for each row execute function private.application_for_new_provider();

-- ---------- 2) documents ----------
create table if not exists public.provider_documents (
  id           uuid primary key default gen_random_uuid(),
  provider_id  uuid not null references public.provider_profiles(id) on delete cascade,
  service_id   uuid references public.services(id) on delete cascade,
  kind         text not null check (kind in ('id', 'license', 'insurance', 'other', 'service')),
  storage_path text not null unique check (char_length(storage_path) between 10 and 300),
  file_name    text not null check (char_length(file_name) between 1 and 150),
  size_bytes   integer check (size_bytes is null or size_bytes between 1 and 10485760),
  created_at   timestamptz not null default now(),
  check ((kind = 'service') = (service_id is not null))
);
create index if not exists provider_documents_provider_idx on public.provider_documents (provider_id);
create index if not exists provider_documents_service_idx on public.provider_documents (service_id) where service_id is not null;
alter table public.provider_documents enable row level security;
revoke all on public.provider_documents from public, anon, authenticated;
grant select, delete on public.provider_documents to authenticated;
grant insert (provider_id, service_id, kind, storage_path, file_name, size_bytes) on public.provider_documents to authenticated;

create policy "Owner reads own documents" on public.provider_documents for select to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Admins read documents" on public.provider_documents for select to authenticated
using ((select private.is_admin()));

-- the file must sit in the uploader's own folder, and a service document must belong to the uploader's own service
create policy "Owner adds documents" on public.provider_documents for insert to authenticated
with check (
  exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid()))
  and storage_path like (select auth.uid())::text || '/%'
  and (service_id is null or exists (select 1 from public.services s where s.id = service_id and s.provider_id = provider_documents.provider_id))
);
create policy "Active accounts only (documents)" on public.provider_documents as restrictive for insert to authenticated
with check ((select private.account_active()));

-- ID / license / insurance can't be removed after approval (the admin relied on them); service documents and "other" can
create policy "Owner removes documents" on public.provider_documents for delete to authenticated
using (
  exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid()))
  and (kind in ('service', 'other') or exists (select 1 from public.provider_applications a where a.provider_id = provider_documents.provider_id and a.state <> 'approved'))
);

create or replace function private.limit_documents() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.service_id is null then
    if (select count(*) from public.provider_documents where provider_id = new.provider_id and service_id is null) >= 8 then
      raise exception 'You can upload up to 8 documents for your business.';
    end if;
  elsif (select count(*) from public.provider_documents where service_id = new.service_id) >= 5 then
    raise exception 'You can upload up to 5 documents for one service.';
  end if;
  return new;
end $$;
revoke all on function private.limit_documents() from public, anon, authenticated;
drop trigger if exists provider_documents_limit on public.provider_documents;
create trigger provider_documents_limit before insert on public.provider_documents
for each row execute function private.limit_documents();

-- what must an application contain before it can be approved?  an ID + (a license or proof of insurance)
create or replace function private.missing_provider_docs(p_provider uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select array_remove(array[
    case when not exists (select 1 from public.provider_documents d where d.provider_id = p_provider and d.kind = 'id') then 'an ID' end,
    case when not exists (select 1 from public.provider_documents d where d.provider_id = p_provider and d.kind in ('license', 'insurance')) then 'a license or proof of insurance' end
  ], null);
$$;
revoke all on function private.missing_provider_docs(uuid) from public, anon, authenticated;

-- private storage bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('provider-docs', 'provider-docs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "Owner uploads own documents" on storage.objects for insert to authenticated
with check (bucket_id = 'provider-docs' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Owner and admins read documents" on storage.objects for select to authenticated
using (bucket_id = 'provider-docs' and ((storage.foldername(name))[1] = (select auth.uid())::text or (select private.is_admin())));
create policy "Owner deletes own documents" on storage.objects for delete to authenticated
using (bucket_id = 'provider-docs' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------- 3) the admin decides on a provider application ----------
create or replace function public.admin_review_provider(p_provider_id uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare pr public.provider_profiles; app public.provider_applications; r text; missing text[];
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  if p_action not in ('approve', 'reject', 'request_info') then raise exception 'Unknown action'; end if;
  select * into pr from public.provider_profiles where id = p_provider_id for update;
  if not found then raise exception 'Provider not found'; end if;
  select * into app from public.provider_applications where provider_id = p_provider_id for update;
  if pr.status <> 'pending' or app.state = 'approved' then raise exception 'This application was already approved.'; end if;

  if p_action = 'approve' then
    missing := private.missing_provider_docs(p_provider_id);
    if cardinality(missing) > 0 then raise exception 'Cannot approve yet: the application is missing %.', array_to_string(missing, ' and '); end if;
    r := nullif(btrim(coalesce(p_note, '')), '');
    if r is not null and char_length(r) > 500 then raise exception 'Please keep the note under 500 characters.'; end if;
    update public.provider_profiles set status = 'approved' where id = p_provider_id;
    update public.provider_applications set state = 'approved', note = r, reviewed_at = now(), reviewed_by = (select auth.uid()) where provider_id = p_provider_id;
  else
    r := private.need_reason(p_note);
    update public.provider_applications
    set state = case when p_action = 'reject' then 'rejected' else 'needs_info' end, note = r, reviewed_at = now(), reviewed_by = (select auth.uid())
    where provider_id = p_provider_id;
  end if;
  perform private.log_admin(case p_action when 'approve' then 'provider_approved' when 'reject' then 'provider_rejected' else 'provider_info_requested' end,
    'provider', p_provider_id, r, jsonb_build_object('business', pr.business_name));
end $$;
revoke all on function public.admin_review_provider(uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_review_provider(uuid, text, text) to authenticated;

-- the provider answers a "more information" request and sends the application back
create or replace function public.resubmit_application()
returns void language plpgsql security definer set search_path = '' as $$
declare pid uuid;
begin
  if not private.account_active() then raise exception 'You cannot do this right now. If your account was deactivated, please contact us.'; end if;
  select id into pid from public.provider_profiles where user_id = (select auth.uid());
  if pid is null then raise exception 'Provider profile not found'; end if;
  update public.provider_applications set state = 'submitted', note = null, submitted_at = now(), reviewed_at = null, reviewed_by = null
  where provider_id = pid and state = 'needs_info';
  if not found then raise exception 'There is nothing to send again.'; end if;
end $$;
revoke all on function public.resubmit_application() from public, anon, authenticated;
grant execute on function public.resubmit_application() to authenticated;

-- approving a waiting provider goes through admin_review_provider (it checks the documents);
-- this older function still suspends and reinstates
create or replace function public.admin_set_provider_status(p_provider_id uuid, p_status public.provider_status)
returns public.provider_profiles language plpgsql security definer set search_path = '' as $$
declare row public.provider_profiles; old_status public.provider_status;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  select status into old_status from public.provider_profiles where id = p_provider_id;
  if old_status = 'pending' and p_status = 'approved' then raise exception 'Review the application to approve it (documents are checked there).'; end if;
  update public.provider_profiles set status = p_status where id = p_provider_id returning * into row;
  if not found then raise exception 'Provider not found'; end if;
  perform private.log_admin('provider_status', 'provider', p_provider_id, null, jsonb_build_object('from', old_status, 'to', p_status, 'business', row.business_name));
  return row;
end $$;

-- ---------- 4) services: "more information" state, documents required ----------
alter table public.services drop constraint if exists services_approval_check;
alter table public.services add constraint services_approval_check check (approval in ('pending', 'approved', 'rejected', 'needs_info'));

drop function if exists public.admin_service_queue();
create or replace function public.admin_service_queue()
returns table (id uuid, name text, description text, category text, price numeric, duration_minutes integer,
               business_name text, provider_status text, photo_count bigint, created_at timestamptz, updated_at timestamptz, doc_count bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select s.id, s.name, s.description, s.category::text, s.price, s.duration_minutes, pp.business_name, pp.status::text,
           (select count(*) from public.service_photos ph where ph.service_id = s.id), s.created_at, s.updated_at,
           (select count(*) from public.provider_documents d where d.service_id = s.id)
    from public.services s join public.provider_profiles pp on pp.id = s.provider_id
    where s.approval = 'pending'
    order by s.updated_at asc;
end $$;
revoke all on function public.admin_service_queue() from public, anon, authenticated;
grant execute on function public.admin_service_queue() to authenticated;

-- approving needs at least one supporting document
create or replace function public.admin_review_service(p_service_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services; r text;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  select * into s from public.services where id = p_service_id for update;
  if not found then raise exception 'Service not found'; end if;
  if s.approval <> 'pending' then raise exception 'This service is not waiting for review.'; end if;
  if p_approve then
    if not exists (select 1 from public.provider_documents d where d.service_id = p_service_id) then
      raise exception 'Cannot approve yet: the provider has not uploaded a supporting document for this service.';
    end if;
    r := nullif(btrim(coalesce(p_note, '')), '');
    if r is not null and char_length(r) > 500 then raise exception 'Please keep the note under 500 characters.'; end if;
  else
    r := private.need_reason(p_note);
  end if;
  update public.services
  set approval = case when p_approve then 'approved' else 'rejected' end,
      approval_note = r, reviewed_at = now(), reviewed_by = (select auth.uid())
  where id = p_service_id;
  perform private.log_admin(case when p_approve then 'service_approved' else 'service_rejected' end, 'service', p_service_id, r,
    jsonb_build_object('name', s.name, 'price', s.price, 'provider_id', s.provider_id));
end $$;

create or replace function public.admin_request_service_info(p_service_id uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services; r text;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  select * into s from public.services where id = p_service_id for update;
  if not found then raise exception 'Service not found'; end if;
  if s.approval <> 'pending' then raise exception 'This service is not waiting for review.'; end if;
  r := private.need_reason(p_note);
  update public.services set approval = 'needs_info', approval_note = r, reviewed_at = now(), reviewed_by = (select auth.uid()) where id = p_service_id;
  perform private.log_admin('service_info_requested', 'service', p_service_id, r, jsonb_build_object('name', s.name, 'provider_id', s.provider_id));
end $$;
revoke all on function public.admin_request_service_info(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_request_service_info(uuid, text) to authenticated;

-- the provider sends a rejected service, or one the admin asked about, back for review
create or replace function public.resubmit_service(p_service_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services;
begin
  if not private.account_active() then raise exception 'You cannot do this right now. If your account was deactivated, please contact us.'; end if;
  select sv.* into s from public.services sv join public.provider_profiles p on p.id = sv.provider_id
  where sv.id = p_service_id and p.user_id = (select auth.uid()) for update of sv;
  if not found then raise exception 'Service not found'; end if;
  if s.approval not in ('rejected', 'needs_info') then raise exception 'Only a rejected service, or one the admin asked about, can be sent for review again.'; end if;
  update public.services set approval = 'pending', approval_note = null, reviewed_at = null, reviewed_by = null where id = p_service_id;
end $$;

-- ---------- 5) emails ----------
alter table public.email_outbox add column if not exists provider_id uuid references public.provider_profiles(id) on delete cascade;
alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done',
                  'booking_completed','completion_confirmed','problem_reported','completion_reminder',
                  'service_pending','service_approved','service_rejected','service_needs_info','contact_new',
                  'provider_new','provider_approved','provider_rejected','provider_needs_info'));
alter table public.email_outbox drop constraint if exists email_outbox_subject_check;
alter table public.email_outbox add constraint email_outbox_subject_check
  check ((kind like 'service\_%' and service_id is not null)
         or (kind = 'contact_new' and contact_id is not null)
         or (kind like 'provider\_%' and provider_id is not null)
         or (kind not like 'service\_%' and kind <> 'contact_new' and kind not like 'provider\_%' and booking_id is not null));

-- services: also tell the provider when the admin asks for more
create or replace function public.email_on_service_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid; key text := new.id::text || ':' || extract(epoch from clock_timestamp())::text;
begin
  if new.approval = 'pending' and (tg_op = 'INSERT' or old.approval is distinct from 'pending') then
    insert into public.email_outbox(kind, service_id, to_user, dedupe)
    select 'service_pending', new.id, p.id, key from public.profiles p where p.role = 'admin' and p.is_active
    on conflict do nothing;
  elsif tg_op = 'UPDATE' and old.approval = 'pending' and new.approval in ('approved', 'rejected', 'needs_info') then
    select user_id into pu from public.provider_profiles where id = new.provider_id;
    if pu is not null then
      insert into public.email_outbox(kind, service_id, to_user, dedupe)
      values (case new.approval when 'approved' then 'service_approved' when 'rejected' then 'service_rejected' else 'service_needs_info' end, new.id, pu, key)
      on conflict do nothing;
    end if;
  end if;
  return new;
end $$;

-- provider applications: admins hear about a new / re-sent one, the provider hears about the decision
create or replace function public.email_on_application()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid; key text := new.provider_id::text || ':' || extract(epoch from clock_timestamp())::text;
begin
  if new.state = 'submitted' and (tg_op = 'INSERT' or old.state is distinct from 'submitted') then
    insert into public.email_outbox(kind, provider_id, to_user, dedupe)
    select 'provider_new', new.provider_id, p.id, key from public.profiles p where p.role = 'admin' and p.is_active
    on conflict do nothing;
  elsif tg_op = 'UPDATE' and old.state is distinct from new.state and new.state in ('approved', 'rejected', 'needs_info') then
    select user_id into pu from public.provider_profiles where id = new.provider_id;
    if pu is not null then
      insert into public.email_outbox(kind, provider_id, to_user, dedupe)
      values (case new.state when 'approved' then 'provider_approved' when 'rejected' then 'provider_rejected' else 'provider_needs_info' end, new.provider_id, pu, key)
      on conflict do nothing;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.email_on_application() from public, anon, authenticated;
drop trigger if exists applications_email on public.provider_applications;
create trigger applications_email after insert or update of state on public.provider_applications
for each row execute function public.email_on_application();

-- claim_emails: same as 019, also understands the new kinds (the note comes from the service or from the application)
drop function if exists public.claim_emails(int);
create function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric, completed_at timestamptz,
  to_is_admin boolean, approval_note text, contact_name text, contact_email text, contact_topic text, contact_message text,
  to_lang text
) language plpgsql security definer set search_path = '' as $$
begin
  perform public.queue_completion_reminders();

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'completion_reminder' and o.status = 'pending'
    and (b.status <> 'completed' or b.confirmed_at is not null or b.problem_status <> 'none');

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.services s
  where o.service_id = s.id and o.status = 'pending'
    and ((o.kind = 'service_pending' and s.approval <> 'pending')
      or (o.kind = 'service_approved' and s.approval <> 'approved')
      or (o.kind = 'service_rejected' and s.approval <> 'rejected')
      or (o.kind = 'service_needs_info' and s.approval <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.provider_applications a
  where o.provider_id = a.provider_id and o.status = 'pending'
    and ((o.kind = 'provider_new' and a.state <> 'submitted')
      or (o.kind = 'provider_approved' and a.state <> 'approved')
      or (o.kind = 'provider_rejected' and a.state <> 'rejected')
      or (o.kind = 'provider_needs_info' and a.state <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         coalesce(pp.user_id = upd.to_user, false), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, coalesce(b.service_price, sv.price), pay.amount, b.completed_at,
         (tp.role = 'admin'), coalesce(sv.approval_note, app.note), cm.name, cm.email, cm.topic, cm.message, tp.lang
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  left join public.bookings b on b.id = upd.booking_id
  left join public.services sv on sv.id = coalesce(b.service_id, upd.service_id)
  left join public.provider_profiles pp on pp.id = coalesce(b.provider_id, sv.provider_id, upd.provider_id)
  left join public.provider_applications app on app.provider_id = upd.provider_id
  left join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id
  left join public.contact_messages cm on cm.id = upd.contact_id;
end $$;
revoke all on function public.claim_emails(int) from public, anon, authenticated;
grant execute on function public.claim_emails(int) to service_role;

-- admins can also see the application state and documents count in one call
create or replace function public.admin_provider_extras()
returns table (provider_id uuid, state text, note text, submitted_at timestamptz, id_docs bigint, license_docs bigint, insurance_docs bigint, other_docs bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select a.provider_id, a.state, a.note, a.submitted_at,
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'id'),
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'license'),
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'insurance'),
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'other')
    from public.provider_applications a;
end $$;
revoke all on function public.admin_provider_extras() from public, anon, authenticated;
grant execute on function public.admin_provider_extras() to authenticated;


-- ########## 021_distance.sql ##########
-- =========================================================
-- WASEL MVP — Distance in miles (approximate, from ZIP codes)
--
--   * zip_centroids: the center point of every Texas ZIP code (free public data, ~2.6k rows; no address is ever sent anywhere).
--   * provider_distances(place): miles from a customer search place (a ZIP, or a city = the average of its ZIP centers)
--     to each approved provider's own ZIP. Public: it returns only miles, never a ZIP or an address.
--   * my_booking_distances(): for the signed-in provider, miles from their ZIP to the ZIP on each of their bookings.
-- Distances are straight-line and approximate (ZIP center to ZIP center). Run AFTER 020.
-- =========================================================

create table if not exists public.zip_centroids (
  zip  text primary key check (zip ~ '^[0-9]{5}$'),
  city text not null,
  lat  double precision not null check (lat between 25 and 37),
  lng  double precision not null check (lng between -107 and -93)
);
create index if not exists zip_centroids_city_idx on public.zip_centroids (lower(city));
alter table public.zip_centroids enable row level security;
revoke all on public.zip_centroids from public, anon, authenticated;   -- read only through the functions below

insert into public.zip_centroids (zip, city, lat, lng) values
('73301','Austin',30.3264,-97.7713),
('73344','Austin',30.3264,-97.7713),
('73960','Texhoma',36.5055,-101.7829),
('75001','Addison',32.96,-96.8385),
('75002','Allen',33.0934,-96.6454),
('75006','Carrollton',32.9657,-96.8825),
('75007','Carrollton',33.0033,-96.882),
('75009','Celina',33.3103,-96.7673),
('75010','Carrollton',33.0304,-96.8777),
('75011','Carrollton',32.9537,-96.8903),
('75013','Allen',33.1186,-96.6773),
('75014','Irving',32.7673,-96.7776),
('75015','Irving',32.8987,-96.9722),
('75016','Irving',32.8987,-96.9722),
('75017','Irving',32.7673,-96.7776),
('75019','Coppell',32.9673,-96.9805),
('75020','Denison',33.745,-96.5496),
('75021','Denison',33.7169,-96.5235),
('75022','Flower Mound',33.0268,-97.1193),
('75023','Plano',33.055,-96.7365),
('75024','Plano',33.0752,-96.7843),
('75025','Plano',33.0784,-96.7291),
('75026','Plano',33.0198,-96.6989),
('75027','Flower Mound',33.2074,-97.1163),
('75028','Flower Mound',33.0383,-97.0745),
('75029','Lewisville',33.0462,-96.9942),
('75030','Rowlett',32.9029,-96.5639),
('75032','Rockwall',32.886,-96.4095),
('75033','Frisco',33.2559,-96.8853),
('75034','Frisco',33.1499,-96.8241),
('75035','Frisco',33.1377,-96.7524),
('75037','Irving',32.78,-96.8),
('75038','Irving',32.8653,-96.9905),
('75039','Irving',32.8697,-96.9389),
('75040','Garland',32.9227,-96.6248),
('75041','Garland',32.8794,-96.6411),
('75042','Garland',32.9185,-96.6775),
('75043','Garland',32.8565,-96.5999),
('75044','Garland',32.9522,-96.6654),
('75045','Garland',32.9137,-96.6271),
('75046','Garland',32.9126,-96.6389),
('75047','Garland',32.9126,-96.6389),
('75048','Sachse',32.9643,-96.6012),
('75049','Garland',32.9126,-96.6389),
('75050','Grand Prairie',32.7649,-97.0112),
('75051','Grand Prairie',32.7115,-97.0069),
('75052','Grand Prairie',32.6605,-97.0311),
('75053','Grand Prairie',32.746,-96.9978),
('75054','Grand Prairie',32.5907,-97.0405),
('75056','The Colony',33.094,-96.8836),
('75057','Lewisville',33.0532,-96.9999),
('75058','Gunter',33.4495,-96.7341),
('75060','Irving',32.8023,-96.9597),
('75061','Irving',32.8267,-96.9633),
('75062','Irving',32.8479,-96.974),
('75063','Irving',32.9247,-96.9598),
('75065','Lake Dallas',33.1219,-97.0237),
('75067','Lewisville',33.0198,-96.9925),
('75068','Little Elm',33.1768,-96.9583),
('75069','Mckinney',33.1976,-96.6153),
('75070','Mckinney',33.1976,-96.6153),
('75071','Mckinney',33.1976,-96.6153),
('75074','Plano',33.0277,-96.6777),
('75075','Plano',33.025,-96.7397),
('75076','Pottsboro',33.8095,-96.6906),
('75077','Lewisville',33.0775,-97.0704),
('75078','Prosper',33.2362,-96.7954),
('75080','Richardson',32.966,-96.7452),
('75081','Richardson',32.9462,-96.7058),
('75082','Richardson',32.9865,-96.686),
('75083','Richardson',32.7673,-96.7776),
('75085','Richardson',32.7673,-96.7776),
('75086','Plano',33.0198,-96.6989),
('75087','Rockwall',32.9492,-96.4418),
('75088','Rowlett',32.9031,-96.5472),
('75089','Rowlett',32.9346,-96.5544),
('75090','Sherman',33.6435,-96.6075),
('75091','Sherman',33.6357,-96.6089),
('75092','Sherman',33.6372,-96.6184),
('75093','Plano',33.0299,-96.7889),
('75094','Plano',33.0148,-96.6189),
('75097','Weston',33.3512,-96.6646),
('75098','Wylie',33.0041,-96.5394),
('75099','Coppell',32.9546,-97.015),
('75101','Bardwell',32.2731,-96.703),
('75102','Barry',32.1014,-96.6251),
('75103','Canton',32.5143,-95.9047),
('75104','Cedar Hill',32.5885,-96.9438),
('75105','Chatfield',32.2954,-96.3887),
('75106','Cedar Hill',32.5885,-96.9561),
('75109','Corsicana',31.9937,-96.4199),
('75110','Corsicana',32.0868,-96.4762),
('75114','Crandall',32.6279,-96.4558),
('75115','Desoto',32.6041,-96.8653),
('75116','Duncanville',32.6587,-96.9114),
('75117','Edgewood',32.7003,-95.878),
('75118','Elmo',32.5996,-96.3027),
('75119','Ennis',32.3321,-96.6224),
('75120','Ennis',32.3347,-96.6335),
('75121','Copeville',33.0875,-96.4186),
('75123','Desoto',32.5899,-96.8569),
('75124','Eustace',32.2965,-96.0137),
('75125','Ferris',32.5223,-96.6643),
('75126','Forney',32.7491,-96.4598),
('75127','Fruitvale',32.677,-95.7899),
('75132','Fate',32.9415,-96.3814),
('75134','Lancaster',32.6161,-96.783),
('75135','Caddo Mills',33.0683,-96.2391),
('75137','Duncanville',32.6347,-96.9113),
('75138','Duncanville',32.7673,-96.7776),
('75140','Grand Saline',32.6635,-95.7064),
('75141','Hutchins',32.6396,-96.707),
('75142','Kaufman',32.546,-96.2852),
('75143','Kemp',32.2486,-96.2161),
('75144','Kerens',32.1275,-96.2298),
('75146','Lancaster',32.5914,-96.7728),
('75147','Mabank',32.3685,-96.0685),
('75148','Malakoff',32.1705,-96.006),
('75149','Mesquite',32.7678,-96.6082),
('75150','Mesquite',32.8154,-96.6307),
('75151','Corsicana',32.0624,-96.4735),
('75152','Palmer',32.4387,-96.6794),
('75153','Powell',32.1196,-96.3327),
('75154','Red Oak',32.5185,-96.8071),
('75155','Rice',32.2258,-96.4606),
('75156','Mabank',32.2972,-96.1184),
('75157','Rosser',32.4626,-96.4533),
('75158','Scurry',32.4818,-96.3925),
('75159','Seagoville',32.6525,-96.558),
('75160','Terrell',32.7515,-96.2831),
('75161','Terrell',32.7332,-96.195),
('75163','Trinidad',32.1383,-96.0831),
('75164','Josephine',33.0612,-96.3072),
('75165','Waxahachie',32.3808,-96.8374),
('75166','Lavon',33.0139,-96.4377),
('75167','Waxahachie',32.3773,-96.9162),
('75168','Waxahachie',32.3749,-96.7166),
('75169','Wills Point',32.7283,-96.0079),
('75172','Wilmer',32.5981,-96.6838),
('75173','Nevada',33.0593,-96.3877),
('75180','Balch Springs',32.7287,-96.6228),
('75181','Mesquite',32.7272,-96.5669),
('75182','Sunnyvale',32.797,-96.5616),
('75185','Mesquite',32.7403,-96.5618),
('75187','Mesquite',32.7673,-96.7776),
('75189','Royse City',32.9628,-96.3648),
('75201','Dallas',32.7904,-96.8044),
('75202','Dallas',32.7781,-96.8054),
('75203','Dallas',32.746,-96.807),
('75204','Dallas',32.8038,-96.7851),
('75205','Dallas',32.826,-96.7843),
('75206','Dallas',32.831,-96.7692),
('75207','Dallas',32.7939,-96.8319),
('75208','Dallas',32.7492,-96.8389),
('75209','Dallas',32.8456,-96.826),
('75210','Dallas',32.7699,-96.743),
('75211','Dallas',32.7319,-96.9057),
('75212','Dallas',32.7829,-96.8714),
('75214','Dallas',32.8248,-96.7498),
('75215','Dallas',32.7582,-96.7623),
('75216','Dallas',32.7086,-96.7955),
('75217','Dallas',32.7244,-96.6755),
('75218','Dallas',32.8463,-96.6972),
('75219','Dallas',32.8132,-96.8142),
('75220','Dallas',32.8681,-96.8622),
('75221','Dallas',32.8147,-96.7877),
('75222','Dallas',32.7673,-96.7776),
('75223','Dallas',32.7942,-96.7475),
('75224','Dallas',32.7114,-96.8387),
('75225','Dallas',32.8628,-96.7918),
('75226','Dallas',32.7887,-96.7676),
('75227','Dallas',32.7672,-96.6836),
('75228','Dallas',32.825,-96.6784),
('75229','Dallas',32.8958,-96.8588),
('75230','Dallas',32.8999,-96.7897),
('75231','Dallas',32.8756,-96.7495),
('75232','Dallas',32.6647,-96.8384),
('75233','Dallas',32.7046,-96.8725),
('75234','Dallas',32.9245,-96.8938),
('75235','Dallas',32.8252,-96.8388),
('75236','Dallas',32.69,-96.9177),
('75237','Dallas',32.659,-96.8765),
('75238','Dallas',32.877,-96.708),
('75240','Dallas',32.9374,-96.7872),
('75241','Dallas',32.6722,-96.7774),
('75242','Dallas',32.7673,-96.7776),
('75243','Dallas',32.9103,-96.7285),
('75244','Dallas',32.9322,-96.8353),
('75245','Dallas',32.82,-96.83),
('75246','Dallas',32.7948,-96.7697),
('75247','Dallas',32.8152,-96.8703),
('75248','Dallas',32.9682,-96.7942),
('75249','Dallas',32.636,-96.9493),
('75250','Dallas',32.7673,-96.7776),
('75251','Dallas',32.9189,-96.7751),
('75252','Dallas',32.9968,-96.7921),
('75253','Dallas',32.6833,-96.5964),
('75254','Dallas',32.9503,-96.819),
('75258','Dallas',32.8,-96.88),
('75260','Dallas',32.7673,-96.7776),
('75261','Dallas',32.7673,-96.7776),
('75262','Dallas',32.7673,-96.7776),
('75263','Dallas',32.7673,-96.7776),
('75264','Dallas',32.7673,-96.7776),
('75265','Dallas',32.7673,-96.7776),
('75266','Dallas',32.7673,-96.7776),
('75267','Dallas',32.7673,-96.7776),
('75270','Dallas',32.7813,-96.8019),
('75275','Dallas',32.7673,-96.7776),
('75277','Dallas',32.7673,-96.7776),
('75283','Dallas',32.7673,-96.7776),
('75284','Dallas',32.7673,-96.7776),
('75285','Dallas',32.7673,-96.7776),
('75286','Dallas',32.78,-96.8),
('75287','Dallas',33.0005,-96.8314),
('75301','Dallas',32.7673,-96.7776),
('75303','Dallas',32.7673,-96.7776),
('75310','Dallas',32.78,-96.8),
('75312','Dallas',32.7673,-96.7776),
('75313','Dallas',32.7673,-96.7776),
('75315','Dallas',32.7673,-96.7776),
('75320','Dallas',32.7673,-96.7776),
('75323','Dallas',32.96,-96.8),
('75326','Dallas',32.7673,-96.7776),
('75334','Dallas',32.67,-96.61),
('75336','Dallas',32.7673,-96.7776),
('75339','Dallas',32.7673,-96.7776),
('75340','Dallas',32.76,-96.86),
('75342','Dallas',32.7673,-96.7776),
('75343','Dallas',32.76,-96.86),
('75344','Dallas',32.78,-96.79),
('75353','Dallas',32.78,-96.8),
('75354','Dallas',32.7673,-96.7776),
('75355','Dallas',32.7673,-96.7776),
('75356','Dallas',32.7673,-96.7776),
('75357','Dallas',32.7673,-96.7776),
('75358','Dallas',32.7942,-96.7652),
('75359','Dallas',32.7673,-96.7776),
('75360','Dallas',32.7673,-96.7776),
('75363','American Express',32.93,-96.79),
('75364','Dallas',32.78,-96.8),
('75367','Dallas',32.7673,-96.7776),
('75368','Dallas',32.7673,-96.7776),
('75370','Dallas',32.7673,-96.7776),
('75371','Dallas',32.7673,-96.7776),
('75372','Dallas',32.7673,-96.7776),
('75373','Dallas',32.7673,-96.7776),
('75374','Dallas',32.7673,-96.7776),
('75376','Dallas',32.7673,-96.7776),
('75378','Dallas',32.7673,-96.7776),
('75379','Dallas',32.7673,-96.7776),
('75380','Dallas',32.7673,-96.7776),
('75381','Dallas',32.7673,-96.7776),
('75382','Dallas',32.7673,-96.7776),
('75386','Dallas',32.78,-96.87),
('75387','Dallas',32.78,-96.8),
('75388','Dallas',32.78,-96.8),
('75389','Dallas',32.7673,-96.7776),
('75390','Dallas',32.7673,-96.7776),
('75391','Dallas',32.7673,-96.7776),
('75392','Dallas',32.7673,-96.7776),
('75393','Dallas',32.7673,-96.7776),
('75394','Dallas',32.7673,-96.7776),
('75395','Dallas',32.7673,-96.7776),
('75396','Dallas',32.78,-96.8),
('75397','Dallas',32.7673,-96.7776),
('75398','Dallas',32.7673,-96.7776),
('75401','Greenville',33.1854,-96.1304),
('75402','Greenville',33.1047,-96.0927),
('75403','Greenville',33.2185,-96.0487),
('75404','Greenville',33.0563,-96.081),
('75407','Princeton',33.1555,-96.4981),
('75409','Anna',33.3445,-96.5639),
('75410','Alba',32.7652,-95.5971),
('75411','Arthur City',33.8643,-95.6111),
('75412','Bagwell',33.8361,-95.1487),
('75413','Bailey',33.43,-96.1662),
('75414','Bells',33.6178,-96.4237),
('75415','Ben Franklin',33.4768,-95.7689),
('75416','Blossom',33.6945,-95.3823),
('75417','Bogata',33.4699,-95.1937),
('75418','Bonham',33.5806,-96.1836),
('75420','Brashear',33.1155,-95.7345),
('75421','Brookston',33.6246,-95.6888),
('75422','Campbell',33.151,-95.9439),
('75423','Celeste',33.2649,-96.2076),
('75424','Blue Ridge',33.3061,-96.3901),
('75425','Chicota',33.869,-95.5711),
('75426','Clarksville',33.6236,-95.0461),
('75428','Commerce',33.2493,-95.9097),
('75429','Commerce',33.2377,-95.9089),
('75431','Como',33.0107,-95.4734),
('75432','Cooper',33.3812,-95.6623),
('75433','Cumby',33.1118,-95.7945),
('75434','Cunningham',33.409,-95.3711),
('75435','Deport',33.5221,-95.3654),
('75436','Detroit',33.6627,-95.2385),
('75437','Dike',33.2648,-95.4423),
('75438','Dodd City',33.5647,-96.0619),
('75439','Ector',33.5819,-96.2735),
('75440','Emory',32.875,-95.7418),
('75441','Enloe',33.4291,-95.6518),
('75442','Farmersville',33.1659,-96.3686),
('75443','Gober',33.4697,-96.1111),
('75444','Golden',32.7299,-95.5636),
('75446','Honey Grove',33.5985,-95.9109),
('75447','Ivanhoe',33.7612,-96.1193),
('75448','Klondike',33.3034,-95.8018),
('75449','Ladonia',33.4245,-95.9455),
('75450','Lake Creek',33.4116,-95.4551),
('75451','Leesburg',32.9763,-95.1079),
('75452','Leonard',33.3796,-96.2475),
('75453','Lone Oak',32.9916,-95.9434),
('75454','Melissa',33.2841,-96.574),
('75455','Mount Pleasant',33.1733,-94.9695),
('75456','Mount Pleasant',33.1568,-94.9683),
('75457','Mount Vernon',33.1702,-95.2181),
('75458','Merit',33.2427,-96.2916),
('75459','Howe',33.5311,-96.6777),
('75460','Paris',33.6581,-95.5379),
('75461','Paris',33.6609,-95.5555),
('75462','Paris',33.6805,-95.4905),
('75468','Pattonville',33.5702,-95.3908),
('75469','Pecan Gap',33.4196,-95.8262),
('75470','Petty',33.6098,-95.7891),
('75471','Pickton',33.0519,-95.3851),
('75472','Point',32.9007,-95.8903),
('75473','Powderly',33.7779,-95.5307),
('75474','Quinlan',32.8983,-96.1261),
('75475','Randolph',33.4846,-96.2541),
('75476','Ravenna',33.7098,-96.1452),
('75477','Roxton',33.5429,-95.7416),
('75478','Saltillo',33.1767,-95.3433),
('75479','Savoy',33.6066,-96.3502),
('75480','Scroggins',33.0478,-95.1962),
('75481','Sulphur Bluff',33.3334,-95.374),
('75482','Sulphur Springs',33.1345,-95.5922),
('75483','Sulphur Springs',33.1384,-95.6011),
('75485','Westminster',33.3627,-96.4635),
('75486','Sumner',33.7589,-95.6807),
('75487','Talco',33.3344,-95.0497),
('75488','Telephone',33.7979,-96.0449),
('75489','Tom Bean',33.5193,-96.4843),
('75490','Trenton',33.4235,-96.3398),
('75491','Whitewright',33.519,-96.451),
('75492','Windom',33.5633,-96.002),
('75493','Winfield',33.1673,-95.1119),
('75494','Winnsboro',32.9146,-95.2726),
('75495','Van Alstyne',33.4292,-96.5486),
('75496','Wolfe City',33.3605,-96.0691),
('75497','Yantis',32.9257,-95.5311),
('75501','Texarkana',33.4113,-94.1774),
('75503','Texarkana',33.4669,-94.0774),
('75504','Texarkana',33.4251,-94.0477),
('75505','Texarkana',33.4624,-94.0715),
('75507','Texarkana',33.4251,-94.0477),
('75550','Annona',33.5535,-94.8992),
('75551','Atlanta',33.109,-94.1646),
('75554','Avery',33.5339,-94.7867),
('75555','Bivins',32.966,-94.1404),
('75556','Bloomburg',33.1339,-94.0647),
('75558','Cookville',33.2432,-94.8747),
('75559','De Kalb',33.5087,-94.6163),
('75560','Douglassville',33.1758,-94.3467),
('75561','Hooks',33.5253,-94.2657),
('75562','Kildare',32.9468,-94.2539),
('75563','Linden',33.0048,-94.3605),
('75564','Lodi',32.8718,-94.2729),
('75565','Mc Leod',32.9511,-94.0808),
('75566','Marietta',33.1735,-94.5424),
('75567','Maud',33.3409,-94.3175),
('75568','Naples',33.1912,-94.6891),
('75569','Nash',33.4344,-94.1219),
('75570','New Boston',33.4619,-94.4375),
('75571','Omaha',33.1808,-94.7639),
('75572','Queen City',33.1557,-94.1537),
('75573','Redwater',33.358,-94.2571),
('75574','Simms',33.3359,-94.552),
('75599','Texarkana',33.4251,-94.0477),
('75601','Longview',32.5178,-94.7303),
('75602','Longview',32.4724,-94.7101),
('75603','Longview',32.4264,-94.7117),
('75604','Longview',32.5251,-94.799),
('75605','Longview',32.5547,-94.7767),
('75606','Longview',32.5007,-94.7405),
('75607','Longview',32.5112,-94.7835),
('75608','Longview',32.5701,-94.8481),
('75615','Longview',32.5112,-94.7835),
('75630','Avinger',32.8485,-94.5795),
('75631','Beckville',32.2452,-94.4555),
('75633','Carthage',32.1544,-94.3527),
('75636','Cason',33.024,-94.8249),
('75637','Clayton',32.1027,-94.4935),
('75638','Daingerfield',33.0313,-94.7359),
('75639','De Berry',32.2543,-94.1356),
('75640','Diana',32.7698,-94.7032),
('75641','Easton',32.3874,-94.583),
('75642','Elysian Fields',32.3685,-94.183),
('75643','Gary',32.0334,-94.38),
('75644','Gilmer',32.7246,-94.9714),
('75645','Gilmer',32.6044,-94.8491),
('75647','Gladewater',32.5559,-94.932),
('75650','Hallsville',32.5073,-94.5333),
('75651','Harleton',32.6579,-94.4652),
('75652','Henderson',32.2131,-94.7834),
('75653','Henderson',32.1532,-94.7994),
('75654','Henderson',32.126,-94.7488),
('75656','Hughes Springs',33.0168,-94.6228),
('75657','Jefferson',32.8059,-94.3655),
('75658','Joinerville',32.1959,-94.9065),
('75659','Jonesville',32.5075,-94.1106),
('75660','Judson',32.5826,-94.7535),
('75661','Karnack',32.6205,-94.2001),
('75662','Kilgore',32.3836,-94.8653),
('75663','Kilgore',32.387,-94.8951),
('75666','Laird Hill',32.3532,-94.9055),
('75667','Laneville',31.9508,-94.866),
('75668','Lone Star',32.9252,-94.7049),
('75669','Long Branch',32.0449,-94.5381),
('75670','Marshall',32.5338,-94.3619),
('75671','Marshall',32.5449,-94.3674),
('75672','Marshall',32.5165,-94.3251),
('75680','Minden',32.0028,-94.7129),
('75681','Mount Enterprise',31.9125,-94.6235),
('75682','New London',32.2542,-94.9322),
('75683','Ore City',32.7856,-94.7514),
('75684','Overton',32.269,-94.9529),
('75685','Panola',32.3579,-94.0913),
('75686','Pittsburg',32.9623,-94.9603),
('75687','Price',32.1518,-94.9554),
('75688','Scottsville',32.554,-94.2394),
('75689','Selman City',32.1826,-94.9355),
('75691','Tatum',32.3266,-94.596),
('75692','Waskom',32.5184,-94.1355),
('75693','White Oak',32.5383,-94.8622),
('75694','Woodlawn',32.6537,-94.3427),
('75701','Tyler',32.3254,-95.2922),
('75702','Tyler',32.362,-95.3117),
('75703','Tyler',32.2768,-95.3031),
('75704','Tyler',32.3738,-95.407),
('75705','Tyler',32.3766,-95.1252),
('75706','Tyler',32.4441,-95.331),
('75707','Tyler',32.3038,-95.1927),
('75708','Tyler',32.419,-95.2106),
('75709','Tyler',32.3078,-95.3956),
('75710','Tyler',32.3475,-95.3065),
('75711','Tyler',32.3513,-95.3011),
('75712','Tyler',32.4112,-95.2899),
('75713','Tyler',32.4112,-95.2899),
('75750','Arp',32.2418,-95.0639),
('75751','Athens',32.1935,-95.8432),
('75752','Athens',32.2151,-95.79),
('75754','Ben Wheeler',32.4126,-95.6371),
('75755','Big Sandy',32.6168,-95.088),
('75756','Brownsboro',32.304,-95.6),
('75757','Bullard',32.1095,-95.3342),
('75758','Chandler',32.2572,-95.5393),
('75759','Cuney',32.0415,-95.42),
('75760','Cushing',31.7978,-94.8539),
('75762','Flint',32.2079,-95.3948),
('75763','Frankston',32.0535,-95.5163),
('75764','Gallatin',31.891,-95.1455),
('75765','Hawkins',32.6439,-95.222),
('75766','Jacksonville',31.9618,-95.2703),
('75770','Larue',32.1608,-95.5927),
('75771','Lindale',32.5062,-95.4006),
('75772','Maydelle',31.8008,-95.3001),
('75773','Mineola',32.6661,-95.487),
('75778','Murchison',32.3257,-95.7737),
('75779','Neches',31.8668,-95.4958),
('75780','New Summerfield',31.9807,-95.0938),
('75782','Poynor',32.0797,-95.5938),
('75783','Quitman',32.8049,-95.4302),
('75784','Reklaw',31.8859,-95.0118),
('75785','Rusk',31.8136,-95.0965),
('75788','Sacul',31.8254,-94.9189),
('75789','Troup',32.1117,-95.1155),
('75790','Van',32.5283,-95.6545),
('75791','Whitehouse',32.222,-95.2266),
('75792','Winona',32.4662,-95.1246),
('75797','Big Sandy',32.5765,-95.1313),
('75798','Tyler',32.4112,-95.2899),
('75799','Tyler',32.4112,-95.2899),
('75801','Palestine',31.7588,-95.6342),
('75802','Palestine',31.7621,-95.6308),
('75803','Palestine',31.7571,-95.6545),
('75831','Buffalo',31.4121,-95.9904),
('75832','Cayuga',31.9571,-95.9747),
('75833','Centerville',31.272,-95.9213),
('75834','Centralia',31.258,-95.0399),
('75835','Crockett',31.3208,-95.3928),
('75838','Donie',31.4873,-96.2387),
('75839','Elkhart',31.648,-95.5551),
('75840','Fairfield',31.7361,-96.1572),
('75844','Grapeland',31.4972,-95.4447),
('75845','Groveton',31.0651,-95.0969),
('75846','Jewett',31.3739,-96.1918),
('75847','Kennard',31.3384,-95.1541),
('75848','Kirvin',31.7666,-96.3303),
('75849','Latexo',31.3952,-95.4741),
('75850','Leona',31.1421,-95.9284),
('75851','Lovelady',31.0564,-95.5501),
('75852','Midway',30.9806,-95.7089),
('75853','Montalba',31.8766,-95.7327),
('75855','Oakwood',31.5849,-95.8491),
('75856','Pennington',31.1953,-95.2469),
('75858','Ratcliff',31.3916,-95.1397),
('75859','Streetman',31.8885,-96.2988),
('75860','Teague',31.6328,-96.2778),
('75861','Tennessee Colony',31.7929,-95.8998),
('75862','Trinity',30.942,-95.3403),
('75865','Woodlake',31.0288,-95.033),
('75880','Tennessee Colony',31.8354,-95.8389),
('75882','Palestine',31.7942,-95.662),
('75884','Tennessee Colony',31.8354,-95.8389),
('75886','Tennessee Colony',31.8354,-95.8389),
('75901','Lufkin',31.27,-94.6469),
('75902','Lufkin',31.3623,-94.7611),
('75903','Lufkin',31.2766,-94.5676),
('75904','Lufkin',31.3489,-94.8327),
('75915','Lufkin',31.3382,-94.7291),
('75925','Alto',31.6103,-95.0762),
('75926','Apple Springs',31.2269,-94.9812),
('75928','Bon Wier',30.6876,-93.7665),
('75929','Broaddus',31.2952,-94.2156),
('75930','Bronson',31.3391,-93.9993),
('75931','Brookeland',31.0922,-93.9684),
('75932','Burkeville',31.0099,-93.6585),
('75933','Call',30.5741,-93.8334),
('75934','Camden',30.9,-94.7547),
('75935','Center',31.7865,-94.1869),
('75936','Chester',30.9447,-94.5554),
('75937','Chireno',31.5119,-94.4302),
('75938','Colmesneil',30.9007,-94.3916),
('75939','Corrigan',31.0408,-94.8124),
('75941','Diboll',31.195,-94.7729),
('75942','Doucette',30.8183,-94.4288),
('75943','Douglass',31.6578,-94.8696),
('75944','Etoile',31.3601,-94.4064),
('75946','Garrison',31.8111,-94.5266),
('75948','Hemphill',31.3161,-93.7905),
('75949','Huntington',31.2837,-94.5662),
('75951','Jasper',30.8673,-93.9977),
('75954','Joaquin',31.944,-94.0608),
('75956','Kirbyville',30.6583,-93.8984),
('75958','Martinsville',31.6427,-94.4141),
('75959','Milam',31.4324,-93.8457),
('75960','Moscow',30.9179,-94.8544),
('75961','Nacogdoches',31.5611,-94.5),
('75962','Nacogdoches',31.6995,-94.6074),
('75963','Nacogdoches',31.6046,-94.6641),
('75964','Nacogdoches',31.6737,-94.6932),
('75965','Nacogdoches',31.7195,-94.6168),
('75966','Newton',30.8351,-93.7497),
('75968','Pineland',31.2418,-93.9754),
('75969','Pollok',31.4291,-94.8254),
('75972','San Augustine',31.5152,-94.1326),
('75973','Shelbyville',31.7131,-93.9698),
('75974','Tenaha',31.9408,-94.2488),
('75975','Timpson',31.8841,-94.3967),
('75976','Wells',31.4885,-94.9399),
('75977','Wiergate',31.0414,-93.8039),
('75978','Woden',31.5037,-94.525),
('75979','Woodville',30.7752,-94.4155),
('75980','Zavalla',31.1569,-94.3871),
('75990','Woodville',30.7752,-94.4155),
('76001','Arlington',32.6289,-97.1517),
('76002','Arlington',32.6255,-97.0784),
('76003','Arlington',32.7417,-97.2253),
('76004','Arlington',32.7357,-97.1081),
('76005','Arlington',32.7714,-97.2915),
('76006','Arlington',32.7785,-97.0834),
('76007','Arlington',32.7714,-97.2915),
('76008','Aledo',32.7004,-97.6039),
('76009','Alvarado',32.4395,-97.213),
('76010','Arlington',32.7204,-97.0826),
('76011','Arlington',32.7582,-97.1003),
('76012','Arlington',32.754,-97.1348),
('76013','Arlington',32.7199,-97.1442),
('76014','Arlington',32.6954,-97.0876),
('76015','Arlington',32.6931,-97.1347),
('76016','Arlington',32.6889,-97.1905),
('76017','Arlington',32.6555,-97.1599),
('76018','Arlington',32.6548,-97.092),
('76019','Arlington',32.7357,-97.1081),
('76020','Azle',32.9035,-97.5412),
('76021','Bedford',32.8536,-97.1358),
('76022','Bedford',32.8297,-97.1454),
('76023','Boyd',33.0594,-97.5868),
('76028','Burleson',32.5316,-97.309),
('76031','Cleburne',32.3485,-97.3311),
('76033','Cleburne',32.3509,-97.4103),
('76034','Colleyville',32.8872,-97.146),
('76035','Cresson',32.5343,-97.6158),
('76036','Crowley',32.5814,-97.3703),
('76039','Euless',32.8582,-97.0832),
('76040','Euless',32.8264,-97.0972),
('76041','Forreston',32.2486,-96.8232),
('76043','Glen Rose',32.2298,-97.7629),
('76044','Godley',32.4282,-97.5349),
('76048','Granbury',32.425,-97.7742),
('76049','Granbury',32.4488,-97.7285),
('76050','Grandview',32.2704,-97.1792),
('76051','Grapevine',32.9328,-97.0808),
('76052','Haslet',32.9557,-97.3372),
('76053','Hurst',32.8211,-97.1756),
('76054','Hurst',32.8558,-97.1755),
('76055','Itasca',32.1636,-97.146),
('76058','Joshua',32.4663,-97.4011),
('76059','Keene',32.3937,-97.3287),
('76060','Kennedale',32.6432,-97.2139),
('76061','Lillian',32.5065,-97.1875),
('76063','Mansfield',32.5773,-97.1416),
('76064','Maypearl',32.2993,-97.0271),
('76065','Midlothian',32.4757,-96.9936),
('76066','Millsap',32.7457,-97.9561),
('76067','Mineral Wells',32.8085,-98.1128),
('76068','Mineral Wells',32.8085,-98.1128),
('76070','Nemo',32.2713,-97.6567),
('76071','Newark',33.007,-97.4923),
('76073','Paradise',33.0826,-97.6974),
('76077','Rainbow',32.2812,-97.7065),
('76078','Rhome',33.054,-97.4817),
('76082','Springtown',32.966,-97.6836),
('76084','Venus',32.433,-97.1087),
('76085','Weatherford',32.7676,-97.7516),
('76086','Weatherford',32.7549,-97.7899),
('76087','Weatherford',32.7495,-97.6894),
('76088','Weatherford',32.8478,-97.8606),
('76092','Southlake',32.9485,-97.1524),
('76093','Rio Vista',32.2532,-97.3678),
('76094','Arlington',32.7714,-97.2915),
('76095','Bedford',32.844,-97.1431),
('76096','Arlington',32.7714,-97.2915),
('76097','Burleson',32.5421,-97.3208),
('76098','Azle',32.8957,-97.5636),
('76099','Grapevine',32.9343,-97.0781),
('76101','Fort Worth',32.7714,-97.2915),
('76102','Fort Worth',32.7589,-97.328),
('76103','Fort Worth',32.747,-97.2604),
('76104','Fort Worth',32.7256,-97.3184),
('76105','Fort Worth',32.7233,-97.269),
('76106','Fort Worth',32.7968,-97.356),
('76107','Fort Worth',32.7392,-97.3852),
('76108','Fort Worth',32.7822,-97.4969),
('76109','Fort Worth',32.7002,-97.3789),
('76110','Fort Worth',32.7065,-97.3375),
('76111','Fort Worth',32.7824,-97.3003),
('76112','Fort Worth',32.7493,-97.2181),
('76113','Fort Worth',32.7714,-97.2915),
('76114','Fort Worth',32.7796,-97.3928),
('76115','Fort Worth',32.6796,-97.3336),
('76116','Fort Worth',32.723,-97.4483),
('76117','Haltom City',32.8087,-97.2709),
('76118','Fort Worth',32.8013,-97.1952),
('76119','Fort Worth',32.6914,-97.2675),
('76120','Fort Worth',32.7639,-97.1781),
('76121','Fort Worth',32.7714,-97.2915),
('76122','Fort Worth',32.7714,-97.2915),
('76123','Fort Worth',32.6254,-97.3658),
('76124','Fort Worth',32.7714,-97.2915),
('76126','Fort Worth',32.64,-97.5448),
('76127','Naval Air Station/ Jrb',32.7254,-97.3208),
('76129','Fort Worth',32.7714,-97.2915),
('76130','Fort Worth',32.7714,-97.2915),
('76131','Fort Worth',32.8632,-97.3377),
('76132','Fort Worth',32.6711,-97.4056),
('76133','Fort Worth',32.6526,-97.3758),
('76134','Fort Worth',32.6469,-97.3325),
('76135','Fort Worth',32.8248,-97.4519),
('76136','Fort Worth',32.7714,-97.2915),
('76137','Fort Worth',32.8664,-97.2891),
('76140','Fort Worth',32.6192,-97.2735),
('76147','Fort Worth',32.7714,-97.2915),
('76148','Fort Worth',32.8621,-97.2508),
('76150','Fort Worth',32.7714,-97.2915),
('76155','Fort Worth',32.8247,-97.0503),
('76161','Fort Worth',32.7714,-97.2915),
('76162','Fort Worth',32.7714,-97.2915),
('76163','Fort Worth',32.7714,-97.2915),
('76164','Fort Worth',32.7811,-97.3546),
('76166','Fort Worth',32.7539,-97.3362),
('76177','Fort Worth',32.9448,-97.3124),
('76179','Fort Worth',32.9074,-97.4257),
('76180','North Richland Hills',32.84,-97.225),
('76181','Fort Worth',32.7714,-97.2915),
('76182','North Richland Hills',32.8828,-97.2098),
('76185','Fort Worth',32.7714,-97.2915),
('76190','Fort Worth',32.7423,-97.3315),
('76191','Fort Worth',32.7714,-97.2915),
('76192','Fort Worth',32.7714,-97.2915),
('76193','Fort Worth',32.7714,-97.2915),
('76195','Fort Worth',32.7254,-97.3208),
('76196','Fort Worth',32.7714,-97.2915),
('76197','Fort Worth',32.7714,-97.2915),
('76198','Fort Worth',32.7714,-97.2915),
('76199','Fort Worth',32.7714,-97.2915),
('76201','Denton',33.2289,-97.1314),
('76202','Denton',33.2255,-97.1085),
('76203','Denton',33.2148,-97.1331),
('76204','Denton',33.2074,-97.1163),
('76205','Denton',33.1903,-97.1282),
('76206','Denton',33.1694,-97.1506),
('76207','Denton',33.2285,-97.1813),
('76208','Denton',33.2117,-97.0612),
('76209','Denton',33.2346,-97.1131),
('76210','Denton',33.1428,-97.0727),
('76225','Alvord',33.3698,-97.6885),
('76226','Argyle',33.1062,-97.16),
('76227','Aubrey',33.292,-96.9879),
('76228','Bellevue',33.5879,-98.1574),
('76230','Bowie',33.5568,-97.8373),
('76233','Collinsville',33.558,-96.9014),
('76234','Decatur',33.2351,-97.574),
('76238','Era',33.4965,-97.3859),
('76239','Forestburg',33.5398,-97.5848),
('76240','Gainesville',33.6547,-97.1583),
('76241','Gainesville',33.6104,-97.0369),
('76244','Keller',32.931,-97.2843),
('76245','Gordonville',33.8343,-96.8403),
('76246','Greenwood',33.407,-97.4716),
('76247','Justin',33.0734,-97.3093),
('76248','Keller',32.9276,-97.2489),
('76249','Krum',33.2734,-97.2675),
('76250','Lindsay',33.636,-97.2214),
('76251','Montague',33.6639,-97.7282),
('76252','Muenster',33.6595,-97.3624),
('76253','Myra',33.6178,-97.309),
('76255','Nocona',33.7982,-97.727),
('76258','Pilot Point',33.371,-96.9446),
('76259','Ponder',33.1774,-97.2848),
('76261','Ringgold',33.8164,-97.944),
('76262','Roanoke',33.0211,-97.2127),
('76263','Rosston',33.4674,-97.4534),
('76264','Sadler',33.731,-96.84),
('76265','Saint Jo',33.744,-97.5568),
('76266','Sanger',33.3563,-97.1814),
('76267','Slidell',33.378,-97.3922),
('76268','Southmayd',33.6304,-96.7692),
('76270','Sunset',33.4539,-97.7709),
('76271','Tioga',33.4675,-96.9097),
('76272','Valley View',33.5022,-97.2311),
('76273','Whitesboro',33.659,-96.879),
('76299','Roanoke',32.99,-97.23),
('76301','Wichita Falls',33.9053,-98.4976),
('76302','Wichita Falls',33.8643,-98.494),
('76305','Wichita Falls',33.9995,-98.3938),
('76306','Wichita Falls',33.9519,-98.5145),
('76307','Wichita Falls',33.9137,-98.4934),
('76308','Wichita Falls',33.8633,-98.534),
('76309','Wichita Falls',33.8931,-98.5343),
('76310','Wichita Falls',33.8581,-98.5755),
('76311','Sheppard Afb',33.9824,-98.5088),
('76351','Archer City',33.5562,-98.6249),
('76352','Bluegrove',33.674,-98.23),
('76354','Burkburnett',34.086,-98.5708),
('76357','Byers',34.0728,-98.1839),
('76360','Electra',34.0362,-98.9155),
('76363','Goree',33.4748,-99.5258),
('76364','Harrold',34.0806,-99.0323),
('76365','Henrietta',33.8196,-98.26),
('76366','Holliday',33.8162,-98.6951),
('76367','Iowa Park',33.9423,-98.6745),
('76369','Kamay',33.8579,-98.8081),
('76370','Megargel',33.4533,-98.9297),
('76371','Munday',33.4561,-99.6326),
('76372','Newcastle',33.1901,-98.7446),
('76373','Oklaunion',34.1295,-99.1429),
('76374','Olney',33.3601,-98.7427),
('76377','Petrolia',34.0132,-98.2323),
('76379','Scotland',33.6535,-98.465),
('76380','Seymour',33.5914,-99.2587),
('76384','Vernon',34.1491,-99.303),
('76385','Vernon',34.1554,-99.2663),
('76388','Weinert',33.3249,-99.6664),
('76389','Windthorst',33.5796,-98.4376),
('76401','Stephenville',32.2214,-98.2224),
('76402','Stephenville',32.2153,-98.208),
('76424','Breckenridge',32.7532,-98.9099),
('76426','Bridgeport',33.187,-97.781),
('76427','Bryson',33.1615,-98.3874),
('76429','Caddo',32.6886,-98.659),
('76430','Albany',32.719,-99.3196),
('76431','Chico',33.3193,-97.8031),
('76432','Blanket',31.7882,-98.8311),
('76433','Bluff Dale',32.2884,-98.0539),
('76435','Carbon',32.2701,-98.8348),
('76436','Carlton',31.8949,-98.1842),
('76437','Cisco',32.38,-98.9865),
('76439','Dennis',32.6187,-97.9267),
('76442','Comanche',31.9116,-98.6082),
('76443','Cross Plains',32.1482,-99.1872),
('76444','De Leon',32.1087,-98.5489),
('76445','Desdemona',32.2819,-98.5673),
('76446','Dublin',32.0909,-98.3455),
('76448','Eastland',32.3994,-98.8071),
('76449','Graford',32.9242,-98.337),
('76450','Graham',33.0993,-98.5832),
('76452','Energy',31.7629,-98.3695),
('76453','Gordon',32.5478,-98.3632),
('76454','Gorman',32.2234,-98.6834),
('76455','Gustine',31.8468,-98.4017),
('76457','Hico',31.9597,-98.0249),
('76458','Jacksboro',33.2347,-98.1681),
('76459','Jermyn',33.2636,-98.3931),
('76460','Loving',33.2689,-98.5024),
('76461','Lingleville',32.2446,-98.3775),
('76462','Lipan',32.5072,-97.9536),
('76463','Mingus',32.5381,-98.4219),
('76464','Moran',32.5549,-99.1656),
('76465','Morgan Mill',32.3882,-98.1673),
('76466','Olden',32.4421,-98.7342),
('76467','Paluxy',32.2707,-97.9075),
('76468','Proctor',31.9874,-98.4298),
('76469','Putnam',32.374,-99.1957),
('76470','Ranger',32.4681,-98.6747),
('76471','Rising Star',32.128,-98.9859),
('76472','Santo',32.5979,-98.1797),
('76474','Sidney',31.932,-98.768),
('76475','Strawn',32.5945,-98.4995),
('76476','Tolar',32.3772,-97.8802),
('76481','South Bend',33.0052,-98.6892),
('76483','Throckmorton',33.1794,-99.1838),
('76484','Palo Pinto',32.7673,-98.2987),
('76485','Peaster',32.8721,-97.8667),
('76486','Perrin',33.034,-98.0692),
('76487','Poolville',32.968,-97.8472),
('76490','Whitt',32.9555,-98.021),
('76491','Woodson',33.0741,-99.0546),
('76501','Temple',31.0895,-97.3343),
('76502','Temple',31.071,-97.3898),
('76503','Temple',31.054,-97.3203),
('76504','Temple',31.0917,-97.3648),
('76505','Temple',31.09,-97.36),
('76508','Temple',31.0363,-97.492),
('76511','Bartlett',30.7991,-97.4263),
('76513','Belton',31.0723,-97.472),
('76518','Buckholts',30.8858,-97.1241),
('76519','Burlington',30.9736,-96.9642),
('76520','Cameron',30.8527,-96.9766),
('76522','Copperas Cove',31.2029,-97.9301),
('76523','Davilla',30.7857,-97.275),
('76524','Eddy',31.3088,-97.2774),
('76525','Evant',31.4388,-98.0535),
('76526','Flat',31.2956,-97.5822),
('76527','Florence',30.8076,-97.7812),
('76528','Gatesville',31.4177,-97.833),
('76530','Granger',30.7398,-97.4451),
('76531','Hamilton',31.6781,-98.1131),
('76533','Heidenheimer',31.0496,-97.4936),
('76534','Holland',30.88,-97.3857),
('76537','Jarrell',30.8119,-97.5942),
('76538','Jonesboro',31.5599,-97.8456),
('76539','Kempner',31.0887,-98.0099),
('76540','Killeen',31.1171,-97.7278),
('76541','Killeen',31.1164,-97.7278),
('76542','Killeen',31.0376,-97.6809),
('76543','Killeen',31.1172,-97.6651),
('76544','Fort Hood',31.1349,-97.7756),
('76545','Killeen',31.11,-97.72),
('76546','Killeen',31.11,-97.72),
('76547','Killeen',31.1171,-97.7278),
('76548','Harker Heights',31.0286,-97.6115),
('76549','Killeen',31.0065,-97.841),
('76550','Lampasas',31.068,-98.1834),
('76554','Little River Academy',30.9863,-97.3586),
('76556','Milano',30.7304,-96.8807),
('76557','Moody',31.2533,-97.41),
('76558','Mound',31.3514,-97.6444),
('76559','Nolanville',31.0833,-97.5941),
('76561','Oglesby',31.4438,-97.5501),
('76564','Pendleton',31.1952,-97.3486),
('76565','Pottsville',31.6732,-98.3256),
('76566','Purmela',31.4841,-97.9903),
('76567','Rockdale',30.6583,-97.0079),
('76569','Rogers',30.955,-97.2228),
('76570','Rosebud',31.0922,-96.9755),
('76571','Salado',30.9494,-97.533),
('76573','Schwertner',30.8155,-97.5142),
('76574','Taylor',30.5708,-97.4094),
('76577','Thorndale',30.6082,-97.1764),
('76578','Thrall',30.592,-97.2893),
('76579','Troy',31.1759,-97.2852),
('76596','Gatesville',31.3902,-97.7993),
('76597','Gatesville',31.3902,-97.7993),
('76598','Gatesville',31.3902,-97.7993),
('76599','Gatesville',31.4706,-97.7347),
('76621','Abbott',31.8916,-97.0671),
('76622','Aquilla',31.8589,-97.2258),
('76623','Avalon',32.2054,-96.79),
('76624','Axtell',31.661,-96.9882),
('76626','Blooming Grove',32.0758,-96.701),
('76627','Blum',32.1052,-97.3652),
('76628','Brandon',32.0457,-96.9606),
('76629','Bremond',31.156,-96.6697),
('76630','Bruceville',31.3267,-97.2342),
('76631','Bynum',31.9907,-96.9837),
('76632','Chilton',31.31,-97.09),
('76633','China Spring',31.6673,-97.3002),
('76634','Clifton',31.7918,-97.5203),
('76635','Coolidge',31.7438,-96.6577),
('76636','Covington',32.1595,-97.2591),
('76637','Cranfills Gap',31.7486,-97.8113),
('76638','Crawford',31.5598,-97.39),
('76639','Dawson',31.8974,-96.7085),
('76640','Elm Mott',31.6725,-97.1138),
('76641','Frost',32.0275,-96.7684),
('76642','Groesbeck',31.5357,-96.5234),
('76643','Hewitt',31.4582,-97.1966),
('76644','Laguna Park',31.8593,-97.3797),
('76645','Hillsboro',32.0149,-97.1198),
('76648','Hubbard',31.8436,-96.8),
('76649','Iredell',31.9722,-97.8793),
('76650','Irene',31.9921,-96.8714),
('76651','Italy',32.1785,-96.8823),
('76652','Kopperl',32.1035,-97.5421),
('76653','Kosse',31.3147,-96.6195),
('76654','Leroy',31.7316,-97.0178),
('76655','Lorena',31.4093,-97.2302),
('76656','Lott',31.1925,-97.0581),
('76657','Mc Gregor',31.4431,-97.3943),
('76660','Malone',31.924,-96.8907),
('76661','Marlin',31.3036,-96.8889),
('76664','Mart',31.5458,-96.8381),
('76665','Meridian',31.929,-97.6443),
('76666','Mertens',32.0275,-96.8981),
('76667','Mexia',31.6784,-96.4952),
('76670','Milford',32.1482,-96.9612),
('76671','Morgan',32.0195,-97.5608),
('76673','Mount Calm',31.7575,-96.8944),
('76676','Penelope',31.8551,-96.9372),
('76678','Prairie Hill',31.6591,-96.8094),
('76679','Purdon',31.9483,-96.5856),
('76680','Reagan',31.1871,-96.7998),
('76681','Richland',31.9018,-96.4373),
('76682','Riesel',31.5002,-96.9476),
('76684','Ross',31.7173,-97.1188),
('76685','Satin',31.3601,-97.0108),
('76686','Tehuacana',31.7504,-96.5416),
('76687','Thornton',31.4083,-96.5024),
('76689','Valley Mills',31.6599,-97.4935),
('76690','Walnut Springs',32.0593,-97.7514),
('76691','West',31.7754,-97.1258),
('76692','Whitney',31.9713,-97.3463),
('76693','Wortham',31.7865,-96.4202),
('76701','Waco',31.5525,-97.1396),
('76702','Waco',31.5475,-97.1443),
('76703','Waco',31.5536,-97.2032),
('76704','Waco',31.5773,-97.1241),
('76705','Waco',31.6403,-97.0963),
('76706','Waco',31.5171,-97.1198),
('76707','Waco',31.5527,-97.1588),
('76708','Waco',31.5765,-97.1786),
('76710','Waco',31.535,-97.1899),
('76711','Waco',31.5175,-97.1547),
('76712','Woodway',31.5051,-97.2311),
('76714','Waco',31.5536,-97.2032),
('76715','Waco',31.5536,-97.2032),
('76716','Waco',31.5536,-97.2032),
('76795','Waco',31.47,-97.24),
('76797','Waco',31.5536,-97.2032),
('76798','Waco',31.547,-97.1203),
('76799','Waco',31.5411,-97.1615),
('76801','Brownwood',31.7754,-98.9915),
('76802','Early',31.7874,-98.9229),
('76803','Brownwood',31.7421,-98.9456),
('76804','Brownwood',31.7742,-99.0921),
('76820','Art',30.767,-99.0486),
('76821','Ballinger',31.7468,-99.9589),
('76823','Bangs',31.7503,-99.1568),
('76824','Bend',31.1123,-98.4821),
('76825','Brady',31.1509,-99.3372),
('76827','Brookesmith',31.5176,-99.1277),
('76828','Burkett',31.9986,-99.2553),
('76831','Castell',30.701,-98.9564),
('76832','Cherokee',30.9806,-98.6633),
('76834','Coleman',31.8287,-99.427),
('76836','Doole',31.3957,-99.599),
('76837','Eden',31.2192,-99.8407),
('76841','Fort Mc Kavett',30.829,-100.0809),
('76842','Fredonia',30.9214,-99.1216),
('76844','Goldthwaite',31.4458,-98.5744),
('76845','Gouldbusk',31.5549,-99.4767),
('76848','Hext',30.8816,-99.554),
('76849','Junction',30.4754,-99.7473),
('76852','Lohn',31.3173,-99.3833),
('76853','Lometa',31.2167,-98.4006),
('76854','London',30.6768,-99.5765),
('76855','Lowake',31.5663,-100.0759),
('76856','Mason',30.7434,-99.2261),
('76857','May',31.9571,-98.9656),
('76858','Melvin',31.1952,-99.5798),
('76859','Menard',30.9119,-99.7847),
('76861','Miles',31.6121,-100.1823),
('76862','Millersview',31.4167,-99.7171),
('76864','Mullin',31.5748,-98.6635),
('76865','Norton',31.8795,-100.1315),
('76866','Paint Rock',31.5048,-99.9139),
('76869','Pontotoc',30.8906,-99.0212),
('76870','Priddy',31.641,-98.5276),
('76871','Richland Springs',31.3003,-98.9128),
('76872','Rochelle',31.3,-99.1572),
('76873','Rockwood',31.5037,-99.3746),
('76874','Roosevelt',30.47,-100.0901),
('76875','Rowena',31.6436,-100.0191),
('76877','San Saba',31.1627,-98.7309),
('76878','Santa Anna',31.7215,-99.3212),
('76880','Star',31.4685,-98.3161),
('76882','Talpa',31.8034,-99.6747),
('76883','Telegraph',30.3274,-99.9062),
('76884','Valera',31.7529,-99.5473),
('76885','Valley Spring',30.866,-98.8357),
('76886','Veribest',31.4766,-100.2595),
('76887','Voca',30.9959,-99.1682),
('76888','Voss',31.5892,-99.6326),
('76890','Zephyr',31.6694,-98.8182),
('76901','San Angelo',31.4782,-100.4818),
('76902','San Angelo',31.4638,-100.437),
('76903','San Angelo',31.4707,-100.4386),
('76904','San Angelo',31.4194,-100.48),
('76905','San Angelo',31.4647,-100.39),
('76906','San Angelo',31.4638,-100.437),
('76908','Goodfellow Afb',31.4321,-100.4022),
('76909','San Angelo',31.4638,-100.437),
('76930','Barnhart',31.1596,-101.1918),
('76932','Big Lake',31.417,-101.5423),
('76933','Bronte',31.8789,-100.2988),
('76934','Carlsbad',31.6266,-100.6694),
('76935','Christoval',31.2346,-100.5203),
('76936','Eldorado',30.8667,-100.5889),
('76937','Eola',31.3617,-100.0922),
('76939','Knickerbocker',31.2501,-100.592),
('76940','Mereta',31.4518,-100.1349),
('76941','Mertzon',31.2829,-100.8221),
('76943','Ozona',30.7164,-101.2388),
('76945','Robert Lee',31.8951,-100.5104),
('76949','Silver',32.0484,-100.6922),
('76950','Sonora',30.5558,-100.6307),
('76951','Sterling City',31.8351,-101.0017),
('76953','Tennyson',31.7397,-100.2884),
('76955','Vancourt',31.3132,-100.1328),
('76957','Wall',31.3741,-100.3076),
('76958','Water Valley',31.6453,-100.716),
('77001','Houston',29.8131,-95.3098),
('77002','Houston',29.7594,-95.3594),
('77003','Houston',29.7489,-95.3391),
('77004','Houston',29.7247,-95.3625),
('77005','Houston',29.7179,-95.4263),
('77006','Houston',29.7409,-95.3923),
('77007','Houston',29.7736,-95.4034),
('77008','Houston',29.7991,-95.4118),
('77009','Houston',29.7936,-95.3675),
('77010','Houston',29.7543,-95.3609),
('77011','Houston',29.742,-95.3073),
('77012','Houston',29.7149,-95.2819),
('77013','Houston',29.7842,-95.2301),
('77014','Houston',29.9796,-95.4625),
('77015','Houston',29.7853,-95.1852),
('77016','Houston',29.8579,-95.3032),
('77017','Houston',29.6863,-95.2555),
('77018','Houston',29.8272,-95.4266),
('77019','Houston',29.7517,-95.4054),
('77020','Houston',29.7758,-95.3121),
('77021','Houston',29.6954,-95.3562),
('77022','Houston',29.8299,-95.3769),
('77023','Houston',29.7242,-95.3178),
('77024','Houston',29.7696,-95.5201),
('77025','Houston',29.6889,-95.4341),
('77026','Houston',29.7972,-95.3288),
('77027','Houston',29.7396,-95.446),
('77028','Houston',29.8297,-95.2879),
('77029','Houston',29.763,-95.2567),
('77030','Houston',29.7041,-95.401),
('77031','Houston',29.6581,-95.5413),
('77032','Houston',29.9368,-95.3299),
('77033','Houston',29.6686,-95.3382),
('77034','Houston',29.6364,-95.2216),
('77035','Houston',29.6518,-95.4854),
('77036','Houston',29.6984,-95.5405),
('77037','Houston',29.8892,-95.3935),
('77038','Houston',29.9196,-95.4386),
('77039','Houston',29.9067,-95.3334),
('77040','Houston',29.8744,-95.5278),
('77041','Houston',29.8602,-95.5817),
('77042','Houston',29.7404,-95.5589),
('77043','Houston',29.8052,-95.5607),
('77044','Houston',29.8635,-95.1976),
('77045','Houston',29.6297,-95.4382),
('77046','Houston',29.733,-95.4306),
('77047','Houston',29.6254,-95.375),
('77048','Houston',29.6321,-95.3416),
('77049','Houston',29.8235,-95.1848),
('77050','Houston',29.9015,-95.2848),
('77051','Houston',29.6579,-95.3688),
('77052','Houston',29.7633,-95.3633),
('77053','Houston',29.5962,-95.4587),
('77054','Houston',29.6852,-95.4017),
('77055','Houston',29.7971,-95.4958),
('77056','Houston',29.7446,-95.4683),
('77057','Houston',29.7422,-95.4903),
('77058','Houston',29.5716,-95.0998),
('77059','Houston',29.5975,-95.1134),
('77060','Houston',29.9335,-95.3981),
('77061','Houston',29.6652,-95.279),
('77062','Houston',29.5721,-95.1303),
('77063','Houston',29.7348,-95.522),
('77064','Houston',29.919,-95.5569),
('77065','Houston',29.9319,-95.6106),
('77066','Houston',29.961,-95.4947),
('77067','Houston',29.9547,-95.4522),
('77068','Houston',30.0069,-95.4897),
('77069','Houston',29.9863,-95.5208),
('77070','Houston',29.9781,-95.5803),
('77071','Houston',29.6518,-95.5176),
('77072','Houston',29.699,-95.5862),
('77073','Houston',30.0198,-95.4087),
('77074','Houston',29.6896,-95.5106),
('77075','Houston',29.6223,-95.26),
('77076','Houston',29.858,-95.3834),
('77077','Houston',29.7477,-95.603),
('77078','Houston',29.8497,-95.2582),
('77079','Houston',29.7738,-95.598),
('77080','Houston',29.8159,-95.523),
('77081','Houston',29.7119,-95.4845),
('77082','Houston',29.7223,-95.6285),
('77083','Houston',29.6947,-95.6511),
('77084','Houston',29.844,-95.6623),
('77085','Houston',29.6218,-95.4819),
('77086','Houston',29.9227,-95.4939),
('77087','Houston',29.6876,-95.3011),
('77088','Houston',29.8817,-95.4539),
('77089','Houston',29.594,-95.2218),
('77090','Houston',30.0167,-95.447),
('77091','Houston',29.8534,-95.4435),
('77092','Houston',29.8324,-95.472),
('77093','Houston',29.8617,-95.3403),
('77094','Houston',29.7705,-95.7107),
('77095','Houston',29.8941,-95.6481),
('77096','Houston',29.6722,-95.4861),
('77097','Houston',29.76,-95.36),
('77098','Houston',29.735,-95.4118),
('77099','Houston',29.6709,-95.5866),
('77201','Houston',29.7633,-95.3633),
('77202','Houston',29.834,-95.4342),
('77203','Houston',29.7633,-95.3633),
('77204','Houston',29.834,-95.4342),
('77205','Houston',29.834,-95.4342),
('77206','Houston',29.834,-95.4342),
('77207','Houston',29.834,-95.4342),
('77208','Houston',29.7633,-95.3633),
('77209','Houston',29.7633,-95.3633),
('77210','Houston',29.7633,-95.3633),
('77212','Houston',29.7633,-95.3633),
('77213','Houston',29.834,-95.4342),
('77215','Houston',29.834,-95.4342),
('77216','Houston',29.834,-95.4342),
('77217','Houston',29.834,-95.4342),
('77218','Houston',29.834,-95.4342),
('77219','Houston',29.834,-95.4342),
('77220','Houston',29.834,-95.4342),
('77221','Houston',29.834,-95.4342),
('77222','Houston',29.834,-95.4342),
('77223','Houston',29.834,-95.4342),
('77224','Houston',29.834,-95.4342),
('77225','Houston',29.834,-95.4342),
('77226','Houston',29.834,-95.4342),
('77227','Houston',29.834,-95.4342),
('77228','Houston',29.834,-95.4342),
('77229','Houston',29.834,-95.4342),
('77230','Houston',29.834,-95.4342),
('77231','Houston',29.834,-95.4342),
('77233','Houston',29.834,-95.4342),
('77234','Houston',29.834,-95.4342),
('77235','Houston',29.834,-95.4342),
('77236','Houston',29.834,-95.4342),
('77237','Houston',29.834,-95.4342),
('77238','Houston',29.834,-95.4342),
('77240','Houston',29.834,-95.4342),
('77241','Houston',29.834,-95.4342),
('77242','Houston',29.834,-95.4342),
('77243','Houston',29.834,-95.4342),
('77244','Houston',29.834,-95.4342),
('77245','Houston',29.834,-95.4342),
('77246','Houston',29.64,-95.43),
('77247','Houston',29.64,-95.43),
('77248','Houston',29.834,-95.4342),
('77249','Houston',29.834,-95.4342),
('77250','Houston',29.7,-95.53),
('77251','Houston',29.834,-95.4342),
('77252','Houston',29.7633,-95.3633),
('77253','Houston',29.7633,-95.3633),
('77254','Houston',29.834,-95.4342),
('77255','Houston',29.834,-95.4342),
('77256','Houston',29.834,-95.4342),
('77257','Houston',29.834,-95.4342),
('77258','Houston',29.834,-95.4342),
('77259','Houston',29.834,-95.4342),
('77260','Houston',29.67,-95.24),
('77261','Houston',29.834,-95.4342),
('77262','Houston',29.834,-95.4342),
('77263','Houston',29.834,-95.4342),
('77265','Houston',29.834,-95.4342),
('77266','Houston',29.834,-95.4342),
('77267','Houston',29.834,-95.4342),
('77268','Houston',29.834,-95.4342),
('77269','Houston',29.834,-95.4342),
('77270','Houston',29.834,-95.4342),
('77271','Houston',29.834,-95.4342),
('77272','Houston',29.834,-95.4342),
('77273','Houston',29.834,-95.4342),
('77274','Houston',29.834,-95.4342),
('77275','Houston',29.834,-95.4342),
('77276','Houston',29.75,-95.36),
('77277','Houston',29.834,-95.4342),
('77278','Houston',29.76,-95.51),
('77279','Houston',29.834,-95.4342),
('77280','Houston',29.834,-95.4342),
('77282','Houston',29.834,-95.4342),
('77284','Houston',29.834,-95.4342),
('77285','Houston',29.75,-95.36),
('77286','Houston',29.67,-95.36),
('77287','Houston',29.834,-95.4342),
('77288','Houston',29.834,-95.4342),
('77289','Houston',29.834,-95.4342),
('77290','Houston',29.834,-95.4342),
('77291','Houston',29.834,-95.4342),
('77292','Houston',29.7443,-95.3326),
('77293','Houston',29.834,-95.4342),
('77294','Houston',29.86,-95.24),
('77296','Houston',29.76,-95.36),
('77297','Houston',29.7633,-95.3633),
('77298','Houston',29.76,-95.36),
('77299','Houston',29.834,-95.4342),
('77301','Conroe',30.3125,-95.4527),
('77302','Conroe',30.2238,-95.3577),
('77303','Conroe',30.3814,-95.3749),
('77304','Conroe',30.3217,-95.5285),
('77305','Conroe',30.2906,-95.3832),
('77306','Conroe',30.2277,-95.2851),
('77315','North Houston',29.834,-95.4342),
('77316','Montgomery',30.3587,-95.6857),
('77318','Willis',30.4416,-95.5394),
('77320','Huntsville',30.847,-95.597),
('77325','Kingwood',30.0569,-95.1835),
('77326','Ace',30.5209,-94.8221),
('77327','Cleveland',30.33,-95.0202),
('77328','Cleveland',30.3963,-95.194),
('77331','Coldspring',30.6027,-95.1086),
('77332','Dallardsville',30.6285,-94.6319),
('77333','Dobbin',30.3365,-95.7723),
('77334','Dodge',30.772,-95.3838),
('77335','Goodrich',30.6079,-94.9592),
('77336','Huffman',30.0565,-95.1051),
('77337','Hufsmith',30.1222,-95.5966),
('77338','Humble',30.0041,-95.2825),
('77339','Kingwood',30.0569,-95.1835),
('77340','Huntsville',30.6448,-95.5798),
('77341','Huntsville',30.7142,-95.5508),
('77342','Huntsville',30.7813,-95.5953),
('77343','Huntsville',30.7235,-95.5508),
('77344','Huntsville',30.7235,-95.5508),
('77345','Kingwood',30.0336,-95.261),
('77346','Humble',30.0042,-95.1728),
('77347','Humble',29.9988,-95.2622),
('77348','Huntsville',30.7235,-95.5508),
('77349','Huntsville',30.7235,-95.5508),
('77350','Leggett',30.8568,-94.8561),
('77351','Livingston',30.6829,-94.8976),
('77353','Magnolia',30.2094,-95.7508),
('77354','Magnolia',30.2333,-95.5502),
('77355','Magnolia',30.1598,-95.7402),
('77356','Montgomery',30.4411,-95.7097),
('77357','New Caney',30.1579,-95.198),
('77358','New Waverly',30.5354,-95.4532),
('77359','Oakhurst',30.7126,-95.3095),
('77360','Onalaska',30.8225,-95.1056),
('77362','Pinehurst',30.1581,-95.6814),
('77363','Plantersville',30.2969,-95.8498),
('77364','Pointblank',30.7593,-95.2295),
('77365','Porter',30.1237,-95.2686),
('77367','Riverside',30.853,-95.4036),
('77368','Romayor',30.4513,-94.8433),
('77369','Rye',30.4596,-94.7436),
('77371','Shepherd',30.498,-94.9966),
('77372','Splendora',30.2326,-95.1993),
('77373','Spring',30.0532,-95.3773),
('77374','Thicket',30.3765,-94.6361),
('77375','Tomball',30.0739,-95.6201),
('77376','Votaw',30.4334,-94.6804),
('77377','Tomball',30.0615,-95.6821),
('77378','Willis',30.4441,-95.4506),
('77379','Spring',30.0377,-95.5326),
('77380','Spring',30.1441,-95.4703),
('77381','Spring',30.1716,-95.4985),
('77382','Spring',30.2106,-95.5257),
('77383','Spring',30.0799,-95.4172),
('77384','Conroe',30.2257,-95.4924),
('77385','Conroe',30.1877,-95.4288),
('77386','Spring',30.1288,-95.4239),
('77387','Spring',30.1199,-95.4247),
('77388','Spring',30.0505,-95.4695),
('77389','Spring',30.1044,-95.5066),
('77391','Spring',30.0799,-95.4172),
('77393','Spring',30.329,-95.4635),
('77396','Humble',29.9507,-95.2622),
('77399','Livingston',30.8179,-94.8691),
('77401','Bellaire',29.7023,-95.4611),
('77402','Bellaire',29.834,-95.4342),
('77404','Bay City',28.9828,-95.9694),
('77406','Richmond',29.6436,-95.798),
('77407','Richmond',29.6625,-95.7272),
('77410','Cypress',29.9691,-95.6972),
('77411','Alief',29.7111,-95.5963),
('77412','Altair',29.5714,-96.4541),
('77413','Barker',29.7844,-95.6849),
('77414','Bay City',28.8636,-95.9173),
('77415','Cedar Lane',28.9386,-95.7366),
('77417','Beasley',29.479,-95.9681),
('77418','Bellville',29.9658,-96.2531),
('77419','Blessing',28.8649,-96.218),
('77420','Boling',29.2529,-95.974),
('77422','Brazoria',29.0236,-95.5867),
('77423','Brookshire',29.8072,-95.9755),
('77426','Chappell Hill',30.1833,-96.2347),
('77428','Collegeport',28.7253,-96.175),
('77429','Cypress',29.9766,-95.6358),
('77430','Damon',29.3014,-95.7036),
('77431','Danciger',29.1737,-95.8207),
('77432','Danevang',29.0575,-96.2075),
('77433','Cypress',29.8836,-95.7025),
('77434','Eagle Lake',29.5842,-96.3354),
('77435','East Bernard',29.4705,-96.1211),
('77436','Egypt',29.405,-96.2369),
('77437','El Campo',29.2008,-96.2743),
('77440','Elmaton',28.8864,-96.14),
('77441','Fulshear',29.7217,-95.8977),
('77442','Garwood',29.476,-96.4919),
('77443','Glen Flora',29.3475,-96.1933),
('77444','Guy',29.3327,-95.7702),
('77445','Hempstead',30.092,-96.0716),
('77446','Prairie View',30.0836,-95.9866),
('77447','Hockley',30.0729,-95.8104),
('77448','Hungerford',29.4137,-96.0929),
('77449','Katy',29.8323,-95.736),
('77450','Katy',29.745,-95.7326),
('77451','Kendleton',29.447,-96.0036),
('77452','Kenney',30.0477,-96.3269),
('77453','Lane City',29.2161,-96.0263),
('77454','Lissie',29.5353,-96.2303),
('77455','Louise',29.1114,-96.4033),
('77456','Markham',28.9547,-96.0928),
('77457','Matagorda',28.6908,-95.9675),
('77458','Midfield',28.9362,-96.2265),
('77459','Missouri City',29.5704,-95.5423),
('77460','Nada',29.405,-96.3864),
('77461','Needville',29.4117,-95.8273),
('77463','Old Ocean',29.08,-95.7497),
('77464','Orchard',29.5948,-95.9727),
('77465','Palacios',28.715,-96.2154),
('77466','Pattison',29.8173,-96.0073),
('77467','Pierce',29.2052,-96.1369),
('77468','Pledger',29.1825,-95.9086),
('77469','Richmond',29.5511,-95.7329),
('77470','Rock Island',29.5311,-96.5752),
('77471','Rosenberg',29.5497,-95.7982),
('77473','San Felipe',29.8019,-96.1014),
('77474','Sealy',29.7826,-96.1592),
('77475','Sheridan',29.4936,-96.6711),
('77476','Simonton',29.6794,-95.9772),
('77477','Stafford',29.6228,-95.5678),
('77478','Sugar Land',29.6196,-95.607),
('77479','Sugar Land',29.5785,-95.6066),
('77480','Sweeny',29.0415,-95.7004),
('77481','Thompsons',29.4683,-95.5776),
('77482','Van Vleck',29.016,-95.8905),
('77483','Wadsworth',28.8259,-95.9046),
('77484','Waller',30.071,-95.9253),
('77485','Wallis',29.6397,-96.0456),
('77486','West Columbia',29.1408,-95.6694),
('77487','Sugar Land',29.6197,-95.6349),
('77488','Wharton',29.3205,-96.0858),
('77489','Missouri City',29.5962,-95.5115),
('77491','Katy',29.7858,-95.8244),
('77492','Katy',29.7858,-95.8244),
('77493','Katy',29.8678,-95.8298),
('77494','Katy',29.7404,-95.8304),
('77496','Sugar Land',29.5255,-95.7565),
('77497','Stafford',29.6161,-95.5577),
('77498','Sugar Land',29.6396,-95.65),
('77501','Pasadena',29.6911,-95.2091),
('77502','Pasadena',29.6789,-95.1982),
('77503','Pasadena',29.6877,-95.1572),
('77504','Pasadena',29.6501,-95.1885),
('77505','Pasadena',29.6518,-95.1464),
('77506','Pasadena',29.7009,-95.1989),
('77507','Pasadena',29.6224,-95.0545),
('77508','Pasadena',29.5699,-95.1066),
('77510','Santa Fe',29.4032,-95.0734),
('77511','Alvin',29.412,-95.2515),
('77512','Alvin',29.4238,-95.2441),
('77514','Anahuac',29.662,-94.593),
('77515','Angleton',29.181,-95.4467),
('77516','Angleton',29.1694,-95.4319),
('77517','Santa Fe',29.3673,-95.1361),
('77518','Bacliff',29.5055,-94.9893),
('77519','Batson',30.225,-94.6096),
('77520','Baytown',29.7461,-94.9653),
('77521','Baytown',29.7705,-94.9695),
('77522','Baytown',29.7355,-94.9774),
('77523','Baytown',29.77,-94.8608),
('77530','Channelview',29.7914,-95.1317),
('77531','Clute',29.0325,-95.4026),
('77532','Crosby',29.9249,-95.0578),
('77533','Daisetta',30.1133,-94.643),
('77534','Danbury',29.2291,-95.3435),
('77535','Dayton',30.0102,-94.8787),
('77536','Deer Park',29.6826,-95.1222),
('77538','Devers',29.9978,-94.5746),
('77539','Dickinson',29.4585,-95.0345),
('77541','Freeport',29.0357,-95.3379),
('77542','Freeport',28.9541,-95.3597),
('77545','Fresno',29.5293,-95.4626),
('77546','Friendswood',29.5224,-95.1879),
('77547','Galena Park',29.7392,-95.24),
('77549','Friendswood',29.5294,-95.201),
('77550','Galveston',29.2983,-94.793),
('77551','Galveston',29.2766,-94.8303),
('77552','Galveston',29.2205,-94.9444),
('77553','Galveston',29.3322,-94.8002),
('77554','Galveston',29.2243,-94.9637),
('77555','Galveston',29.3305,-94.8002),
('77560','Hankamer',29.8752,-94.5938),
('77561','Hardin',30.151,-94.7338),
('77562','Highlands',29.8296,-95.0393),
('77563','Hitchcock',29.3398,-94.9926),
('77564','Hull',30.1463,-94.6424),
('77565','Kemah',29.5236,-95.0276),
('77566','Lake Jackson',29.0393,-95.4401),
('77568','La Marque',29.3676,-94.9742),
('77571','La Porte',29.6884,-95.0513),
('77572','La Porte',29.6658,-95.0194),
('77573','League City',29.5173,-95.0963),
('77574','League City',29.5116,-95.0582),
('77575','Liberty',30.0946,-94.7378),
('77577','Liverpool',29.2667,-95.2889),
('77578','Manvel',29.4694,-95.3503),
('77580','Mont Belvieu',29.8477,-94.8908),
('77581','Pearland',29.5617,-95.2721),
('77582','Raywood',30.0542,-94.6764),
('77583','Rosharon',29.4203,-95.4537),
('77584','Pearland',29.5405,-95.3208),
('77585','Saratoga',30.2841,-94.5294),
('77586','Seabrook',29.5832,-95.037),
('77587','South Houston',29.6601,-95.2258),
('77588','Pearland',29.5127,-95.2542),
('77590','Texas City',29.397,-94.9203),
('77591','Texas City',29.3891,-94.9942),
('77592','Texas City',29.3305,-94.8002),
('77597','Wallisville',29.8591,-94.6759),
('77598','Webster',29.5564,-95.144),
('77611','Bridge City',30.0192,-93.8326),
('77612','Buna',30.4132,-93.9913),
('77613','China',30.0108,-94.363),
('77614','Deweyville',30.2894,-93.7488),
('77615','Evadale',30.3129,-94.0731),
('77616','Fred',30.5678,-94.18),
('77617','Gilchrist',29.523,-94.4755),
('77619','Groves',29.9448,-93.9152),
('77622','Hamshire',29.8668,-94.3187),
('77623','High Island',29.5472,-94.4267),
('77624','Hillister',30.675,-94.3534),
('77625','Kountze',30.3703,-94.3259),
('77626','Mauriceville',30.204,-93.8866),
('77627','Nederland',29.9716,-94.0012),
('77629','Nome',30.0015,-94.4189),
('77630','Orange',30.0709,-93.8659),
('77631','Orange',30.093,-93.7366),
('77632','Orange',30.1775,-93.8409),
('77639','Orangefield',30.0631,-93.8599),
('77640','Port Arthur',29.8709,-93.9643),
('77641','Port Arthur',29.8476,-94.1297),
('77642','Port Arthur',29.9212,-93.927),
('77643','Port Arthur',29.9621,-93.8679),
('77650','Port Bolivar',29.4266,-94.6861),
('77651','Port Neches',29.977,-93.9626),
('77655','Sabine Pass',29.7336,-93.8943),
('77656','Silsbee',30.3244,-94.1907),
('77657','Lumberton',30.2818,-94.2191),
('77659','Sour Lake',30.1491,-94.3733),
('77660','Spurger',30.6387,-94.1663),
('77661','Stowell',29.7809,-94.39),
('77662','Vidor',30.1502,-94.0008),
('77663','Village Mills',30.5185,-94.4458),
('77664','Warren',30.5978,-94.412),
('77665','Winnie',29.8157,-94.3395),
('77670','Vidor',30.1316,-94.0155),
('77701','Beaumont',30.0688,-94.1039),
('77702','Beaumont',30.0871,-94.1254),
('77703','Beaumont',30.1132,-94.1197),
('77704','Beaumont',30.1236,-94.1539),
('77705','Beaumont',30.0211,-94.1157),
('77706','Beaumont',30.0948,-94.1648),
('77707','Beaumont',30.0686,-94.1755),
('77708','Beaumont',30.14,-94.1604),
('77709','Beaumont',30.14,-94.14),
('77710','Beaumont',30.086,-94.1018),
('77713','Beaumont',30.085,-94.2607),
('77720','Beaumont',30.086,-94.1018),
('77725','Beaumont',30.086,-94.1018),
('77726','Beaumont',30.1118,-94.1901),
('77801','Bryan',30.6327,-96.3662),
('77802','Bryan',30.6582,-96.3351),
('77803','Bryan',30.6913,-96.3714),
('77805','Bryan',30.6521,-96.341),
('77806','Bryan',30.6744,-96.37),
('77807','Bryan',30.6711,-96.4799),
('77808','Bryan',30.8202,-96.3059),
('77830','Anderson',30.5443,-96.0018),
('77831','Bedias',30.7065,-95.9546),
('77833','Brenham',30.1774,-96.4028),
('77834','Brenham',30.1669,-96.3977),
('77835','Burton',30.1767,-96.5925),
('77836','Caldwell',30.5298,-96.7143),
('77837','Calvert',30.9782,-96.6711),
('77838','Chriesman',30.5994,-96.7708),
('77840','College Station',30.6045,-96.3123),
('77841','College Station',30.5726,-96.327),
('77842','College Station',30.6521,-96.341),
('77843','College Station',30.6521,-96.341),
('77844','College Station',30.6521,-96.341),
('77845','College Station',30.5118,-96.3171),
('77850','Concord',31.3138,-95.9935),
('77852','Deanville',30.4322,-96.7561),
('77853','Dime Box',30.3579,-96.8248),
('77855','Flynn',31.1593,-96.1234),
('77856','Franklin',31.0001,-96.5171),
('77857','Gause',30.7833,-96.7237),
('77859','Hearne',30.8669,-96.5843),
('77861','Iola',30.7326,-96.0911),
('77862','Kurten',30.7871,-96.2641),
('77863','Lyons',30.3863,-96.5633),
('77864','Madisonville',30.9533,-95.9091),
('77865','Marquez',31.2309,-96.2375),
('77866','Millican',30.4491,-96.217),
('77867','Mumford',30.7344,-96.565),
('77868','Navasota',30.3576,-96.0594),
('77869','Texas Dept Of Correction',30.35,-96.06),
('77870','New Baden',31.051,-96.4291),
('77871','Normangee',31.0705,-96.125),
('77872','North Zulch',30.9285,-96.0925),
('77873','Richards',30.5796,-95.8959),
('77875','Roans Prairie',30.6075,-95.9579),
('77876','Shiro',30.6133,-95.8883),
('77878','Snook',30.4702,-96.4804),
('77879','Somerville',30.4076,-96.5358),
('77880','Washington',30.3182,-96.2249),
('77881','Wellborn',30.5334,-96.3032),
('77882','Wheelock',30.8977,-96.39),
('77901','Victoria',28.809,-96.9993),
('77902','Victoria',28.9255,-97.1006),
('77903','Victoria',28.8053,-97.0036),
('77904','Victoria',28.8675,-96.999),
('77905','Victoria',28.7525,-97.0338),
('77950','Austwell',28.4023,-96.853),
('77951','Bloomington',28.6495,-96.8945),
('77954','Cuero',29.091,-97.2812),
('77957','Edna',28.9527,-96.6488),
('77960','Fannin',28.6955,-97.2358),
('77961','Francitas',28.8597,-96.3386),
('77962','Ganado',29.0308,-96.5031),
('77963','Goliad',28.6993,-97.3783),
('77964','Hallettsville',29.4426,-96.9234),
('77967','Hochheim',29.3125,-97.2917),
('77968','Inez',28.8994,-96.8003),
('77969','La Salle',28.7671,-96.6492),
('77970','La Ward',28.8439,-96.4641),
('77971','Lolita',28.7724,-96.4793),
('77973','Mcfaddin',28.5511,-97.0099),
('77974','Meyersville',28.9229,-97.3042),
('77975','Moulton',29.57,-97.1031),
('77976','Nursery',28.9543,-97.0906),
('77977','Placedo',28.6923,-96.8254),
('77978','Point Comfort',28.6651,-96.5506),
('77979','Port Lavaca',28.6011,-96.6259),
('77982','Port O Connor',28.4483,-96.4058),
('77983','Seadrift',28.4101,-96.7023),
('77984','Shiner',29.428,-97.164),
('77986','Sublime',29.4876,-96.7946),
('77987','Sweet Home',29.3426,-97.0756),
('77988','Telferner',28.8489,-96.8905),
('77989','Thomaston',28.9974,-97.1539),
('77990','Tivoli',28.4587,-96.8928),
('77991','Vanderbilt',28.8068,-96.6042),
('77993','Weesatche',28.8472,-97.448),
('77994','Westhoff',29.1792,-97.46),
('77995','Yoakum',29.284,-97.1306),
('78001','Artesia Wells',28.2639,-99.2802),
('78002','Atascosa',29.2705,-98.7421),
('78003','Bandera',29.7276,-99.0453),
('78004','Bergheim',29.8274,-98.5753),
('78005','Bigfoot',29.0531,-98.8582),
('78006','Boerne',29.8931,-98.6857),
('78007','Calliham',28.4805,-98.3503),
('78008','Campbellton',28.767,-98.2566),
('78009','Castroville',29.3553,-98.8824),
('78010','Center Point',29.9441,-99.0364),
('78011','Charlotte',28.8649,-98.707),
('78012','Christine',28.7858,-98.4886),
('78013','Comfort',29.9677,-98.905),
('78014','Cotulla',28.4398,-99.2328),
('78015','Boerne',29.7327,-98.6646),
('78016','Devine',29.1521,-98.909),
('78017','Dilley',28.6782,-99.1747),
('78019','Encinal',28.0405,-99.3563),
('78021','Fowlerton',28.4887,-98.8518),
('78022','George West',28.3204,-98.1162),
('78023','Helotes',29.6321,-98.7542),
('78024','Hunt',30.0027,-99.4823),
('78025','Ingram',30.0731,-99.269),
('78026','Jourdanton',28.903,-98.544),
('78027','Kendalia',29.9406,-98.5166),
('78028','Kerrville',30.0416,-99.1408),
('78029','Kerrville',30.0332,-99.141),
('78039','La Coste',29.3082,-98.8125),
('78040','Laredo',27.5155,-99.4986),
('78041','Laredo',27.5569,-99.4907),
('78042','Laredo',27.5655,-99.4768),
('78043','Laredo',27.5879,-99.2176),
('78044','Laredo',27.3637,-99.4819),
('78045','Laredo',27.6357,-99.5923),
('78046','Laredo',27.4047,-99.4743),
('78049','Laredo',27.53,-99.48),
('78050','Leming',29.073,-98.4842),
('78052','Lytle',29.2366,-98.7945),
('78054','Macdona',29.3258,-98.6911),
('78055','Medina',29.8475,-99.3215),
('78056','Mico',29.5441,-98.9231),
('78057','Moore',29.0595,-99.0204),
('78058','Mountain Home',30.1725,-99.485),
('78059','Natalia',29.2117,-98.8552),
('78060','Oakville',28.4492,-98.1019),
('78061','Pearsall',28.8923,-99.0944),
('78062','Peggy',28.7397,-98.1786),
('78063','Pipe Creek',29.6796,-98.9484),
('78064','Pleasanton',28.9924,-98.4831),
('78065','Poteet',29.0994,-98.6241),
('78066','Rio Medina',29.4612,-98.8694),
('78067','San Ygnacio',27.0425,-99.44),
('78069','Somerset',29.2205,-98.6678),
('78070','Spring Branch',29.9238,-98.3788),
('78071','Three Rivers',28.4756,-98.1782),
('78072','Tilden',28.4198,-98.5693),
('78073','Von Ormy',29.275,-98.6677),
('78074','Waring',29.9523,-98.7944),
('78075','Whitsett',28.6373,-98.2565),
('78076','Zapata',26.8897,-99.2506),
('78101','Adkins',29.3805,-98.265),
('78102','Beeville',28.4222,-97.7616),
('78104','Beeville',28.3931,-97.776),
('78107','Berclair',28.5295,-97.5925),
('78108','Cibolo',29.575,-98.228),
('78109','Converse',29.5173,-98.3217),
('78111','Ecleto',29.0464,-97.7514),
('78112','Elmendorf',29.2308,-98.372),
('78113','Falls City',28.9814,-98.0156),
('78114','Floresville',29.1693,-98.1936),
('78115','Geronimo',29.5451,-98.0408),
('78116','Gillett',29.0514,-97.8343),
('78117','Hobson',28.9445,-97.9707),
('78118','Karnes City',28.8828,-97.9071),
('78119','Kenedy',28.8046,-97.8456),
('78121','La Vernia',29.3509,-98.113),
('78122','Leesville',29.3961,-97.7566),
('78123','Mc Queeney',29.6023,-98.0492),
('78124','Marion',29.5683,-98.1517),
('78125','Mineral',28.5552,-97.9407),
('78130','New Braunfels',29.7229,-98.0742),
('78131','New Braunfels',29.703,-98.1245),
('78132','New Braunfels',29.7565,-98.1983),
('78133','Canyon Lake',29.9112,-98.2374),
('78135','New Braunfels',29.703,-98.1245),
('78140','Nixon',29.3016,-97.7529),
('78141','Nordheim',28.9142,-97.5946),
('78142','Normanna',28.5278,-97.7831),
('78143','Pandora',29.2484,-97.8287),
('78144','Panna Maria',28.9562,-97.8982),
('78145','Pawnee',28.6526,-97.9921),
('78146','Pettus',28.6164,-97.8082),
('78147','Poth',29.0619,-98.0825),
('78148','Universal City',29.5465,-98.2954),
('78150','Randolph A F B',29.3759,-97.958),
('78151','Runge',28.8876,-97.7138),
('78152','Saint Hedwig',29.4353,-98.1952),
('78154','Schertz',29.579,-98.2778),
('78155','Seguin',29.5613,-97.9628),
('78156','Seguin',29.6118,-97.9712),
('78159','Smiley',29.2655,-97.6227),
('78160','Stockdale',29.2319,-97.9351),
('78161','Sutherland Springs',29.2888,-98.0509),
('78162','Tuleta',28.5708,-97.7972),
('78163','Bulverde',29.7767,-98.4626),
('78164','Yorktown',28.9892,-97.5121),
('78201','San Antonio',29.4711,-98.5356),
('78202','San Antonio',29.4275,-98.4601),
('78203','San Antonio',29.4148,-98.4601),
('78204','San Antonio',29.4059,-98.5078),
('78205','San Antonio',29.4237,-98.4925),
('78206','San Antonio',29.4375,-98.4616),
('78207','San Antonio',29.4229,-98.526),
('78208','San Antonio',29.44,-98.459),
('78209','San Antonio',29.4821,-98.4554),
('78210','San Antonio',29.3977,-98.4658),
('78211','San Antonio',29.3499,-98.5638),
('78212','San Antonio',29.4388,-98.4935),
('78213','San Antonio',29.5234,-98.5273),
('78214','San Antonio',29.3641,-98.4924),
('78215','San Antonio',29.4413,-98.4793),
('78216','San Antonio',29.5334,-98.4975),
('78217','San Antonio',29.5395,-98.4194),
('78218','San Antonio',29.4969,-98.4032),
('78219','San Antonio',29.4492,-98.3446),
('78220','San Antonio',29.4106,-98.4128),
('78221','San Antonio',29.3309,-98.5054),
('78222','San Antonio',29.3831,-98.396),
('78223','San Antonio',29.3579,-98.4356),
('78224','San Antonio',29.3374,-98.5393),
('78225','San Antonio',29.3875,-98.5245),
('78226','San Antonio',29.393,-98.5511),
('78227','San Antonio',29.4027,-98.6433),
('78228','San Antonio',29.4589,-98.5699),
('78229','San Antonio',29.5042,-98.5697),
('78230','San Antonio',29.5407,-98.5521),
('78231','San Antonio',29.5714,-98.5414),
('78232','San Antonio',29.5863,-98.4769),
('78233','San Antonio',29.5563,-98.3643),
('78234','San Antonio',29.4241,-98.4936),
('78235','San Antonio',29.3494,-98.4422),
('78236','Lackland A F B',29.4241,-98.4936),
('78237','San Antonio',29.4208,-98.5645),
('78238','San Antonio',29.451,-98.6169),
('78239','San Antonio',29.5182,-98.3627),
('78240','San Antonio',29.5189,-98.6006),
('78241','San Antonio',29.4375,-98.4616),
('78242','San Antonio',29.3509,-98.6109),
('78243','San Antonio',29.4375,-98.4616),
('78244','San Antonio',29.4793,-98.3476),
('78245','San Antonio',29.4189,-98.6895),
('78246','San Antonio',29.4375,-98.4616),
('78247','San Antonio',29.5855,-98.4071),
('78248','San Antonio',29.5894,-98.5201),
('78249','San Antonio',29.5612,-98.6117),
('78250','San Antonio',29.5054,-98.6688),
('78251','San Antonio',29.4597,-98.6555),
('78252','San Antonio',29.346,-98.6464),
('78253','San Antonio',29.4599,-98.7479),
('78254','San Antonio',29.5551,-98.7442),
('78255','San Antonio',29.6701,-98.6873),
('78256','San Antonio',29.6169,-98.6252),
('78257','San Antonio',29.6495,-98.6137),
('78258','San Antonio',29.6562,-98.4967),
('78259','San Antonio',29.6283,-98.4445),
('78260','San Antonio',29.7026,-98.4759),
('78261','San Antonio',29.7055,-98.4191),
('78262','Kelly Usa',29.42,-98.49),
('78263','San Antonio',29.3614,-98.3174),
('78264','San Antonio',29.1733,-98.4723),
('78265','San Antonio',29.4375,-98.4616),
('78266','San Antonio',29.6643,-98.3118),
('78268','San Antonio',29.4375,-98.4616),
('78269','San Antonio',29.4375,-98.4616),
('78270','San Antonio',29.4375,-98.4616),
('78275','Alliance Data Systems',29.53,-98.42),
('78278','San Antonio',29.4375,-98.4616),
('78279','San Antonio',29.4375,-98.4616),
('78280','San Antonio',29.4375,-98.4616),
('78283','San Antonio',29.4375,-98.4616),
('78284','San Antonio',29.4426,-98.4913),
('78285','San Antonio',29.4375,-98.4616),
('78286','San Antonio',29.42,-98.49),
('78287','San Antonio',29.45,-98.5),
('78288','San Antonio',29.4241,-98.4936),
('78289','San Antonio',29.4375,-98.4616),
('78291','San Antonio',29.4375,-98.4616),
('78292','San Antonio',29.4375,-98.4616),
('78293','San Antonio',29.4375,-98.4616),
('78294','San Antonio',29.4375,-98.4616),
('78295','San Antonio',29.4375,-98.4616),
('78296','San Antonio',29.4375,-98.4616),
('78297','San Antonio',29.4375,-98.4616),
('78298','San Antonio',29.4375,-98.4616),
('78299','San Antonio',29.4375,-98.4616),
('78330','Agua Dulce',27.7817,-97.9086),
('78332','Alice',27.7432,-98.0836),
('78333','Alice',27.7522,-98.0697),
('78335','Aransas Pass',27.9125,-97.1884),
('78336','Aransas Pass',27.9095,-97.1591),
('78338','Armstrong',26.8698,-97.7698),
('78339','Banquete',27.8051,-97.7922),
('78340','Bayside',28.0968,-97.2106),
('78341','Benavides',27.5925,-98.4142),
('78342','Ben Bolt',27.6475,-98.0814),
('78343','Bishop',27.5886,-97.783),
('78344','Bruni',27.4295,-98.8385),
('78347','Chapman Ranch',27.5988,-97.462),
('78349','Concepcion',27.3849,-98.309),
('78350','Dinero',28.2264,-97.9617),
('78351','Driscoll',27.6745,-97.7486),
('78352','Edroy',27.9736,-97.6761),
('78353','Encino',26.9249,-98.1922),
('78355','Falfurrias',27.2242,-98.1408),
('78357','Freer',27.88,-98.6061),
('78358','Fulton',28.0614,-97.0411),
('78359','Gregory',27.9222,-97.29),
('78360','Guerra',26.8831,-98.8936),
('78361','Hebbronville',27.2997,-98.6829),
('78362','Ingleside',27.8682,-97.2069),
('78363','Kingsville',27.4229,-97.8407),
('78364','Kingsville',27.5159,-97.8561),
('78368','Mathis',28.0802,-97.8097),
('78369','Mirando City',27.445,-99.0011),
('78370','Odem',27.9403,-97.5838),
('78371','Oilton',27.4685,-98.9586),
('78372','Orange Grove',27.9487,-97.9838),
('78373','Port Aransas',27.7707,-97.1051),
('78374','Portland',27.8935,-97.3169),
('78375','Premont',27.3544,-98.133),
('78376','Realitos',27.4184,-98.514),
('78377','Refugio',28.3169,-97.2767),
('78379','Riviera',27.3217,-97.7787),
('78380','Robstown',27.7984,-97.6995),
('78381','Rockport',28.0131,-97.0936),
('78382','Rockport',28.0308,-97.0688),
('78383','Sandia',28.025,-97.8705),
('78384','San Diego',27.7654,-98.2503),
('78385','Sarita',27.1496,-97.8576),
('78387','Sinton',28.0339,-97.5196),
('78389','Skidmore',28.2121,-97.7127),
('78390','Taft',27.9765,-97.3966),
('78391','Tynan',28.1693,-97.7549),
('78393','Woodsboro',28.2232,-97.3192),
('78401','Corpus Christi',27.7941,-97.403),
('78402','Corpus Christi',27.8262,-97.3857),
('78403','Corpus Christi',27.777,-97.4632),
('78404','Corpus Christi',27.7683,-97.4013),
('78405','Corpus Christi',27.7762,-97.4271),
('78406','Corpus Christi',27.7684,-97.5144),
('78407','Corpus Christi',27.8042,-97.4356),
('78408','Corpus Christi',27.7945,-97.4381),
('78409','Corpus Christi',27.8146,-97.527),
('78410','Corpus Christi',27.8458,-97.596),
('78411','Corpus Christi',27.7311,-97.3877),
('78412','Corpus Christi',27.7061,-97.3537),
('78413','Corpus Christi',27.691,-97.3983),
('78414','Corpus Christi',27.677,-97.365),
('78415','Corpus Christi',27.7262,-97.4078),
('78416','Corpus Christi',27.7536,-97.4347),
('78417','Corpus Christi',27.729,-97.4494),
('78418','Corpus Christi',27.6349,-97.3103),
('78419','Corpus Christi',27.6952,-97.2694),
('78426','Corpus Christi',27.777,-97.4632),
('78427','Corpus Christi',27.8006,-97.3964),
('78460','Corpus Christi',27.8006,-97.3964),
('78461','Crp Christi',27.79,-97.42),
('78463','Corpus Christi',27.777,-97.4632),
('78465','Corpus Christi',27.777,-97.4632),
('78466','Corpus Christi',27.777,-97.4632),
('78467','Corpus Christi',27.777,-97.4632),
('78468','Corpus Christi',27.777,-97.4632),
('78469','Corpus Christi',27.777,-97.4632),
('78470','Corpus Christi',27.8,-97.39),
('78471','Corpus Christi',27.8,-97.39),
('78472','Corpus Christi',27.7402,-97.5792),
('78473','Corpus Christi',27.79,-97.39),
('78474','Corpus Christi',27.8,-97.39),
('78475','Corpus Christi',27.79,-97.39),
('78476','Corpus Christi',27.8,-97.39),
('78477','Corpus Christi',27.8,-97.39),
('78478','Crp Christi',27.79,-97.39),
('78480','Corpus Christi',27.777,-97.4632),
('78501','Mcallen',26.2154,-98.2359),
('78502','Mcallen',26.2567,-98.1989),
('78503','Mcallen',26.1771,-98.252),
('78504','Mcallen',26.2556,-98.2303),
('78505','Mcallen',26.2034,-98.23),
('78516','Alamo',26.1906,-98.1164),
('78520','Brownsville',25.9337,-97.5174),
('78521','Brownsville',25.9221,-97.4612),
('78522','Brownsville',25.9017,-97.4975),
('78523','Brownsville',25.981,-97.5209),
('78526','Brownsville',25.9717,-97.4699),
('78535','Combes',26.2451,-97.7416),
('78536','Delmita',26.6801,-98.4125),
('78537','Donna',26.1671,-98.0529),
('78538','Edcouch',26.3328,-97.9622),
('78539','Edinburg',26.2792,-98.1832),
('78540','Edinburg',26.3017,-98.1633),
('78541','Edinburg',26.4481,-98.2842),
('78542','Edinburg',26.4661,-98.0695),
('78543','Elsa',26.2974,-97.9884),
('78545','Falcon Heights',26.562,-99.1335),
('78547','Garciasville',26.3396,-98.6876),
('78548','Grulla',26.2897,-98.6479),
('78549','Hargill',26.4671,-98.0393),
('78550','Harlingen',26.1951,-97.689),
('78551','Harlingen',26.2447,-97.7206),
('78552','Harlingen',26.1831,-97.7468),
('78553','Harlingen',26.1906,-97.6961),
('78557','Hidalgo',26.1028,-98.2536),
('78558','La Blanca',26.2928,-98.0378),
('78559','La Feria',26.1666,-97.8261),
('78560','La Joya',26.2426,-98.4747),
('78561','Lasara',26.4648,-97.9111),
('78562','La Villa',26.2999,-97.9247),
('78563','Linn',26.6279,-98.2498),
('78564','Lopeno',26.7114,-99.11),
('78565','Los Ebanos',26.2434,-98.5617),
('78566','Los Fresnos',26.1158,-97.4107),
('78567','Los Indios',26.0492,-97.745),
('78568','Lozano',26.1904,-97.5423),
('78569','Lyford',26.4089,-97.7817),
('78570','Mercedes',26.1513,-97.9185),
('78572','Mission',26.2159,-98.3253),
('78573','Mission',26.2937,-98.3008),
('78574','Mission',26.3189,-98.3701),
('78575','Olmito',26.0353,-97.5496),
('78576','Penitas',26.278,-98.4469),
('78577','Pharr',26.1771,-98.187),
('78578','Port Isabel',26.0539,-97.3125),
('78579','Progreso',26.0922,-97.9533),
('78580','Raymondville',26.4792,-97.7967),
('78582','Rio Grande City',26.3942,-98.8104),
('78583','Rio Hondo',26.2339,-97.5513),
('78584','Roma',26.4215,-99.0025),
('78585','Salineno',26.5164,-99.1123),
('78586','San Benito',26.1337,-97.6447),
('78588','San Isidro',26.7167,-98.4539),
('78589','San Juan',26.2044,-98.1537),
('78590','San Perlita',26.5012,-97.6397),
('78591','Santa Elena',26.5808,-98.5138),
('78592','Santa Maria',26.0787,-97.8494),
('78593','Santa Rosa',26.2555,-97.8257),
('78594','Sebastian',26.344,-97.8123),
('78595','Sullivan City',26.272,-98.5627),
('78596','Weslaco',26.1694,-97.9887),
('78597','South Padre Island',26.2393,-97.1936),
('78598','Port Mansfield',26.5548,-97.425),
('78599','Weslaco',26.1595,-97.9908),
('78602','Bastrop',30.1388,-97.2921),
('78604','Belmont',29.5233,-97.6839),
('78605','Bertram',30.7411,-98.0529),
('78606','Blanco',30.0874,-98.4107),
('78607','Bluffton',30.8256,-98.515),
('78608','Briggs',30.9325,-97.9702),
('78609','Buchanan Dam',30.7538,-98.4295),
('78610','Buda',30.0918,-97.8534),
('78611','Burnet',30.7766,-98.2642),
('78612','Cedar Creek',30.0966,-97.4976),
('78613','Cedar Park',30.5052,-97.8203),
('78614','Cost',29.4321,-97.5531),
('78615','Coupland',30.4872,-97.3676),
('78616','Dale',29.9528,-97.581),
('78617','Del Valle',30.1745,-97.6134),
('78618','Doss',30.4613,-99.1707),
('78619','Driftwood',30.1072,-98.0327),
('78620','Dripping Springs',30.2268,-98.1029),
('78621','Elgin',30.3231,-97.3737),
('78622','Fentress',29.7561,-97.7764),
('78623','Fischer',29.9627,-98.2088),
('78624','Fredericksburg',30.2817,-98.8799),
('78626','Georgetown',30.633,-97.6707),
('78627','Georgetown',30.6327,-97.6772),
('78628','Georgetown',30.6411,-97.7511),
('78629','Gonzales',29.5086,-97.4495),
('78630','Cedar Park',30.5052,-97.8203),
('78631','Harper',30.2816,-99.241),
('78632','Harwood',29.6661,-97.4906),
('78633','Georgetown',30.7177,-97.7543),
('78634','Hutto',30.5257,-97.5672),
('78635','Hye',30.2269,-98.5396),
('78636','Johnson City',30.2948,-98.3691),
('78638','Kingsbury',29.6726,-97.8306),
('78639','Kingsland',30.6662,-98.4475),
('78640','Kyle',29.9966,-97.8335),
('78641','Leander',30.5835,-97.8575),
('78642','Liberty Hill',30.663,-97.9316),
('78643','Llano',30.7151,-98.6109),
('78644','Lockhart',29.8868,-97.6769),
('78645','Leander',30.449,-97.9669),
('78646','Leander',30.5788,-97.8531),
('78648','Luling',29.6826,-97.6499),
('78650','Mc Dade',30.2968,-97.2386),
('78651','Mc Neil',30.3264,-97.7713),
('78652','Manchaca',30.1238,-97.8393),
('78653','Manor',30.3388,-97.5323),
('78654','Marble Falls',30.5784,-98.2751),
('78655','Martindale',29.8394,-97.8508),
('78656','Maxwell',29.8953,-97.8144),
('78657','Horseshoe Bay',30.5443,-98.3739),
('78658','Ottine',29.5952,-97.5911),
('78659','Paige',30.1858,-97.1198),
('78660','Pflugerville',30.4421,-97.6299),
('78661','Prairie Lea',29.7239,-97.7449),
('78662','Red Rock',29.9906,-97.4081),
('78663','Round Mountain',30.4429,-98.4365),
('78664','Round Rock',30.5145,-97.668),
('78665','Round Rock',30.5145,-97.668),
('78666','San Marcos',29.8754,-97.9404),
('78667','San Marcos',30.0544,-98.0036),
('78669','Spicewood',30.3899,-98.0539),
('78670','Staples',29.7706,-97.8186),
('78671','Stonewall',30.2088,-98.6131),
('78672','Tow',30.8609,-98.4596),
('78673','Walburg',30.7415,-97.5891),
('78674','Weir',30.6747,-97.5929),
('78675','Willow City',30.4549,-98.6646),
('78676','Wimberley',30.0265,-98.1123),
('78677','Wrightsboro',29.3739,-97.565),
('78680','Round Rock',30.6568,-97.6026),
('78681','Round Rock',30.5083,-97.6789),
('78682','Round Rock',30.6568,-97.6026),
('78683','Round Rock',30.6568,-97.6026),
('78691','Pflugerville',30.4394,-97.62),
('78701','Austin',30.2713,-97.7426),
('78702','Austin',30.2638,-97.7166),
('78703','Austin',30.2907,-97.7648),
('78704','Austin',30.2428,-97.7658),
('78705','Austin',30.2896,-97.7396),
('78708','Austin',30.3264,-97.7713),
('78709','Austin',30.3264,-97.7713),
('78710','Austin',30.352,-97.7151),
('78711','Austin',30.3264,-97.7713),
('78712','Austin',30.2852,-97.7354),
('78713','Austin',30.2672,-97.7431),
('78714','Austin',30.2672,-97.7431),
('78715','Austin',30.2672,-97.7431),
('78716','Austin',30.3162,-97.8588),
('78717','Austin',30.506,-97.7472),
('78718','Austin',30.3264,-97.7713),
('78719','Austin',30.1802,-97.6667),
('78720','Austin',30.3264,-97.7713),
('78721','Austin',30.2721,-97.6868),
('78722','Austin',30.2893,-97.715),
('78723','Austin',30.3085,-97.6849),
('78724','Austin',30.296,-97.6396),
('78725','Austin',30.2562,-97.6243),
('78726','Austin',30.43,-97.8326),
('78727','Austin',30.4254,-97.7195),
('78728','Austin',30.4417,-97.6811),
('78729','Austin',30.4521,-97.7688),
('78730','Austin',30.3607,-97.8241),
('78731','Austin',30.3471,-97.7609),
('78732','Austin',30.3752,-97.9007),
('78733','Austin',30.3314,-97.8666),
('78734','Austin',30.3705,-97.9427),
('78735','Austin',30.249,-97.8414),
('78736','Austin',30.2444,-97.916),
('78737','Austin',30.2107,-97.9427),
('78738','Austin',30.3337,-97.9824),
('78739','Austin',30.172,-97.8784),
('78741','Austin',30.2315,-97.7223),
('78742','Austin',30.2313,-97.6703),
('78744','Austin',30.1876,-97.7472),
('78745','Austin',30.2063,-97.7956),
('78746','Austin',30.2971,-97.8181),
('78747','Austin',30.1204,-97.7433),
('78748','Austin',30.1743,-97.8225),
('78749','Austin',30.2166,-97.8508),
('78750','Austin',30.4224,-97.7967),
('78751','Austin',30.3093,-97.7242),
('78752','Austin',30.3316,-97.7004),
('78753','Austin',30.3649,-97.6827),
('78754','Austin',30.3423,-97.6673),
('78755','Austin',30.3264,-97.7713),
('78756','Austin',30.3223,-97.739),
('78757','Austin',30.3437,-97.7316),
('78758','Austin',30.3764,-97.7078),
('78759','Austin',30.4036,-97.7526),
('78760','Austin',30.3264,-97.7713),
('78761','Austin',30.3264,-97.7713),
('78762','Austin',30.3264,-97.7713),
('78763','Austin',30.3354,-97.5598),
('78764','Austin',30.4455,-97.6595),
('78765','Austin',30.3264,-97.7713),
('78766','Austin',30.2672,-97.7431),
('78767','Austin',30.2672,-97.7431),
('78768','Austin',30.2672,-97.7431),
('78769','Austin',30.3264,-97.7713),
('78772','Austin',30.3264,-97.7713),
('78773','Austin',30.3264,-97.7713),
('78774','Austin',30.3264,-97.7713),
('78778','Austin',30.3264,-97.7713),
('78779','Austin',30.3264,-97.7713),
('78780','Austin',30.26,-97.74),
('78781','Austin',30.26,-97.74),
('78783','Austin',30.3264,-97.7713),
('78785','Austin',30.26,-97.74),
('78786','State Board Of Insurance',30.35,-97.65),
('78788','Austin',30.26,-97.74),
('78789','Austin',30.26,-97.74),
('78798','Austin',30.37,-97.68),
('78799','Austin',30.2672,-97.7431),
('78801','Uvalde',29.2172,-99.7931),
('78802','Uvalde',29.2237,-99.7794),
('78827','Asherton',28.4364,-99.7486),
('78828','Barksdale',29.8282,-100.105),
('78829','Batesville',28.9286,-99.6115),
('78830','Big Wells',28.5693,-99.5781),
('78832','Brackettville',29.3096,-100.4155),
('78833','Camp Wood',29.6795,-100.0084),
('78834','Carrizo Springs',28.5278,-99.8635),
('78836','Catarina',28.3598,-99.586),
('78837','Comstock',29.7484,-101.2628),
('78838','Concan',29.4952,-99.7126),
('78839','Crystal City',28.687,-99.8264),
('78840','Del Rio',29.4102,-100.8932),
('78841','Del Rio',29.3465,-100.9289),
('78842','Del Rio',29.412,-100.9342),
('78843','Laughlin A F B',29.3627,-100.8968),
('78847','Del Rio',29.3627,-100.8968),
('78850','D Hanis',29.3398,-99.2835),
('78851','Dryden',30.0446,-102.1146),
('78852','Eagle Pass',28.7028,-100.4818),
('78853','Eagle Pass',28.679,-100.4784),
('78860','El Indio',28.5119,-100.3112),
('78861','Hondo',29.3475,-99.1414),
('78870','Knippa',29.2911,-99.6372),
('78871','Langtry',29.8085,-101.5587),
('78872','La Pryor',28.9488,-99.8507),
('78873','Leakey',29.769,-99.7479),
('78877','Quemado',28.9256,-100.5912),
('78879','Rio Frio',29.6495,-99.7165),
('78880','Rocksprings',30.0188,-100.231),
('78881','Sabinal',29.3267,-99.4781),
('78883','Tarpley',29.6455,-99.2469),
('78884','Utopia',29.5972,-99.5585),
('78885','Vanderpool',29.7452,-99.5551),
('78886','Yancey',29.1404,-99.1428),
('78931','Bleiblerville',30.0292,-96.4448),
('78932','Carmine',30.1404,-96.6861),
('78933','Cat Spring',29.7512,-96.39),
('78934','Columbus',29.7032,-96.5527),
('78935','Alleyton',29.7092,-96.4865),
('78938','Ellinger',29.8459,-96.6966),
('78940','Fayetteville',29.8868,-96.6463),
('78941','Flatonia',29.7095,-97.0987),
('78942','Giddings',30.1777,-96.9332),
('78943','Glidden',29.6994,-96.5942),
('78944','Industry',29.9904,-96.4843),
('78945','La Grange',29.904,-96.886),
('78946','Ledbetter',30.2383,-96.7613),
('78947','Lexington',30.4191,-97.0524),
('78948','Lincoln',30.3177,-96.9702),
('78949','Muldoon',29.7993,-97.1006),
('78950','New Ulm',29.9134,-96.4961),
('78951','Oakland',29.6016,-96.83),
('78952','Plum',29.9349,-96.9675),
('78953','Rosanky',29.9241,-97.3119),
('78954','Round Top',30.0411,-96.7341),
('78956','Schulenburg',29.6882,-96.9106),
('78957','Smithville',30.0178,-97.1494),
('78959','Waelder',29.6868,-97.2958),
('78960','Warda',30.0702,-96.902),
('78961','Warrenton',30.0652,-96.6961),
('78962','Weimar',29.6787,-96.755),
('78963','West Point',29.9523,-97.0361),
('79001','Adrian',35.2748,-102.6652),
('79002','Alanreed',35.2273,-100.7592),
('79003','Allison',35.6059,-100.1007),
('79005','Booker',36.4429,-100.5238),
('79007','Borger',35.6678,-101.3974),
('79008','Borger',35.6678,-101.3974),
('79009','Bovina',34.5137,-102.883),
('79010','Boys Ranch',35.5314,-102.2541),
('79011','Briscoe',35.5855,-100.1679),
('79012','Bushland',35.2664,-102.0978),
('79013','Cactus',36.0412,-102.0007),
('79014','Canadian',35.9045,-100.3841),
('79015','Canyon',34.9772,-101.9247),
('79016','Canyon',34.9803,-101.9188),
('79018','Channing',35.6837,-102.3302),
('79019','Claude',35.0967,-101.3813),
('79021','Cotton Center',33.9753,-102.0314),
('79022','Dalhart',36.0732,-102.5177),
('79024','Darrouzett',36.4453,-100.3254),
('79025','Dawn',34.9106,-102.2002),
('79027','Dimmitt',34.5341,-102.3046),
('79029','Dumas',35.8823,-101.968),
('79031','Earth',34.2415,-102.4213),
('79032','Edmonson',34.2789,-101.8941),
('79033','Farnsworth',36.2963,-100.9843),
('79034','Follett',36.4309,-100.2068),
('79035','Friona',34.6417,-102.7241),
('79036','Fritch',35.6441,-101.5845),
('79039','Groom',35.2168,-101.1285),
('79040','Gruver',36.2868,-101.4089),
('79041','Hale Center',34.0669,-101.8736),
('79042','Happy',34.7219,-101.8256),
('79043','Hart',34.3878,-102.1155),
('79044','Hartley',35.8856,-102.3969),
('79045','Hereford',34.837,-102.405),
('79046','Higgins',36.1365,-100.0952),
('79051','Kerrick',36.4956,-102.2427),
('79052','Kress',34.3737,-101.737),
('79053','Lazbuddie',34.3847,-102.587),
('79054','Lefors',35.4391,-100.8059),
('79056','Lipscomb',36.223,-100.2702),
('79057','Mclean',35.2312,-100.6008),
('79058','Masterson',35.6359,-101.9602),
('79059','Miami',35.7193,-100.7027),
('79061','Mobeetie',35.5297,-100.4242),
('79062','Morse',36.0596,-101.4729),
('79063','Nazareth',34.5444,-102.1069),
('79064','Olton',34.1844,-102.1414),
('79065','Pampa',35.538,-100.9579),
('79066','Pampa',35.5334,-100.956),
('79068','Panhandle',35.3808,-101.4304),
('79070','Perryton',36.3748,-100.8156),
('79072','Plainview',34.1962,-101.7259),
('79073','Plainview',34.0689,-101.827),
('79077','Sam Norwood',35.0523,-100.2807),
('79078','Sanford',35.702,-101.5346),
('79079','Shamrock',35.2142,-100.249),
('79080','Skellytown',35.5685,-101.1721),
('79081','Spearman',36.1927,-101.1952),
('79082','Springlake',34.2393,-102.309),
('79083','Stinnett',35.8377,-101.45),
('79084','Stratford',36.3335,-101.9886),
('79085','Summerfield',34.7437,-102.5064),
('79086','Sunray',36.0097,-101.8123),
('79087','Texline',36.374,-102.9845),
('79088','Tulia',34.5583,-101.8039),
('79091','Umbarger',34.901,-102.0788),
('79092','Vega',35.2241,-102.4214),
('79093','Waka',36.2716,-101.0443),
('79094','Wayside',34.7928,-101.5471),
('79095','Wellington',34.8717,-100.2207),
('79096','Wheeler',35.4319,-100.2568),
('79097','White Deer',35.4278,-101.174),
('79098','Wildorado',35.1916,-102.2118),
('79101','Amarillo',35.2032,-101.8421),
('79102','Amarillo',35.1999,-101.8496),
('79103','Amarillo',35.1751,-101.7976),
('79104','Amarillo',35.1939,-101.7975),
('79105','Amarillo',35.4015,-101.8951),
('79106','Amarillo',35.1977,-101.8949),
('79107','Amarillo',35.2309,-101.806),
('79108','Amarillo',35.2779,-101.83),
('79109','Amarillo',35.1663,-101.8868),
('79110','Amarillo',35.1545,-101.8641),
('79111','Amarillo',35.2286,-101.6703),
('79114','Amarillo',35.05,-101.8175),
('79116','Amarillo',35.2454,-101.999),
('79117','Amarillo',35.3089,-101.843),
('79118','Amarillo',35.0763,-101.8349),
('79119','Amarillo',35.0642,-101.9743),
('79120','Amarillo',35.1964,-101.8034),
('79121','Amarillo',35.1697,-101.9266),
('79124','Amarillo',35.2703,-101.943),
('79159','Amarillo',35.222,-101.8313),
('79166','Amarillo',35.4015,-101.8951),
('79168','Amarillo',35.4015,-101.8951),
('79172','Amarillo',35.4015,-101.8951),
('79174','Amarillo',35.4015,-101.8951),
('79178','Amarillo',35.4015,-101.8951),
('79185','Amarillo',35.4015,-101.8951),
('79187','Amarillo',35.26,-101.71),
('79189','Amarillo',35.4015,-101.8951),
('79201','Childress',34.4104,-100.2364),
('79220','Afton',33.7718,-100.8021),
('79221','Aiken',34.1423,-101.5257),
('79223','Cee Vee',34.2295,-100.4573),
('79225','Chillicothe',34.2439,-99.5157),
('79226','Clarendon',34.9529,-100.8952),
('79227','Crowell',33.9912,-99.6983),
('79229','Dickens',33.628,-100.8197),
('79230','Dodson',34.7644,-100.0286),
('79231','Dougherty',33.9446,-101.0922),
('79233','Estelline',34.5303,-100.4455),
('79234','Flomot',34.2321,-101.0038),
('79235','Floydada',33.9743,-101.3346),
('79236','Guthrie',33.6206,-100.3229),
('79237','Hedley',34.8698,-100.6806),
('79239','Lakeview',34.6724,-100.7259),
('79240','Lelia Lake',34.8843,-100.7674),
('79241','Lockney',34.1458,-101.4259),
('79243','Mcadoo',33.7413,-100.9833),
('79244','Matador',34.0525,-100.8361),
('79245','Memphis',34.7122,-100.5347),
('79247','Odell',34.3452,-99.4196),
('79248','Paducah',34.0217,-100.2986),
('79250','Petersburg',33.8768,-101.6046),
('79251','Quail',34.918,-100.4252),
('79252','Quanah',34.2955,-99.7494),
('79255','Quitaque',34.3796,-101.0465),
('79256','Roaring Springs',33.8977,-100.8528),
('79257','Silverton',34.4641,-101.3169),
('79258','South Plains',34.2245,-101.3096),
('79259','Tell',34.3759,-100.3948),
('79261','Turkey',34.4036,-100.8449),
('79311','Abernathy',33.85,-101.8611),
('79312','Amherst',33.9976,-102.4416),
('79313','Anton',33.8043,-102.1652),
('79314','Bledsoe',33.5997,-103.0168),
('79316','Brownfield',33.1698,-102.2762),
('79320','Bula',33.86,-102.67),
('79322','Crosbyton',33.6562,-101.2287),
('79323','Denver City',32.9711,-102.8313),
('79324','Enochs',33.8731,-102.7599),
('79325','Farwell',34.386,-102.9901),
('79326','Fieldton',34.053,-102.206),
('79329','Idalou',33.6504,-101.6786),
('79330','Justiceburg',33.0594,-101.1881),
('79331','Lamesa',32.7367,-101.9569),
('79336','Levelland',33.5788,-102.3676),
('79338','Levelland',33.5932,-102.3627),
('79339','Littlefield',33.9212,-102.3207),
('79342','Loop',32.9162,-102.4221),
('79343','Lorenzo',33.6666,-101.5277),
('79344','Maple',33.8487,-102.8985),
('79345','Meadow',33.3321,-102.2492),
('79346','Morton',33.7251,-102.7594),
('79347','Muleshoe',34.2193,-102.7496),
('79350','New Deal',33.7296,-101.8355),
('79351','Odonnell',32.9773,-101.8271),
('79353','Pep',33.8104,-102.5656),
('79355','Plains',33.1894,-102.8294),
('79356','Post',33.2017,-101.3922),
('79357','Ralls',33.6851,-101.3836),
('79358','Ropesville',33.4575,-102.1584),
('79359','Seagraves',32.9317,-102.5781),
('79360','Seminole',32.721,-102.6828),
('79363','Shallowater',33.6919,-101.9836),
('79364','Slaton',33.4373,-101.6435),
('79366','Ransom Canyon',33.5334,-101.6796),
('79367','Smyer',33.5918,-102.1692),
('79369','Spade',33.9256,-102.1564),
('79370','Spur',33.479,-100.8571),
('79371','Sudan',34.0697,-102.5255),
('79372','Sundown',33.4482,-102.4898),
('79373','Tahoka',33.1988,-101.822),
('79376','Tokio',33.1826,-102.5768),
('79377','Welch',32.9298,-102.1278),
('79378','Wellman',33.0473,-102.4282),
('79379','Whiteface',33.5988,-102.6199),
('79380','Whitharral',33.7354,-102.3419),
('79381','Wilson',33.3299,-101.7122),
('79382','Wolfforth',33.5059,-102.0091),
('79383','New Home',33.3451,-101.9203),
('79401','Lubbock',33.5865,-101.8606),
('79402','Lubbock',33.5922,-101.8511),
('79403','Lubbock',33.6196,-101.8098),
('79404','Lubbock',33.526,-101.8333),
('79405','Lubbock',33.57,-101.84),
('79406','Lubbock',33.5819,-101.8778),
('79407','Lubbock',33.5684,-101.9423),
('79408','Lubbock',33.5659,-101.9267),
('79409','Lubbock',33.5779,-101.8552),
('79410','Lubbock',33.5693,-101.8904),
('79411','Lubbock',33.5704,-101.8626),
('79412','Lubbock',33.5463,-101.8577),
('79413','Lubbock',33.5466,-101.8871),
('79414','Lubbock',33.5497,-101.9187),
('79415','Lubbock',33.6021,-101.876),
('79416','Lubbock',33.5924,-101.9367),
('79423','Lubbock',33.5146,-101.8795),
('79424','Lubbock',33.5159,-101.9344),
('79430','Lubbock',33.61,-101.8213),
('79452','Lubbock',33.61,-101.8213),
('79453','Lubbock',33.5779,-101.8552),
('79457','Lubbock',33.5779,-101.8552),
('79464','Lubbock',33.4896,-102.0109),
('79490','Lubbock',33.61,-101.8213),
('79491','Lubbock',33.61,-101.8213),
('79493','Lubbock',33.61,-101.8213),
('79499','Lubbock',33.61,-101.8213),
('79501','Anson',32.7489,-99.8953),
('79502','Aspermont',33.1301,-100.2344),
('79503','Avoca',32.8832,-99.6964),
('79504','Baird',32.3916,-99.3777),
('79505','Benjamin',33.584,-99.7923),
('79506','Blackwell',32.082,-100.3111),
('79508','Buffalo Gap',32.2894,-99.8103),
('79510','Clyde',32.3803,-99.5184),
('79511','Coahoma',32.2942,-101.3197),
('79512','Colorado City',32.3987,-100.8609),
('79516','Dunn',32.5671,-100.8854),
('79517','Fluvanna',32.853,-101.103),
('79518','Girard',33.3632,-100.6937),
('79519','Goldsboro',32.0482,-99.6775),
('79520','Hamlin',32.8799,-100.128),
('79521','Haskell',33.158,-99.7309),
('79525','Hawley',32.6423,-99.9239),
('79526','Hermleigh',32.6294,-100.7547),
('79527','Ira',32.5821,-101.0021),
('79528','Jayton',33.2518,-100.5825),
('79529','Knox City',33.4183,-99.8137),
('79530','Lawn',32.136,-99.7351),
('79532','Loraine',32.4112,-100.7123),
('79533','Lueders',32.8712,-99.5783),
('79534','Mc Caulley',32.7787,-100.2168),
('79535','Maryneal',32.2026,-100.4972),
('79536','Merkel',32.4444,-99.9924),
('79537','Nolan',32.2919,-100.2107),
('79538','Novice',31.9781,-99.6809),
('79539','O Brien',33.3749,-99.8473),
('79540','Old Glory',33.1298,-100.0559),
('79541','Ovalo',32.1553,-99.8229),
('79543','Roby',32.722,-100.4008),
('79544','Rochester',33.3105,-99.8594),
('79545','Roscoe',32.4276,-100.5391),
('79546','Rotan',32.8555,-100.4705),
('79547','Rule',33.1842,-99.8894),
('79548','Rule',33.0771,-99.959),
('79549','Snyder',32.7451,-100.9175),
('79550','Snyder',32.7179,-100.9176),
('79553','Stamford',32.9453,-99.7859),
('79556','Sweetwater',32.4726,-100.3979),
('79560','Sylvester',32.7209,-100.2543),
('79561','Trent',32.4898,-100.1195),
('79562','Tuscola',32.235,-99.8244),
('79563','Tye',32.4477,-99.8684),
('79565','Westbrook',32.3627,-101.043),
('79566','Wingate',32.0318,-100.1183),
('79567','Winters',31.962,-99.9551),
('79601','Abilene',32.4682,-99.7182),
('79602','Abilene',32.4178,-99.7214),
('79603','Abilene',32.4679,-99.7619),
('79604','Abilene',32.4487,-99.7331),
('79605','Abilene',32.432,-99.7724),
('79606','Abilene',32.392,-99.7746),
('79607','Dyess Afb',32.419,-99.8221),
('79608','Abilene',32.4487,-99.7331),
('79697','Abilene',32.4487,-99.7331),
('79698','Abilene',32.4751,-99.7348),
('79699','Abilene',32.4665,-99.7117),
('79701','Midland',31.9896,-102.0626),
('79702','Midland',31.9637,-102.0801),
('79703','Midland',31.9721,-102.1369),
('79704','Midland',31.8693,-102.0317),
('79705','Midland',32.0295,-102.0915),
('79706','Midland',31.8816,-102.0134),
('79707','Midland',32.0199,-102.1476),
('79708','Midland',31.8693,-102.0317),
('79710','Midland',31.8693,-102.0317),
('79711','Midland',31.9973,-102.0779),
('79712','Midland',31.8693,-102.0317),
('79713','Ackerly',32.5273,-101.716),
('79714','Andrews',32.3201,-102.5409),
('79718','Balmorhea',30.9843,-103.7446),
('79719','Barstow',31.4639,-103.3971),
('79720','Big Spring',32.2787,-101.4578),
('79721','Big Spring',32.2733,-101.374),
('79730','Coyanosa',31.2295,-103.0538),
('79731','Crane',31.3969,-102.3544),
('79733','Forsan',32.1105,-101.3669),
('79734','Fort Davis',30.6131,-103.9364),
('79735','Fort Stockton',30.8908,-102.8799),
('79738','Gail',32.7523,-101.45),
('79739','Garden City',31.8491,-101.5269),
('79740','Girvin',31.0629,-102.3885),
('79741','Goldsmith',31.9541,-102.625),
('79742','Grandfalls',31.3459,-102.8568),
('79743','Imperial',31.2729,-102.6926),
('79744','Iraan',30.9156,-101.9152),
('79745','Kermit',31.855,-103.0913),
('79748','Knott',32.4125,-101.6517),
('79749','Lenorah',32.3046,-101.8762),
('79752','Mc Camey',31.1319,-102.2153),
('79754','Mentone',31.7068,-103.5988),
('79755','Midkiff',31.5424,-101.9244),
('79756','Monahans',31.5813,-102.9003),
('79758','Gardendale',32.0245,-102.3572),
('79759','Notrees',31.8599,-102.7413),
('79760','Odessa',31.7652,-102.3543),
('79761','Odessa',31.8579,-102.3523),
('79762','Odessa',31.889,-102.3548),
('79763','Odessa',31.8341,-102.4162),
('79764','Odessa',31.8767,-102.4375),
('79765','Odessa',31.9375,-102.3944),
('79766','Odessa',31.7827,-102.3449),
('79768','Odessa',31.8457,-102.3676),
('79769','Odessa',31.8457,-102.3676),
('79770','Orla',31.864,-103.9297),
('79772','Pecos',31.4467,-103.5791),
('79776','Penwell',31.7334,-102.5879),
('79777','Pyote',31.5387,-103.1267),
('79778','Rankin',31.2266,-101.9441),
('79780','Saragosa',31.0428,-103.6364),
('79781','Sheffield',30.6935,-101.86),
('79782','Stanton',32.14,-101.8099),
('79783','Tarzan',32.3575,-101.9607),
('79785','Toyah',31.282,-103.8057),
('79786','Toyahvale',30.9443,-103.7893),
('79788','Wickett',31.5692,-103.0067),
('79789','Wink',31.7527,-103.1561),
('79821','Anthony',31.9907,-106.5976),
('79830','Alpine',30.2631,-103.6541),
('79831','Alpine',30.3068,-103.6704),
('79832','Alpine',30.3631,-103.6539),
('79834','Big Bend National Park',29.2924,-103.2963),
('79835','Canutillo',31.9344,-106.5929),
('79836','Clint',31.5494,-106.2038),
('79837','Dell City',31.924,-105.2099),
('79838','Fabens',31.4745,-106.1589),
('79839','Fort Hancock',31.2985,-105.8452),
('79842','Marathon',30.1886,-103.2214),
('79843','Marfa',30.293,-104.0848),
('79845','Presidio',29.5573,-104.3551),
('79846','Redford',29.4702,-104.0055),
('79847','Salt Flat',31.8244,-105.2212),
('79848','Sanderson',30.1221,-102.3974),
('79849','San Elizario',31.5508,-106.2507),
('79851','Sierra Blanca',31.1938,-105.3219),
('79852','Terlingua',29.3165,-103.5597),
('79853','Tornillo',31.4407,-106.0765),
('79854','Valentine',30.62,-104.4811),
('79855','Van Horn',31.0391,-104.8245),
('79901','El Paso',31.7584,-106.4783),
('79902','El Paso',31.7763,-106.4932),
('79903','El Paso',31.7862,-106.4406),
('79904','El Paso',31.8533,-106.4381),
('79905','El Paso',31.7674,-106.4304),
('79906','El Paso',31.8092,-106.4247),
('79907','El Paso',31.7089,-106.3293),
('79908','El Paso',31.8265,-106.3857),
('79910','El Paso',31.6948,-106.3),
('79911','El Paso',31.8925,-106.5426),
('79912','El Paso',31.8383,-106.5364),
('79913','El Paso',31.9373,-106.5724),
('79914','El Paso',31.6948,-106.3),
('79915','El Paso',31.7432,-106.3686),
('79916','Fort Bliss',31.8136,-106.4122),
('79917','El Paso',31.6948,-106.3),
('79918','Fort Bliss',31.8136,-106.4122),
('79920','El Paso',31.8214,-106.4614),
('79922','El Paso',31.8218,-106.5732),
('79923','El Paso',31.6948,-106.3),
('79924','El Paso',31.9021,-106.4149),
('79925','El Paso',31.7814,-106.3613),
('79926','El Paso',31.6948,-106.3),
('79927','El Paso',31.6446,-106.2737),
('79928','El Paso',31.6631,-106.1401),
('79929','El Paso',31.6948,-106.3),
('79930','El Paso',31.8048,-106.4568),
('79931','El Paso',31.6948,-106.3),
('79932','El Paso',31.8623,-106.5932),
('79934','El Paso',31.9386,-106.4073),
('79935','El Paso',31.7718,-106.3303),
('79936','El Paso',31.7677,-106.3016),
('79937','El Paso',31.6948,-106.3),
('79938','El Paso',31.8045,-105.9661),
('79940','El Paso',31.6948,-106.3),
('79941','El Paso',31.7587,-106.4869),
('79942','El Paso',31.6948,-106.3),
('79943','El Paso',31.7587,-106.4869),
('79944','El Paso',31.7587,-106.4869),
('79945','El Paso',31.7587,-106.4869),
('79946','El Paso',31.7587,-106.4869),
('79947','El Paso',31.7587,-106.4869),
('79948','El Paso',31.7587,-106.4869),
('79949','El Paso',31.7587,-106.4869),
('79950','El Paso',31.7587,-106.4869),
('79951','El Paso',31.7587,-106.4869),
('79952','El Paso',31.7587,-106.4869),
('79953','El Paso',31.7587,-106.4869),
('79954','El Paso',31.7587,-106.4869),
('79955','El Paso',31.7587,-106.4869),
('79958','El Paso',31.7587,-106.4869),
('79960','El Paso',31.7587,-106.4869),
('79961','El Paso',31.6948,-106.3),
('79968','El Paso',31.7705,-106.5048),
('79976','El Paso',31.6948,-106.3),
('79978','El Paso',31.7587,-106.4869),
('79980','El Paso',31.6948,-106.3),
('79990','El Paso',31.6948,-106.3),
('79995','El Paso',31.6948,-106.3),
('79996','El Paso',31.6948,-106.3),
('79997','El Paso',31.6948,-106.3),
('79998','El Paso',31.6948,-106.3),
('79999','El Paso',31.6948,-106.3),
('88510','El Paso',31.6948,-106.3),
('88511','El Paso',31.6948,-106.3),
('88512','El Paso',31.6948,-106.3),
('88513','El Paso',31.6948,-106.3),
('88514','El Paso',31.6948,-106.3),
('88515','El Paso',31.6948,-106.3),
('88516','El Paso',31.84,-106.43),
('88517','El Paso',31.6948,-106.3),
('88518','El Paso',31.6948,-106.3),
('88519','El Paso',31.6948,-106.3),
('88520','El Paso',31.6948,-106.3),
('88521','El Paso',31.6948,-106.3),
('88523','El Paso',31.6948,-106.3),
('88524','El Paso',31.6948,-106.3),
('88525','El Paso',31.6948,-106.3),
('88526','El Paso',31.6948,-106.3),
('88527','El Paso',31.6948,-106.3),
('88528','El Paso',31.6948,-106.3),
('88529','El Paso',31.6948,-106.3),
('88530','El Paso',31.6948,-106.3),
('88531','El Paso',31.6948,-106.3),
('88532','El Paso',31.6948,-106.3),
('88533','El Paso',31.6948,-106.3),
('88534','El Paso',31.6948,-106.3),
('88535','El Paso',31.6948,-106.3),
('88536','El Paso',31.6948,-106.3),
('88538','El Paso',31.6948,-106.3),
('88539','El Paso',31.6948,-106.3),
('88540','El Paso',31.6948,-106.3),
('88541','El Paso',31.6948,-106.3),
('88542','El Paso',31.6948,-106.3),
('88543','El Paso',31.6948,-106.3),
('88544','El Paso',31.6948,-106.3),
('88545','El Paso',31.6948,-106.3),
('88546','El Paso',31.6948,-106.3),
('88547','El Paso',31.6948,-106.3),
('88548','El Paso',31.6948,-106.3),
('88549','El Paso',31.6948,-106.3),
('88550','El Paso',31.6948,-106.3),
('88553','El Paso',31.6948,-106.3),
('88554','El Paso',31.6948,-106.3),
('88555','El Paso',31.6948,-106.3),
('88556','El Paso',31.6948,-106.3),
('88557','El Paso',31.6948,-106.3),
('88558','El Paso',31.6948,-106.3),
('88559','El Paso',31.6948,-106.3),
('88560','El Paso',31.6948,-106.3),
('88561','El Paso',31.6948,-106.3),
('88562','El Paso',31.6948,-106.3),
('88563','El Paso',31.6948,-106.3),
('88565','El Paso',31.6948,-106.3),
('88566','El Paso',31.6948,-106.3),
('88567','El Paso',31.6948,-106.3),
('88568','El Paso',31.6948,-106.3),
('88569','El Paso',31.6948,-106.3),
('88570','El Paso',31.6948,-106.3),
('88571','El Paso',31.6948,-106.3),
('88572','El Paso',31.6948,-106.3),
('88573','El Paso',31.6948,-106.3),
('88574','El Paso',31.6948,-106.3),
('88575','El Paso',31.6948,-106.3),
('88576','El Paso',31.6948,-106.3),
('88577','El Paso',31.6948,-106.3),
('88578','El Paso',31.6948,-106.3),
('88579','El Paso',31.6948,-106.3),
('88580','El Paso',31.6948,-106.3),
('88581','El Paso',31.6948,-106.3),
('88582','El Paso',31.6948,-106.3),
('88583','El Paso',31.6948,-106.3),
('88584','El Paso',31.6948,-106.3),
('88585','El Paso',31.6948,-106.3),
('88586','El Paso',31.6948,-106.3),
('88587','El Paso',31.6948,-106.3),
('88588','El Paso',31.6948,-106.3),
('88589','El Paso',31.6948,-106.3),
('88590','El Paso',31.6948,-106.3),
('88595','El Paso',31.6948,-106.3)
on conflict (zip) do nothing;

-- straight-line distance in miles (haversine)
create or replace function private.miles_between(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns numeric language sql immutable set search_path = '' as $$
  select round((2 * 3958.8 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ))))::numeric, 1);
$$;
revoke all on function private.miles_between(double precision, double precision, double precision, double precision) from public, anon, authenticated;

-- a ZIP code or a city name -> one point (a city is the average of its ZIP centers)
create or replace function private.place_point(p_place text)
returns table (lat double precision, lng double precision) language plpgsql stable security definer set search_path = '' as $$
declare t text := btrim(coalesce(p_place, ''));
begin
  if t ~ '^[0-9]{5}' then
    return query select c.lat, c.lng from public.zip_centroids c where c.zip = left(t, 5);
  else
    t := lower(btrim(regexp_replace(t, ',?\s*(tx|texas)$', '', 'i')));
    if t = '' then return; end if;
    return query select avg(c.lat), avg(c.lng) from public.zip_centroids c where lower(c.city) = t having count(*) > 0;
  end if;
end $$;
revoke all on function private.place_point(text) from public, anon, authenticated;

-- customer search: miles from the place to every approved provider (providers without a known ZIP are left out)
create or replace function public.provider_distances(p_place text)
returns table (provider_id uuid, miles numeric) language plpgsql stable security definer set search_path = '' as $$
declare pt record;
begin
  if char_length(coalesce(p_place, '')) > 60 then return; end if;
  select * into pt from private.place_point(p_place);
  if pt.lat is null then return; end if;
  return query
    select p.id, private.miles_between(pt.lat, pt.lng, c.lat, c.lng)
    from public.provider_profiles p join public.zip_centroids c on c.zip = left(btrim(coalesce(p.zip_code, '')), 5)
    where p.status = 'approved';
end $$;
revoke all on function public.provider_distances(text) from public, anon, authenticated;
grant execute on function public.provider_distances(text) to anon, authenticated;

-- provider: how far is each of my bookings from my own ZIP?
create or replace function public.my_booking_distances()
returns table (booking_id uuid, miles numeric) language plpgsql stable security definer set search_path = '' as $$
begin
  return query
    select b.id, private.miles_between(pc.lat, pc.lng, cc.lat, cc.lng)
    from public.bookings b
    join public.provider_profiles p on p.id = b.provider_id and p.user_id = (select auth.uid())
    join public.zip_centroids pc on pc.zip = left(btrim(coalesce(p.zip_code, '')), 5)
    join public.zip_centroids cc on cc.zip = left(btrim(coalesce(b.customer_zip_code, '')), 5);
end $$;
revoke all on function public.my_booking_distances() from public, anon, authenticated;
grant execute on function public.my_booking_distances() to authenticated;


-- ########## 022_mutual_ratings_and_alerts.sql ##########
-- =========================================================
-- WASEL MVP — Mutual ratings + low-rating alerts
--
--   * After a job is completed AND confirmed, the provider can rate the customer (1–5 stars + a private comment).
--     The customer already rates the provider (reviews). Both are optional, one each per booking.
--   * A provider sees the customer's name and AVERAGE rating on every booking (never the individual comments).
--     A customer sees only their own average.
--   * Too many low ratings → an ALERT for the admins (no automatic suspension): when a provider has at least
--     <alert_min_reviews> reviews and an average below <alert_max_avg>, one open alert is created and the admins are emailed.
--     The admin then dismisses it or suspends the provider, always with a written reason (saved in Activity).
-- Run AFTER 021.
-- =========================================================

-- ---------- 1) provider -> customer ratings ----------
create table if not exists public.customer_reviews (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null unique references public.bookings(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  rating      integer not null check (rating between 1 and 5),
  comment     text check (comment is null or char_length(comment) <= 1000),
  created_at  timestamptz not null default now()
);
create index if not exists customer_reviews_customer_idx on public.customer_reviews (customer_id);
alter table public.customer_reviews enable row level security;
revoke all on public.customer_reviews from public, anon, authenticated;
grant select on public.customer_reviews to authenticated;
grant insert (booking_id, rating, comment) on public.customer_reviews to authenticated;

-- the author (provider) and the admins read the rows; the customer only ever sees an average (function below)
create policy "Provider reads own customer reviews" on public.customer_reviews for select to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Admins read customer reviews" on public.customer_reviews for select to authenticated
using ((select private.is_admin()));
create policy "Provider rates own customer" on public.customer_reviews for insert to authenticated
with check (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Active accounts only (customer review)" on public.customer_reviews as restrictive for insert to authenticated
with check ((select private.account_active()));

create or replace function private.prepare_customer_review() returns trigger
language plpgsql security definer set search_path = '' as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = new.booking_id;
  if not found or b.status <> 'completed' or b.confirmed_at is null then
    raise exception 'You can rate a customer once the job is completed and the customer has confirmed it.';
  end if;
  new.provider_id := b.provider_id;   -- RLS then checks it is the caller's own provider profile
  new.customer_id := b.customer_id;
  return new;
end $$;
revoke all on function private.prepare_customer_review() from public, anon, authenticated;
drop trigger if exists customer_reviews_prepare on public.customer_reviews;
create trigger customer_reviews_prepare before insert on public.customer_reviews
for each row execute function private.prepare_customer_review();

-- provider: the customer's average rating for each of my bookings (no individual comments)
create or replace function public.customer_ratings_for_my_bookings()
returns table (booking_id uuid, avg_rating numeric, review_count bigint)
language sql stable security definer set search_path = '' as $$
  select b.id,
         (select round(avg(cr.rating), 1) from public.customer_reviews cr where cr.customer_id = b.customer_id),
         (select count(*) from public.customer_reviews cr where cr.customer_id = b.customer_id)
  from public.bookings b join public.provider_profiles p on p.id = b.provider_id and p.user_id = (select auth.uid());
$$;
revoke all on function public.customer_ratings_for_my_bookings() from public, anon, authenticated;
grant execute on function public.customer_ratings_for_my_bookings() to authenticated;

-- customer: my own average from providers
create or replace function public.my_customer_rating()
returns table (avg_rating numeric, review_count bigint)
language sql stable security definer set search_path = '' as $$
  select round(avg(cr.rating), 1), count(*) from public.customer_reviews cr where cr.customer_id = (select auth.uid());
$$;
revoke all on function public.my_customer_rating() from public, anon, authenticated;
grant execute on function public.my_customer_rating() to authenticated;

-- ---------- 2) the policy numbers ----------
alter table public.platform_settings add column if not exists alert_min_reviews integer not null default 5 check (alert_min_reviews between 1 and 100);
alter table public.platform_settings add column if not exists alert_max_avg numeric(3,2) not null default 3.00 check (alert_max_avg between 1 and 5);

create or replace function public.admin_rating_policy()
returns table (min_reviews integer, max_avg numeric) language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query select alert_min_reviews, alert_max_avg from public.platform_settings where id;
end $$;
revoke all on function public.admin_rating_policy() from public, anon, authenticated;
grant execute on function public.admin_rating_policy() to authenticated;

create or replace function public.admin_update_rating_policy(p_min integer, p_max numeric, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.platform_settings;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_min is null or p_min < 1 or p_min > 100 then raise exception 'The minimum number of reviews must be between 1 and 100.'; end if;
  if p_max is null or p_max < 1 or p_max > 5 then raise exception 'The average rating limit must be between 1 and 5.'; end if;
  select * into old from public.platform_settings where id for update;
  update public.platform_settings set alert_min_reviews = p_min, alert_max_avg = round(p_max, 2), updated_at = now() where id;
  perform private.log_admin('rating_policy_changed', 'settings', null, r,
    jsonb_build_object('min_reviews', jsonb_build_array(old.alert_min_reviews, p_min), 'max_avg', jsonb_build_array(old.alert_max_avg, round(p_max, 2))));
end $$;
revoke all on function public.admin_update_rating_policy(integer, numeric, text) from public, anon, authenticated;
grant execute on function public.admin_update_rating_policy(integer, numeric, text) to authenticated;

-- ---------- 3) alerts ----------
create table if not exists public.admin_alerts (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'low_rating' check (kind in ('low_rating')),
  provider_id uuid not null references public.provider_profiles(id) on delete cascade,
  avg_rating  numeric(3,2) not null,
  review_count integer not null,
  status      text not null default 'open' check (status in ('open', 'handled')),
  action      text check (action in ('dismissed', 'suspended')),
  note        text check (note is null or char_length(note) <= 500),
  created_at  timestamptz not null default now(),
  handled_at  timestamptz,
  handled_by  uuid references auth.users(id) on delete set null
);
create unique index if not exists admin_alerts_one_open on public.admin_alerts (provider_id, kind) where status = 'open';
alter table public.admin_alerts enable row level security;
revoke all on public.admin_alerts from public, anon, authenticated;     -- read and write only through the functions below

alter table public.email_outbox add column if not exists alert_id uuid references public.admin_alerts(id) on delete cascade;
alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done',
                  'booking_completed','completion_confirmed','problem_reported','completion_reminder',
                  'service_pending','service_approved','service_rejected','service_needs_info','contact_new',
                  'provider_new','provider_approved','provider_rejected','provider_needs_info','rating_alert'));
alter table public.email_outbox drop constraint if exists email_outbox_subject_check;
alter table public.email_outbox add constraint email_outbox_subject_check
  check ((kind like 'service\_%' and service_id is not null)
         or (kind = 'contact_new' and contact_id is not null)
         or (kind like 'provider\_%' and provider_id is not null)
         or (kind = 'rating_alert' and alert_id is not null)
         or (kind not like 'service\_%' and kind <> 'contact_new' and kind not like 'provider\_%' and kind <> 'rating_alert' and booking_id is not null));

-- after every new customer review: should the admins take a look at this provider?
create or replace function private.check_rating_alert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare minr integer; maxa numeric; n integer; a numeric; aid uuid;
begin
  select alert_min_reviews, alert_max_avg into minr, maxa from public.platform_settings where id;
  select count(*), avg(rating) into n, a from public.reviews where provider_id = new.provider_id;
  if n >= minr and a < maxa
     and exists (select 1 from public.provider_profiles where id = new.provider_id and status = 'approved') then
    insert into public.admin_alerts (provider_id, avg_rating, review_count) values (new.provider_id, round(a, 2), n)
    on conflict (provider_id, kind) where status = 'open' do update set avg_rating = excluded.avg_rating, review_count = excluded.review_count
    returning id into aid;
    insert into public.email_outbox (kind, alert_id, to_user, dedupe)
    select 'rating_alert', aid, p.id, aid::text || ':' || p.id::text from public.profiles p where p.role = 'admin' and p.is_active
    on conflict do nothing;
  end if;
  return null;
end $$;
revoke all on function private.check_rating_alert() from public, anon, authenticated;
drop trigger if exists reviews_z_alert on public.reviews;
create trigger reviews_z_alert after insert on public.reviews for each row execute function private.check_rating_alert();

create or replace function public.admin_alerts_list()
returns table (id uuid, provider_id uuid, business_name text, provider_status text, avg_rating numeric, review_count integer,
               status text, action text, note text, created_at timestamptz, handled_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select a.id, a.provider_id, p.business_name, p.status::text, a.avg_rating, a.review_count, a.status, a.action, a.note, a.created_at, a.handled_at
    from public.admin_alerts a join public.provider_profiles p on p.id = a.provider_id
    order by (a.status = 'open') desc, a.created_at desc limit 100;
end $$;
revoke all on function public.admin_alerts_list() from public, anon, authenticated;
grant execute on function public.admin_alerts_list() to authenticated;

create or replace function public.admin_handle_alert(p_alert_id uuid, p_action text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare al public.admin_alerts; r text; pr public.provider_profiles;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  if p_action not in ('dismiss', 'suspend') then raise exception 'Unknown action'; end if;
  r := private.need_reason(p_note);
  select * into al from public.admin_alerts where id = p_alert_id for update;
  if not found then raise exception 'Alert not found'; end if;
  if al.status <> 'open' then raise exception 'This alert was already handled.'; end if;
  select * into pr from public.provider_profiles where id = al.provider_id for update;
  if p_action = 'suspend' and pr.status = 'approved' then
    update public.provider_profiles set status = 'suspended' where id = pr.id;
  end if;
  update public.admin_alerts
  set status = 'handled', action = case p_action when 'suspend' then 'suspended' else 'dismissed' end,
      note = r, handled_at = now(), handled_by = (select auth.uid())
  where id = p_alert_id;
  perform private.log_admin(case p_action when 'suspend' then 'alert_provider_suspended' else 'alert_dismissed' end, 'provider', al.provider_id, r,
    jsonb_build_object('business', pr.business_name, 'avg', al.avg_rating, 'reviews', al.review_count));
end $$;
revoke all on function public.admin_handle_alert(uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_handle_alert(uuid, text, text) to authenticated;

-- ---------- 4) claim_emails: same as 020, plus the alert fields ----------
drop function if exists public.claim_emails(int);
create function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric, completed_at timestamptz,
  to_is_admin boolean, approval_note text, contact_name text, contact_email text, contact_topic text, contact_message text,
  to_lang text, alert_avg numeric, alert_count integer
) language plpgsql security definer set search_path = '' as $$
begin
  perform public.queue_completion_reminders();

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'completion_reminder' and o.status = 'pending'
    and (b.status <> 'completed' or b.confirmed_at is not null or b.problem_status <> 'none');

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.services s
  where o.service_id = s.id and o.status = 'pending'
    and ((o.kind = 'service_pending' and s.approval <> 'pending')
      or (o.kind = 'service_approved' and s.approval <> 'approved')
      or (o.kind = 'service_rejected' and s.approval <> 'rejected')
      or (o.kind = 'service_needs_info' and s.approval <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.provider_applications a
  where o.provider_id = a.provider_id and o.status = 'pending'
    and ((o.kind = 'provider_new' and a.state <> 'submitted')
      or (o.kind = 'provider_approved' and a.state <> 'approved')
      or (o.kind = 'provider_rejected' and a.state <> 'rejected')
      or (o.kind = 'provider_needs_info' and a.state <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.admin_alerts al
  where o.alert_id = al.id and o.kind = 'rating_alert' and o.status = 'pending' and al.status <> 'open';

  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         coalesce(pp.user_id = upd.to_user, false), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, coalesce(b.service_price, sv.price), pay.amount, b.completed_at,
         (tp.role = 'admin'), coalesce(sv.approval_note, app.note), cm.name, cm.email, cm.topic, cm.message, tp.lang,
         al.avg_rating, al.review_count
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  left join public.bookings b on b.id = upd.booking_id
  left join public.services sv on sv.id = coalesce(b.service_id, upd.service_id)
  left join public.admin_alerts al on al.id = upd.alert_id
  left join public.provider_profiles pp on pp.id = coalesce(b.provider_id, sv.provider_id, upd.provider_id, al.provider_id)
  left join public.provider_applications app on app.provider_id = upd.provider_id
  left join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id
  left join public.contact_messages cm on cm.id = upd.contact_id;
end $$;
revoke all on function public.claim_emails(int) from public, anon, authenticated;
grant execute on function public.claim_emails(int) to service_role;


-- ########## 023_service_day.sql ##########
-- =========================================================
-- WASEL — 023: the day of the service
--   1) start flow: "Start work" -> directions -> "I arrived" -> photos of the finished work -> "Mark completed"
--   2) the customer gets an email 1 hour before the start time
--   3) in-platform messages between customer and provider, open from 1 hour before the start
--   4) nobody but an admin can cancel in the last hour before the start
-- Photos live in a PRIVATE bucket "work-photos". Path: <provider user id>/<booking id>/<random>-<file name>
-- Run AFTER 022.
-- =========================================================

alter table public.bookings add column if not exists started_at timestamptz;
alter table public.bookings add column if not exists arrived_at timestamptz;

create or replace function private.stamp_started() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'in_progress' and old.status is distinct from 'in_progress' then new.started_at := coalesce(new.started_at, now()); end if;
  return new;
end $$;
drop trigger if exists bookings_stamp_started on public.bookings;
create trigger bookings_stamp_started before update of status on public.bookings
for each row execute function private.stamp_started();

-- the provider confirms that they reached the customer's address
create or replace function public.mark_arrived(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings; uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not private.account_active() then raise exception 'Your account is deactivated. Please contact us.'; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or not exists (select 1 from public.provider_profiles p where p.id = b.provider_id and p.user_id = uid) then raise exception 'Booking not found'; end if;
  if b.status <> 'in_progress' then raise exception 'Start the work first.'; end if;
  if b.arrived_at is not null then return 'ok'; end if;
  update public.bookings set arrived_at = now() where id = p_booking_id;
  return 'ok';
end $$;
revoke all on function public.mark_arrived(uuid) from public, anon;
grant execute on function public.mark_arrived(uuid) to authenticated;

-- ---------- photos of the finished work ----------
create table if not exists public.booking_work_photos (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references public.bookings(id) on delete cascade,
  storage_path text not null unique check (char_length(storage_path) between 10 and 300),
  created_at   timestamptz not null default now()
);
create index if not exists booking_work_photos_booking_idx on public.booking_work_photos(booking_id);
alter table public.booking_work_photos enable row level security;
revoke all on public.booking_work_photos from anon, authenticated;
grant select on public.booking_work_photos to authenticated;
grant insert (booking_id, storage_path) on public.booking_work_photos to authenticated;
grant delete on public.booking_work_photos to authenticated;

create policy "Booking people read work photos" on public.booking_work_photos for select to authenticated
using (exists (select 1 from public.bookings b where b.id = booking_id
               and (b.customer_id = (select auth.uid())
                    or exists (select 1 from public.provider_profiles p where p.id = b.provider_id and p.user_id = (select auth.uid()))))
       or (select private.is_admin()));
create policy "Provider adds work photos" on public.booking_work_photos for insert to authenticated
with check (exists (select 1 from public.bookings b join public.provider_profiles p on p.id = b.provider_id
                    where b.id = booking_id and p.user_id = (select auth.uid()) and b.status = 'in_progress' and b.arrived_at is not null)
            and storage_path like (select auth.uid())::text || '/' || booking_id::text || '/%');
create policy "Provider removes work photos before finishing" on public.booking_work_photos for delete to authenticated
using (exists (select 1 from public.bookings b join public.provider_profiles p on p.id = b.provider_id
               where b.id = booking_id and p.user_id = (select auth.uid()) and b.status = 'in_progress'));
create policy "Active accounts only (work photos)" on public.booking_work_photos as restrictive for insert to authenticated with check ((select private.account_active()));

create or replace function private.limit_work_photos() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.booking_work_photos where booking_id = new.booking_id) >= 8 then
    raise exception 'You can add at most 8 photos of the work.';
  end if;
  return new;
end $$;
drop trigger if exists work_photos_limit on public.booking_work_photos;
create trigger work_photos_limit before insert on public.booking_work_photos for each row execute function private.limit_work_photos();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('work-photos', 'work-photos', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
create policy "Provider uploads work photos" on storage.objects for insert to authenticated
with check (bucket_id = 'work-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Booking people read work photo files" on storage.objects for select to authenticated
using (bucket_id = 'work-photos' and ((storage.foldername(name))[1] = (select auth.uid())::text
       or (select private.is_admin())
       or exists (select 1 from public.bookings b where b.id::text = (storage.foldername(name))[2] and b.customer_id = (select auth.uid()))));
create policy "Provider deletes own work photo files" on storage.objects for delete to authenticated
using (bucket_id = 'work-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------- booking changes: finishing needs arrival + photos; nobody cancels in the last hour ----------
create or replace function public.transition_booking(p_booking_id uuid, p_new_status public.booking_status)
returns public.bookings language plpgsql security definer set search_path = '' as $$
declare
  b           public.bookings;
  uid         uuid := (select auth.uid());
  is_provider boolean;
  is_customer boolean;
  allowed     boolean := false;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not private.account_active() then raise exception 'Your account is deactivated. Please contact us.'; end if;

  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;

  is_customer := (b.customer_id = uid);
  is_provider := exists (select 1 from public.provider_profiles p where p.id = b.provider_id and p.user_id = uid);

  if is_provider then
    allowed := (b.status = 'pending'     and p_new_status in ('confirmed', 'declined'))
            or (b.status = 'confirmed'   and p_new_status in ('in_progress', 'cancelled'))
            or (b.status = 'in_progress' and p_new_status = 'completed');
  elsif is_customer then
    allowed := (b.status in ('pending', 'confirmed') and p_new_status = 'cancelled');
  else
    raise exception 'Not allowed';
  end if;
  if not allowed then raise exception 'Cannot change booking from % to %', b.status, p_new_status; end if;

  if p_new_status = 'cancelled' and now() > b.scheduled_at - interval '1 hour' then
    raise exception 'It is too late to cancel: cancelling closes 1 hour before the start time. Please contact Wasel.';
  end if;
  if p_new_status = 'completed' then
    if b.arrived_at is null then raise exception 'Confirm that you arrived at the customer''s address first.'; end if;
    if not exists (select 1 from public.booking_work_photos w where w.booking_id = b.id) then
      raise exception 'Add at least one photo of the finished work first.';
    end if;
  end if;

  update public.bookings set status = p_new_status where id = p_booking_id returning * into b;
  return b;
end $$;

-- ---------- messages between the customer and the provider ----------
create table if not exists public.booking_messages (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  sender_id  uuid not null references public.profiles(id),
  body       text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists booking_messages_booking_idx on public.booking_messages(booking_id, created_at);
alter table public.booking_messages enable row level security;
revoke all on public.booking_messages from anon, authenticated;
grant select on public.booking_messages to authenticated;
create policy "Booking people and admins read messages" on public.booking_messages for select to authenticated
using (exists (select 1 from public.bookings b where b.id = booking_id
               and (b.customer_id = (select auth.uid())
                    or exists (select 1 from public.provider_profiles p where p.id = b.provider_id and p.user_id = (select auth.uid()))))
       or (select private.is_admin()));

-- open from 1 hour before the start until the job is finished
create or replace function public.send_booking_message(p_booking_id uuid, p_body text)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings; uid uuid := (select auth.uid()); txt text := btrim(coalesce(p_body, ''));
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not private.account_active() then raise exception 'Your account is deactivated. Please contact us.'; end if;
  select * into b from public.bookings where id = p_booking_id;
  if not found or not (b.customer_id = uid or exists (select 1 from public.provider_profiles p where p.id = b.provider_id and p.user_id = uid)) then
    raise exception 'Booking not found';
  end if;
  if char_length(txt) < 1 then raise exception 'Write a message first.'; end if;
  if char_length(txt) > 1000 then raise exception 'Messages can have up to 1000 characters.'; end if;
  if b.status not in ('confirmed', 'in_progress') then raise exception 'Messages are available while a confirmed booking is open.'; end if;
  if now() < b.scheduled_at - interval '1 hour' then raise exception 'Messages open 1 hour before the start time.'; end if;
  if (select count(*) from public.booking_messages m where m.booking_id = b.id) >= 200 then raise exception 'This conversation reached its limit. Please contact Wasel.'; end if;
  insert into public.booking_messages(booking_id, sender_id, body) values (b.id, uid, txt);
  return 'ok';
end $$;
revoke all on function public.send_booking_message(uuid, text) from public, anon;
grant execute on function public.send_booking_message(uuid, text) to authenticated;

-- ---------- 1 hour before: email the customer ----------
alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done',
                  'booking_completed','completion_confirmed','problem_reported','completion_reminder',
                  'service_pending','service_approved','service_rejected','service_needs_info','contact_new',
                  'provider_new','provider_approved','provider_rejected','provider_needs_info','rating_alert',
                  'booking_starting_soon'));

create or replace function public.queue_start_reminders()
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  with q as (
    insert into public.email_outbox(kind, booking_id, to_user)
    select 'booking_starting_soon', b.id, b.customer_id
    from public.bookings b
    where b.status = 'confirmed' and b.scheduled_at > now() and b.scheduled_at <= now() + interval '1 hour'
    on conflict do nothing
    returning 1
  )
  select count(*) into n from q;
  return n;
end $$;
revoke all on function public.queue_start_reminders() from public, anon, authenticated;
grant execute on function public.queue_start_reminders() to service_role;

drop function if exists public.claim_emails(int);
create function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric, completed_at timestamptz,
  to_is_admin boolean, approval_note text, contact_name text, contact_email text, contact_topic text, contact_message text,
  to_lang text, alert_avg numeric, alert_count integer
) language plpgsql security definer set search_path = '' as $$
begin
  perform public.queue_completion_reminders();
  perform public.queue_start_reminders();

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'completion_reminder' and o.status = 'pending'
    and (b.status <> 'completed' or b.confirmed_at is not null or b.problem_status <> 'none');

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'booking_starting_soon' and o.status = 'pending'
    and (b.status not in ('confirmed', 'in_progress') or b.scheduled_at < now() - interval '2 hours');

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.services s
  where o.service_id = s.id and o.status = 'pending'
    and ((o.kind = 'service_pending' and s.approval <> 'pending')
      or (o.kind = 'service_approved' and s.approval <> 'approved')
      or (o.kind = 'service_rejected' and s.approval <> 'rejected')
      or (o.kind = 'service_needs_info' and s.approval <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.provider_applications a
  where o.provider_id = a.provider_id and o.status = 'pending'
    and ((o.kind = 'provider_new' and a.state <> 'submitted')
      or (o.kind = 'provider_approved' and a.state <> 'approved')
      or (o.kind = 'provider_rejected' and a.state <> 'rejected')
      or (o.kind = 'provider_needs_info' and a.state <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.admin_alerts al
  where o.alert_id = al.id and o.kind = 'rating_alert' and o.status = 'pending' and al.status <> 'open';

  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         coalesce(pp.user_id = upd.to_user, false), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, coalesce(b.service_price, sv.price), pay.amount, b.completed_at,
         (tp.role = 'admin'), coalesce(sv.approval_note, app.note), cm.name, cm.email, cm.topic, cm.message, tp.lang,
         al.avg_rating, al.review_count
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  left join public.bookings b on b.id = upd.booking_id
  left join public.services sv on sv.id = coalesce(b.service_id, upd.service_id)
  left join public.admin_alerts al on al.id = upd.alert_id
  left join public.provider_profiles pp on pp.id = coalesce(b.provider_id, sv.provider_id, upd.provider_id, al.provider_id)
  left join public.provider_applications app on app.provider_id = upd.provider_id
  left join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id
  left join public.contact_messages cm on cm.id = upd.contact_id;
end $$;
revoke all on function public.claim_emails(int) from public, anon, authenticated;
grant execute on function public.claim_emails(int) to service_role;


-- ########## 024_service_catalog.sql ##########
-- 024: the admin owns the list of services; providers only choose from it
--   * public.service_catalog: the services Wasel offers (name, description, category, suggested price, default duration).
--     Only admins add / change / hide them (every change is written to the audit log).
--   * public.services stays the "offering" row: one provider + one catalog item + the provider's own price, duration and visibility.
--     A provider can no longer type a service name, description or category: they are copied from the catalog.
--   * Because the admin already vetted the list, choosing a catalog item needs no separate approval or supporting document.
--   * Hiding a catalog item hides every provider offering of it (and blocks new bookings); existing bookings are untouched.
--   * Services that exist today become catalog items (hidden ones stay hidden until an admin shows them).

-- ---------- 1) the catalog ----------
create table if not exists public.service_catalog (
  id                       uuid primary key default gen_random_uuid(),
  name                     text not null check (char_length(btrim(name)) between 2 and 80),
  description              text check (description is null or char_length(description) <= 500),
  category                 text not null check (category in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair')),
  suggested_price          numeric(10,2) check (suggested_price is null or (suggested_price >= 1 and suggested_price <= 100000)),
  default_duration_minutes integer not null default 60 check (default_duration_minutes between 15 and 1440),
  is_active                boolean not null default true,
  created_by               uuid references auth.users(id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create unique index if not exists service_catalog_name_idx on public.service_catalog (lower(btrim(name)), category);
create index if not exists service_catalog_active_idx on public.service_catalog (category) where is_active;
drop trigger if exists service_catalog_updated_at on public.service_catalog;
create trigger service_catalog_updated_at before update on public.service_catalog for each row execute function public.set_updated_at();

alter table public.service_catalog enable row level security;
revoke all on public.service_catalog from public, anon, authenticated;
grant select on public.service_catalog to anon, authenticated;          -- no insert / update / delete: only the admin functions below write
create policy "Active catalog is public" on public.service_catalog for select to anon, authenticated using (is_active);
create policy "Admins read the whole catalog" on public.service_catalog for select to authenticated using ((select private.is_admin()));

-- ---------- 2) link offerings to the catalog, and move the services that exist today ----------
alter table public.services add column if not exists catalog_id uuid references public.service_catalog(id) on delete restrict;

do $$
declare r record; cid uuid; nm text;
begin
  -- one catalog item per distinct (name, category); the oldest service supplies the description.
  -- items that only come from services that were never approved stay hidden until an admin looks at them.
  insert into public.service_catalog (name, description, category, suggested_price, default_duration_minutes, is_active)
  select distinct on (lower(btrim(s.name)), s.category)
         btrim(s.name), nullif(btrim(coalesce(s.description, '')), ''), s.category, null, least(1440, greatest(15, s.duration_minutes)),
         exists (select 1 from public.services x where lower(btrim(x.name)) = lower(btrim(s.name)) and x.category = s.category and x.approval = 'approved')
  from public.services s
  where s.catalog_id is null and s.category in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair')
  order by lower(btrim(s.name)), s.category, s.created_at
  on conflict do nothing;

  -- the first offering of each provider for an item links to it; a provider's duplicates get their own numbered item (so nothing is lost)
  for r in
    select s.id, s.name, s.description, s.category, s.duration_minutes, s.approval,
           row_number() over (partition by s.provider_id, lower(btrim(s.name)), s.category order by s.created_at, s.id) as rn
    from public.services s where s.catalog_id is null
  loop
    nm := btrim(r.name);
    if r.rn > 1 then nm := left(nm, 70) || ' (' || r.rn || ')'; end if;
    select id into cid from public.service_catalog where lower(btrim(name)) = lower(nm) and category = r.category;
    if cid is null then
      insert into public.service_catalog (name, description, category, default_duration_minutes, is_active)
      values (nm, nullif(btrim(coalesce(r.description, '')), ''), r.category, least(1440, greatest(15, r.duration_minutes)), r.approval = 'approved')
      returning id into cid;
    end if;
    update public.services set catalog_id = cid where id = r.id;
  end loop;
end $$;

-- the approval workflow is retired: every remaining offering counts as approved (unvetted ones are hidden through their catalog item)
update public.services set approval = 'approved', approval_note = null, reviewed_at = null, reviewed_by = null where approval <> 'approved';
alter table public.services alter column catalog_id set not null;
create unique index if not exists services_provider_catalog_idx on public.services (provider_id, catalog_id);
create index if not exists services_catalog_idx on public.services (catalog_id);

-- ---------- 3) a provider can only pick a catalog item and set price / duration / visibility ----------
revoke insert (name, description, category) on public.services from authenticated;
revoke update (name, description, category) on public.services from authenticated;
grant insert (catalog_id) on public.services to authenticated;

create or replace function private.services_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare c public.service_catalog;
begin
  -- our own SECURITY DEFINER functions and the service role are not restricted; a signed-in user changing the table directly is
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    select * into c from public.service_catalog where id = new.catalog_id and is_active;
    if not found then raise exception 'Please choose a service from the Wasel list.'; end if;
    if exists (select 1 from public.services where provider_id = new.provider_id and catalog_id = new.catalog_id) then
      raise exception 'You already offer this service.';
    end if;
    new.name := c.name; new.description := c.description; new.category := c.category;
    new.approval := 'approved'; new.approval_note := null; new.reviewed_at := null; new.reviewed_by := null;
    if new.price < 1 or new.price > 100000 then raise exception 'The price must be between $1 and $100,000.'; end if;
    return new;
  end if;
  -- update by the provider: what the service IS comes from the catalog and cannot change
  new.catalog_id := old.catalog_id; new.name := old.name; new.description := old.description; new.category := old.category;
  new.approval := old.approval; new.approval_note := old.approval_note; new.reviewed_at := old.reviewed_at; new.reviewed_by := old.reviewed_by;
  if new.price is distinct from old.price and (new.price < 1 or new.price > 100000) then
    raise exception 'The price must be between $1 and $100,000.';
  end if;
  return new;
end $$;
revoke all on function private.services_guard() from public, anon, authenticated;

-- ---------- 4) customers only see / book offerings whose catalog item is shown ----------
drop policy if exists "Active services are publicly visible" on public.services;
create policy "Active services are publicly visible"
on public.services for select to anon, authenticated
using (
  status = 'active' and approval = 'approved'
  and exists (select 1 from public.provider_profiles p where p.id = services.provider_id and p.status = 'approved')
  and exists (select 1 from public.service_catalog c where c.id = services.catalog_id and c.is_active)
);

drop policy if exists "Photos of active services are publicly visible" on public.service_photos;
create policy "Photos of active services are publicly visible"
on public.service_photos for select to anon, authenticated
using (
  exists (
    select 1 from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    join public.service_catalog c on c.id = s.catalog_id
    where s.id = service_photos.service_id and s.status = 'active' and s.approval = 'approved' and p.status = 'approved' and c.is_active
  )
);

create or replace function public.prepare_booking()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  select sv.price, sv.provider_id, p.commission_rate, p.user_id as provider_user_id
    into s
  from public.services sv
  join public.provider_profiles p on p.id = sv.provider_id
  join public.service_catalog c on c.id = sv.catalog_id
  where sv.id = new.service_id
    and sv.status = 'active'
    and sv.approval = 'approved'
    and p.status  = 'approved'
    and c.is_active;

  if not found then raise exception 'Service is not available for booking'; end if;
  if s.provider_user_id = new.customer_id then raise exception 'You cannot book your own service'; end if;
  if new.scheduled_at <= now() then raise exception 'Booking time must be in the future'; end if;
  if new.quoted_price is not null and new.quoted_price <> s.price then
    raise exception 'The price changed to $%. Please check it and try again.', to_char(s.price, 'FM999999990.00');
  end if;

  new.provider_id         := s.provider_id;
  new.service_price       := s.price;
  new.platform_commission := round(s.price * s.commission_rate / 100, 2);
  new.provider_payout     := s.price - new.platform_commission;
  new.status              := 'pending';
  return new;
end $$;
revoke all on function public.prepare_booking() from public, anon, authenticated;

-- ---------- 5) retire the per-service approval workflow ----------
drop trigger if exists services_email_review on public.services;
drop function if exists public.email_on_service_review();
drop function if exists public.admin_service_queue();
drop function if exists public.admin_review_service(uuid, boolean, text);
drop function if exists public.admin_request_service_info(uuid, text);
drop function if exists public.resubmit_service(uuid);

-- ---------- 6) admin: manage the catalog ----------
create or replace function private.check_catalog_fields(p_name text, p_description text, p_category text, p_price numeric, p_duration integer)
returns void language plpgsql immutable as $$
begin
  if char_length(btrim(coalesce(p_name, ''))) < 2 or char_length(btrim(p_name)) > 80 then raise exception 'The service name must be 2 to 80 characters.'; end if;
  if char_length(coalesce(p_description, '')) > 500 then raise exception 'Please keep the description under 500 characters.'; end if;
  if p_category is null or p_category not in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair') then raise exception 'Choose a category.'; end if;
  if p_price is not null and (p_price < 1 or p_price > 100000) then raise exception 'The suggested price must be between $1 and $100,000.'; end if;
  if p_duration is null or p_duration < 15 or p_duration > 1440 then raise exception 'The default duration must be between 15 and 1440 minutes.'; end if;
end $$;
revoke all on function private.check_catalog_fields(text, text, text, numeric, integer) from public, anon, authenticated;

create or replace function public.admin_catalog_list()
returns table (id uuid, name text, description text, category text, suggested_price numeric, default_duration_minutes integer,
               is_active boolean, offered_by bigint, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select c.id, c.name, c.description, c.category, c.suggested_price, c.default_duration_minutes, c.is_active,
           (select count(*) from public.services s where s.catalog_id = c.id), c.created_at, c.updated_at
    from public.service_catalog c
    order by c.category, lower(c.name);
end $$;

create or replace function public.admin_create_catalog_item(p_name text, p_description text, p_category text, p_suggested_price numeric, p_duration integer)
returns uuid language plpgsql security definer set search_path = '' as $$
declare cid uuid; nm text := btrim(coalesce(p_name, ''));
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  perform private.check_catalog_fields(nm, p_description, p_category, p_suggested_price, p_duration);
  if exists (select 1 from public.service_catalog c where lower(btrim(c.name)) = lower(nm) and c.category = p_category) then
    raise exception 'This service is already in the list.';
  end if;
  insert into public.service_catalog (name, description, category, suggested_price, default_duration_minutes, created_by)
  values (nm, nullif(btrim(coalesce(p_description, '')), ''), p_category, p_suggested_price, p_duration, (select auth.uid()))
  returning id into cid;
  perform private.log_admin('catalog_added', 'catalog', cid, null, jsonb_build_object('name', nm, 'category', p_category));
  return cid;
end $$;

-- change a catalog item (a reason is required). The name / description / category are copied to every provider offering of it.
create or replace function public.admin_update_catalog_item(p_id uuid, p_name text, p_description text, p_category text,
                                                            p_suggested_price numeric, p_duration integer, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; nm text := btrim(coalesce(p_name, '')); old public.service_catalog; act text;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into old from public.service_catalog where id = p_id for update;
  if not found then raise exception 'Service not found in the list.'; end if;
  perform private.check_catalog_fields(nm, p_description, p_category, p_suggested_price, p_duration);
  if exists (select 1 from public.service_catalog c where c.id <> p_id and lower(btrim(c.name)) = lower(nm) and c.category = p_category) then
    raise exception 'This service is already in the list.';
  end if;
  update public.service_catalog
  set name = nm, description = nullif(btrim(coalesce(p_description, '')), ''), category = p_category,
      suggested_price = p_suggested_price, default_duration_minutes = p_duration, is_active = coalesce(p_active, old.is_active)
  where id = p_id;
  update public.services
  set name = nm, description = nullif(btrim(coalesce(p_description, '')), ''), category = p_category
  where catalog_id = p_id and (name, description, category) is distinct from (nm, nullif(btrim(coalesce(p_description, '')), ''), p_category);
  act := case when old.is_active and not coalesce(p_active, old.is_active) then 'catalog_hidden'
              when not old.is_active and coalesce(p_active, old.is_active) then 'catalog_shown'
              else 'catalog_updated' end;
  perform private.log_admin(act, 'catalog', p_id, r, jsonb_build_object('name', nm, 'was', old.name, 'category', p_category, 'active', coalesce(p_active, old.is_active)));
end $$;

-- delete is only possible while no provider offers the item (otherwise hide it)
create or replace function public.admin_delete_catalog_item(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.service_catalog;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into old from public.service_catalog where id = p_id for update;
  if not found then raise exception 'Service not found in the list.'; end if;
  if exists (select 1 from public.services where catalog_id = p_id) then
    raise exception 'Providers already offer this service, so it cannot be deleted. Hide it instead.';
  end if;
  delete from public.service_catalog where id = p_id;
  perform private.log_admin('catalog_deleted', 'catalog', p_id, r, jsonb_build_object('name', old.name, 'category', old.category));
end $$;

-- ---------- grants ----------
revoke all on function public.admin_catalog_list()                                                         from public, anon, authenticated;
revoke all on function public.admin_create_catalog_item(text, text, text, numeric, integer)                from public, anon, authenticated;
revoke all on function public.admin_update_catalog_item(uuid, text, text, text, numeric, integer, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_delete_catalog_item(uuid, text)                                        from public, anon, authenticated;
grant execute on function public.admin_catalog_list()                                                      to authenticated;
grant execute on function public.admin_create_catalog_item(text, text, text, numeric, integer)             to authenticated;
grant execute on function public.admin_update_catalog_item(uuid, text, text, text, numeric, integer, boolean, text) to authenticated;
grant execute on function public.admin_delete_catalog_item(uuid, text)                                     to authenticated;



-- ===== 025_super_admin_invites.sql =====
-- =====================================================================
-- Wasel — Super admin, admin invites, full user overview and edits
-- Run ONCE in the Supabase SQL Editor (project wasel-staging), after 001-024.
-- Safe to run again: everything is "if not exists" / "create or replace".
-- =====================================================================

-- 1) Who is the main (super) admin ------------------------------------
alter table public.profiles add column if not exists is_super_admin boolean not null default false;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_super_must_be_admin') then
    alter table public.profiles add constraint profiles_super_must_be_admin
      check (not is_super_admin or role = 'admin');
  end if;
end $$;

-- only one main admin at a time
create unique index if not exists profiles_one_super_admin on public.profiles ((true)) where is_super_admin;

-- clients can never write this column (column-level grants only allow name/phone/avatar)
revoke update (is_super_admin) on public.profiles from anon, authenticated;

create or replace function private.is_super_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin' and is_active = true and is_super_admin = true
  );
$$;
revoke execute on function private.is_super_admin() from public, anon;
grant  execute on function private.is_super_admin() to authenticated;

-- 2) Invite codes ------------------------------------------------------
create table if not exists public.admin_invites (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,              -- only the hash is stored, never the code
  note        text,
  created_by  uuid not null references public.profiles(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_by     uuid references public.profiles(id),
  used_at     timestamptz,
  revoked_at  timestamptz
);
alter table public.admin_invites enable row level security;
revoke all on public.admin_invites from anon, authenticated;   -- reachable only through the functions below

create or replace function private.invite_hash(p_code text)
returns text language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')), 'hex');
$$;

-- super admin creates a one-time code (shown once, valid for p_days)
create or replace function public.admin_create_invite(p_note text default null, p_days integer default 7)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare raw text; shown text; v_id uuid; v_exp timestamptz;
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can create invite codes'; end if;
  if p_days is null or p_days < 1 or p_days > 30 then raise exception 'Choose between 1 and 30 days'; end if;
  raw := upper(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''));
  raw := substr(raw, 1, 32);
  shown := 'WASEL-' || substr(raw,1,8) || '-' || substr(raw,9,8) || '-' || substr(raw,17,8) || '-' || substr(raw,25,8);
  v_exp := now() + make_interval(days => p_days);
  insert into public.admin_invites (code_hash, note, created_by, expires_at)
  values (private.invite_hash(shown), nullif(left(btrim(coalesce(p_note, '')), 120), ''), (select auth.uid()), v_exp)
  returning id into v_id;
  perform private.log_admin('admin_invite_created', 'invite', v_id, null, jsonb_build_object('note', p_note, 'expires_at', v_exp));
  return jsonb_build_object(
    'id', v_id, 'expires_at', v_exp,
    'code', shown);
end $$;

create or replace function public.admin_list_invites()
returns table (id uuid, note text, created_at timestamptz, expires_at timestamptz, status text, used_by_name text, created_by_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can see invite codes'; end if;
  return query
  select i.id, i.note, i.created_at, i.expires_at,
         case when i.used_at is not null then 'used'
              when i.revoked_at is not null then 'revoked'
              when i.expires_at <= now() then 'expired' else 'active' end,
         u.full_name, c.full_name
  from public.admin_invites i
  left join public.profiles u on u.id = i.used_by
  left join public.profiles c on c.id = i.created_by
  order by i.created_at desc limit 100;
end $$;

create or replace function public.admin_revoke_invite(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can cancel invite codes'; end if;
  update public.admin_invites set revoked_at = now() where id = p_id and used_at is null and revoked_at is null;
  if not found then raise exception 'This code is already used, cancelled or does not exist'; end if;
  perform private.log_admin('admin_invite_revoked', 'invite', p_id, null, '{}'::jsonb);
end $$;

-- the sign-up page asks this before creating the account (true/false only)
create or replace function public.check_admin_invite(p_code text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.admin_invites
    where code_hash = private.invite_hash(p_code) and used_at is null and revoked_at is null and expires_at > now()
  );
$$;

-- 3) Account creation: a valid invite code makes the new account an admin ----
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_code text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'admin_invite', '')), '');
        v_inv  public.admin_invites;
        v_role public.user_role := 'customer';
begin
  if v_code is not null then
    select * into v_inv from public.admin_invites
    where code_hash = private.invite_hash(v_code) and used_at is null and revoked_at is null and expires_at > now()
    for update;
    if not found then raise exception 'invalid_admin_invite'; end if;   -- the account is NOT created
    v_role := 'admin';
  end if;

  insert into public.profiles (id, full_name, role, lang)
  values (new.id, new.raw_user_meta_data ->> 'full_name', v_role,
          case when new.raw_user_meta_data ->> 'lang' = 'es' then 'es' else 'en' end);

  if v_role = 'admin' then
    update public.admin_invites set used_by = new.id, used_at = now() where id = v_inv.id;
    insert into public.admin_audit (admin_id, action, target_type, target_id, details)
    values (v_inv.created_by, 'admin_invite_used', 'user', new.id,
            jsonb_build_object('invite', v_inv.id, 'name', new.raw_user_meta_data ->> 'full_name'));
  end if;
  return new;
end $$;

-- 4) Who can change roles / deactivate (admins are managed by the main admin only) ----
create or replace function public.admin_set_user_role(p_user_id uuid, p_role public.user_role)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare row public.profiles; target public.profiles;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own role'; end if;
  select * into target from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  if target.is_super_admin then raise exception 'The main admin cannot be changed'; end if;
  if (target.role = 'admin' or p_role = 'admin') and not private.is_super_admin() then
    raise exception 'Only the main admin can add or remove admins';
  end if;
  update public.profiles set role = p_role where id = p_user_id returning * into row;
  perform private.log_admin('user_role', 'user', p_user_id, null,
          jsonb_build_object('from', target.role, 'to', p_role, 'name', row.full_name));
  return row;
end $$;

create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; target public.profiles; suspended int := 0;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own account'; end if;
  select * into target from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  if target.is_super_admin then raise exception 'The main admin cannot be deactivated'; end if;
  if target.role = 'admin' and not private.is_super_admin() then
    raise exception 'Only the main admin can deactivate an admin';
  end if;
  if target.is_active = p_active then raise exception 'The account is already %', case when p_active then 'active' else 'deactivated' end; end if;

  update public.profiles set is_active = p_active where id = p_user_id;
  if not p_active then
    update public.provider_profiles set status = 'suspended' where user_id = p_user_id and status <> 'suspended';
    get diagnostics suspended = row_count;
  end if;
  perform private.log_admin(case when p_active then 'user_reactivated' else 'user_deactivated' end, 'user', p_user_id, r,
                            jsonb_build_object('name', target.full_name, 'role', target.role, 'provider_suspended', suspended > 0));
end $$;

-- 5) Every user with status, email and last sign-in (admins only) -------------
create or replace function public.admin_users_overview(p_limit integer default 500)
returns table (
  id uuid, email text, full_name text, phone text, role public.user_role, is_active boolean, is_super_admin boolean,
  created_at timestamptz, last_sign_in_at timestamptz, email_confirmed boolean,
  provider_id uuid, provider_status text, business_name text, bookings_count bigint
) language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Admins only'; end if;
  return query
  select p.id, u.email::text, p.full_name, p.phone, p.role, p.is_active, p.is_super_admin,
         p.created_at, u.last_sign_in_at, (u.email_confirmed_at is not null),
         pp.id, pp.status::text, pp.business_name,
         (select count(*) from public.bookings b where b.customer_id = p.id)
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.provider_profiles pp on pp.user_id = p.id
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit, 500), 1), 1000);
end $$;

-- 6) Edit a user / a provider (main admin only, always logged) ---------------
create or replace function public.admin_update_user(p_user_id uuid, p_full_name text, p_phone text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.profiles; n text := nullif(btrim(coalesce(p_full_name, '')), ''); ph text := nullif(btrim(coalesce(p_phone, '')), '');
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can edit user data'; end if;
  r := private.need_reason(p_reason);
  if n is null or char_length(n) > 120 then raise exception 'Name is required (up to 120 characters)'; end if;
  if ph is not null and char_length(ph) > 40 then raise exception 'Phone is too long'; end if;
  select * into old from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  update public.profiles set full_name = n, phone = ph where id = p_user_id;
  perform private.log_admin('user_edited', 'user', p_user_id, r,
          jsonb_build_object('name', old.full_name, 'new_name', n, 'old_phone', old.phone, 'new_phone', ph));
end $$;

create or replace function public.admin_update_provider(
  p_provider_id uuid, p_business_name text, p_description text, p_phone text, p_email text, p_website text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.provider_profiles; b text := nullif(btrim(coalesce(p_business_name, '')), '');
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can edit provider data'; end if;
  r := private.need_reason(p_reason);
  if b is null or char_length(b) > 120 then raise exception 'Business name is required (up to 120 characters)'; end if;
  if char_length(coalesce(p_description, '')) > 2000 then raise exception 'Description is too long'; end if;
  select * into old from public.provider_profiles where id = p_provider_id;
  if not found then raise exception 'Provider not found'; end if;
  update public.provider_profiles set
    business_name = b,
    description   = nullif(btrim(coalesce(p_description, '')), ''),
    phone         = nullif(left(btrim(coalesce(p_phone, '')), 40), ''),
    email         = nullif(left(btrim(coalesce(p_email, '')), 200), ''),
    website       = nullif(left(btrim(coalesce(p_website, '')), 300), '')
  where id = p_provider_id;
  perform private.log_admin('provider_edited', 'provider', p_provider_id, r,
          jsonb_build_object('name', old.business_name, 'new_name', b));
end $$;

-- 7) Permissions: nobody but signed-in users, and each function re-checks the role itself
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_create_invite(text,integer)', 'public.admin_list_invites()', 'public.admin_revoke_invite(uuid)',
    'public.admin_users_overview(integer)', 'public.admin_update_user(uuid,text,text,text)',
    'public.admin_update_provider(uuid,text,text,text,text,text,text)',
    'public.admin_set_user_role(uuid,public.user_role)', 'public.admin_set_user_active(uuid,boolean,text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
revoke execute on function public.check_admin_invite(text) from public;
grant  execute on function public.check_admin_invite(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- FIRST MAIN ADMIN (one time): sign up on the admin page is not possible
-- without a code, so make yourself the main admin like this.
-- 1) create a normal account on the site (customer sign-up) and confirm the email
-- 2) run this with YOUR email:
--
--   update public.profiles
--      set role = 'admin', is_super_admin = true
--    where id = (select id from auth.users where email = 'YOUR-EMAIL@example.com');
-- ---------------------------------------------------------------------

-- 026: small security hardening (advisor notes)
alter function private.audit_no_change() set search_path = '';
alter function private.need_reason(text) set search_path = '';
alter function private.check_catalog_fields(text, text, text, numeric, integer) set search_path = '';
-- trigger-only function: nobody needs to call it through the API
revoke execute on function public.limit_service_photos() from public, anon, authenticated;
