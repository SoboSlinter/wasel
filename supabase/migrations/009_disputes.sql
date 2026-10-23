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
