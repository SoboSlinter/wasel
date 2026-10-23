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
