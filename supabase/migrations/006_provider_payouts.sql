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
