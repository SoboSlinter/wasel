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
