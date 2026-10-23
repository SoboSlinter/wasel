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
