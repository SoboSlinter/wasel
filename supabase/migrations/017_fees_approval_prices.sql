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
