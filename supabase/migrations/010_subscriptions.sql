-- =========================================================
-- WASEL MVP — Provider subscriptions ("Wasel Pro")
-- Free plan: 10% platform fee.  Pro plan ($19/month, set in Stripe): 5% fee and listed first in search.
-- The fee is copied onto a booking when it is created, so changing plan never changes old bookings.
-- Run AFTER 009.
-- =========================================================

alter table public.provider_profiles
  add column if not exists is_pro boolean not null default false;   -- public: used to sort search and show the badge

-- one place that says what each plan costs (percent)
create or replace function public.plan_commission(p_pro boolean)
returns numeric language sql immutable set search_path = '' as $$ select case when p_pro then 5.00 else 10.00 end $$;

-- Server: may this user start a subscription? Returns the provider and any saved Stripe customer.
create or replace function public.subscription_context(p_user_id uuid)
returns table (provider_id uuid, business_name text, email text, stripe_customer_id text, already_pro boolean)
language plpgsql security definer set search_path = '' as $$
declare p public.provider_profiles%rowtype;
begin
  select * into p from public.provider_profiles where user_id = p_user_id;
  if not found then raise exception 'Only providers can subscribe'; end if;
  if p.status <> 'approved' then raise exception 'Your provider account must be approved first'; end if;
  return query
    select p.id, p.business_name, p.email, s.stripe_customer_id, p.is_pro
    from (select 1) x left join public.subscriptions s on s.provider_id = p.id;
end $$;

create or replace function public.save_subscription_customer(p_provider_id uuid, p_customer_id text)
returns void language sql security definer set search_path = '' as $$
  insert into public.subscriptions (provider_id, stripe_customer_id) values (p_provider_id, p_customer_id)
  on conflict (provider_id) do update set stripe_customer_id = coalesce(public.subscriptions.stripe_customer_id, excluded.stripe_customer_id);
$$;

-- Stripe says the subscription is now in state p_status. The customer id must be the one WE saved for that provider.
-- Returns 'pro' | 'free' | 'unknown_provider' | 'customer_mismatch'
create or replace function public.apply_subscription_state(
  p_provider_id uuid, p_customer_id text, p_subscription_id text, p_status text,
  p_period_start timestamptz, p_period_end timestamptz)
returns text language plpgsql security definer set search_path = '' as $$
declare sub public.subscriptions%rowtype; pro boolean; st public.subscription_status;
begin
  select * into sub from public.subscriptions where provider_id = p_provider_id for update;
  if not found then return 'unknown_provider'; end if;
  if sub.stripe_customer_id is distinct from p_customer_id then return 'customer_mismatch'; end if;

  -- an older subscription of the same customer must not overwrite a newer one
  if sub.stripe_subscription_id is not null and sub.stripe_subscription_id <> p_subscription_id
     and sub.status in ('active', 'trialing', 'past_due') and p_status not in ('active', 'trialing') then
    return case when (select is_pro from public.provider_profiles where id = p_provider_id) then 'pro' else 'free' end;
  end if;

  st := case p_status
          when 'active' then 'active' when 'trialing' then 'trialing' when 'past_due' then 'past_due'
          when 'incomplete' then 'incomplete' else 'cancelled' end;
  -- past_due keeps Pro while Stripe retries the card; unpaid/cancelled/incomplete_expired/etc. drop to free
  pro := st in ('active', 'trialing', 'past_due');

  update public.subscriptions
  set plan_name = case when pro then 'pro' else 'basic' end, status = st,
      stripe_subscription_id = p_subscription_id,
      current_period_start = p_period_start, current_period_end = p_period_end
  where provider_id = p_provider_id;

  update public.provider_profiles
  set is_pro = pro, commission_rate = public.plan_commission(pro)
  where id = p_provider_id;
  return case when pro then 'pro' else 'free' end;
end $$;

-- Provider: my plan
create or replace function public.my_subscription()
returns table (is_pro boolean, status text, current_period_end timestamptz, commission_rate numeric, has_customer boolean)
language sql stable security definer set search_path = '' as $$
  select p.is_pro, coalesce(s.status::text, 'none'), s.current_period_end, p.commission_rate, s.stripe_customer_id is not null
  from public.provider_profiles p left join public.subscriptions s on s.provider_id = p.id
  where p.user_id = (select auth.uid());
$$;

revoke all on function public.plan_commission(boolean)                                   from public, anon, authenticated;
revoke all on function public.subscription_context(uuid)                                 from public, anon, authenticated;
revoke all on function public.save_subscription_customer(uuid, text)                     from public, anon, authenticated;
revoke all on function public.apply_subscription_state(uuid, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.my_subscription()                                          from public, anon, authenticated;
grant execute on function public.subscription_context(uuid)                              to service_role;
grant execute on function public.save_subscription_customer(uuid, text)                  to service_role;
grant execute on function public.apply_subscription_state(uuid, text, text, text, timestamptz, timestamptz) to service_role;
grant execute on function public.plan_commission(boolean)                                to service_role;
grant execute on function public.my_subscription()                                       to authenticated;
