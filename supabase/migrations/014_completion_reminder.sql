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
