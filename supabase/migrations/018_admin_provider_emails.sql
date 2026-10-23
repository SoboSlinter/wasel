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
