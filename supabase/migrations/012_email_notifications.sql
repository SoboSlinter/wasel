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
