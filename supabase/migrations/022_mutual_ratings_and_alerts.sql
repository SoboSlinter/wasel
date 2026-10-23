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
