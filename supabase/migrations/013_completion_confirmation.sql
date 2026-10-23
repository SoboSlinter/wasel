-- =========================================================
-- WASEL MVP — Job completion confirmation + public reviews
-- Provider marks the job "completed". The CUSTOMER then confirms it (or reports a problem).
-- The provider's payout waits for that confirmation. If the customer does nothing for
-- 72 hours the job counts as confirmed. A reported problem holds the payout until an admin
-- resolves it. Run AFTER 012.
-- =========================================================

alter table public.bookings
  add column if not exists completed_at   timestamptz,
  add column if not exists confirmed_at   timestamptz,
  add column if not exists problem_status text not null default 'none' check (problem_status in ('none','open','resolved')),
  add column if not exists problem_note   text check (problem_note is null or char_length(problem_note) between 5 and 1000),
  add column if not exists problem_at     timestamptz;

-- jobs that were already completed before this change are treated as confirmed (nobody's payout gets stuck)
update public.bookings set completed_at = coalesce(completed_at, updated_at), confirmed_at = coalesce(confirmed_at, updated_at)
where status = 'completed';

create or replace function public.stamp_completed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then new.completed_at := now(); end if;
  return new;
end $$;
revoke all on function public.stamp_completed() from public, anon, authenticated;
drop trigger if exists bookings_stamp_completed on public.bookings;
create trigger bookings_stamp_completed before update of status on public.bookings
for each row execute function public.stamp_completed();

-- Is the provider's money free to be sent?  completed + no open problem + (confirmed OR 72 h passed)
create or replace function public.payout_released(b public.bookings)
returns boolean language sql stable set search_path = '' as $$
  select b.status = 'completed' and b.problem_status <> 'open'
     and (b.confirmed_at is not null or b.completed_at <= now() - interval '72 hours');
$$;
revoke all on function public.payout_released(public.bookings) from public, anon, authenticated;

-- ---------- customer actions ----------
create or replace function public.confirm_completion(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings; uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.customer_id <> uid then raise exception 'Booking not found'; end if;
  if b.status <> 'completed' then raise exception 'The provider has not marked this job as completed yet'; end if;
  if b.confirmed_at is not null then return 'already'; end if;
  update public.bookings set confirmed_at = now(),
         problem_status = case when problem_status = 'open' then 'resolved' else problem_status end
  where id = b.id;
  return 'ok';
end $$;

create or replace function public.report_problem(p_booking_id uuid, p_note text)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings; uid uuid := (select auth.uid()); n text := btrim(coalesce(p_note, ''));
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.customer_id <> uid then raise exception 'Booking not found'; end if;
  if b.status <> 'completed' then raise exception 'You can only report a problem on a completed job'; end if;
  if b.confirmed_at is not null then raise exception 'You already confirmed this job'; end if;
  if char_length(n) < 5 or char_length(n) > 1000 then raise exception 'Describe the problem in 5 to 1000 characters'; end if;
  if b.problem_status = 'open' then return 'already'; end if;
  update public.bookings set problem_status = 'open', problem_note = n, problem_at = now() where id = b.id;
  return 'ok';
end $$;

-- admin: the problem is sorted out (any refund is made by hand in Stripe) -> the payout is released
create or replace function public.admin_resolve_problem(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  update public.bookings set confirmed_at = coalesce(confirmed_at, now()), problem_status = 'resolved'
  where id = p_booking_id and status = 'completed' and problem_status = 'open';
  if not found then raise exception 'No open problem on this booking'; end if;
  return 'ok';
end $$;

create or replace function public.admin_problems()
returns table (booking_id uuid, service_name text, business_name text, customer_name text, price numeric, note text, reported_at timestamptz, paid boolean, payout_status text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select b.id, sv.name, pp.business_name, coalesce(cp.full_name, ''), b.service_price, b.problem_note, b.problem_at,
           coalesce(pay.status = 'paid', false), coalesce(pay.payout_status, 'none')
    from public.bookings b
    join public.services sv on sv.id = b.service_id
    join public.provider_profiles pp on pp.id = b.provider_id
    join public.profiles cp on cp.id = b.customer_id
    left join public.payments pay on pay.booking_id = b.id
    where b.problem_status = 'open'
    order by b.problem_at;
end $$;

revoke all on function public.confirm_completion(uuid)       from public, anon;
revoke all on function public.report_problem(uuid, text)     from public, anon;
revoke all on function public.admin_resolve_problem(uuid)    from public, anon;
revoke all on function public.admin_problems()               from public, anon;
grant execute on function public.confirm_completion(uuid)    to authenticated;
grant execute on function public.report_problem(uuid, text)  to authenticated;
grant execute on function public.admin_resolve_problem(uuid) to authenticated;
grant execute on function public.admin_problems()            to authenticated;

-- ---------- payout gate (same as 009 plus the confirmation rule) ----------
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
  if p_caller is not null and owner is distinct from p_caller and p_caller is distinct from b.customer_id then
    raise exception 'Payment not found';
  end if;

  booking_id := b.id; payment_intent := pay.stripe_payment_intent_id; amount := pay.provider_amount;
  if pay.payout_status = 'sent'
     or (pay.payout_status = 'processing' and pay.payout_at > now() - interval '10 minutes') then
    code := 'already';
  elsif pay.status <> 'paid' then code := 'not_paid';
  elsif pay.dispute_status in ('open', 'lost') then code := 'disputed';
  elsif b.status <> 'completed' then code := 'not_completed';
  elsif b.problem_status = 'open' then code := 'problem_open';
  elsif not public.payout_released(b) then code := 'awaiting_confirmation';
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

create or replace function public.payments_awaiting_payout(p_account_id text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select pay.id
  from public.payments pay
  join public.bookings b on b.id = pay.booking_id
  join public.provider_payout_accounts a on a.provider_id = b.provider_id
  where a.stripe_account_id = p_account_id
    and pay.status = 'paid' and pay.payout_status in ('none', 'failed')
    and pay.dispute_status in ('none', 'won')
    and public.payout_released(b);
$$;

-- for the scheduler: everything that is free to be paid out right now (72 h passed, or a retry)
create or replace function public.payments_due_for_release()
returns setof uuid language sql stable security definer set search_path = '' as $$
  select pay.id
  from public.payments pay
  join public.bookings b on b.id = pay.booking_id
  join public.provider_payout_accounts a on a.provider_id = b.provider_id and a.payouts_enabled
  where pay.status = 'paid' and pay.payout_status in ('none', 'failed')
    and pay.dispute_status in ('none', 'won')
    and public.payout_released(b)
  order by b.completed_at
  limit 50;
$$;
revoke all on function public.claim_payout(uuid, uuid)            from public, anon, authenticated;
revoke all on function public.payments_awaiting_payout(text)      from public, anon, authenticated;
revoke all on function public.payments_due_for_release()          from public, anon, authenticated;
grant execute on function public.claim_payout(uuid, uuid)         to service_role;
grant execute on function public.payments_awaiting_payout(text)   to service_role;
grant execute on function public.payments_due_for_release()       to service_role;

-- provider's own list now also says whether the customer confirmed
drop function if exists public.my_booking_payouts();
create or replace function public.my_booking_payouts()
returns table (booking_id uuid, paid boolean, payout_status text, dispute_status text, confirmed boolean, problem_status text, auto_release_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select b.id, (pay.status = 'paid'), pay.payout_status, pay.dispute_status,
         (b.confirmed_at is not null), b.problem_status, b.completed_at + interval '72 hours'
  from public.bookings b
  join public.provider_profiles p on p.id = b.provider_id
  join public.payments pay on pay.booking_id = b.id
  where p.user_id = (select auth.uid());
$$;
revoke all on function public.my_booking_payouts() from public, anon;
grant execute on function public.my_booking_payouts() to authenticated;

-- ---------- emails: completed (ask the customer), confirmed / problem (tell the provider) ----------
alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done','booking_completed','completion_confirmed','problem_reported'));

create or replace function public.email_on_completion()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid;
begin
  select user_id into pu from public.provider_profiles where id = new.provider_id;
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform public.queue_email('booking_completed', new.id, new.customer_id);
  end if;
  if new.confirmed_at is not null and old.confirmed_at is null and pu is not null and old.status = 'completed' then
    perform public.queue_email('completion_confirmed', new.id, pu);
  end if;
  if new.problem_status = 'open' and old.problem_status is distinct from 'open' and pu is not null then
    perform public.queue_email('problem_reported', new.id, pu);
  end if;
  return new;
end $$;
revoke all on function public.email_on_completion() from public, anon, authenticated;
drop trigger if exists bookings_email_completion on public.bookings;
create trigger bookings_email_completion after update of status, confirmed_at, problem_status on public.bookings
for each row execute function public.email_on_completion();

-- ---------- public reviews of a provider (first name + last initial only) ----------
create or replace function public.provider_reviews(p_provider_id uuid, p_limit int default 20)
returns table (rating int, comment text, created_at timestamptz, reviewer text)
language sql stable security definer set search_path = '' as $$
  select r.rating, r.comment, r.created_at,
         coalesce(nullif(initcap(split_part(btrim(p.full_name), ' ', 1)), '') ||
                  case when position(' ' in btrim(p.full_name)) > 0 then ' ' || upper(left(split_part(btrim(p.full_name), ' ', 2), 1)) || '.' else '' end,
                  'Customer')
  from public.reviews r
  join public.profiles p on p.id = r.customer_id
  join public.provider_profiles pp on pp.id = r.provider_id and pp.status = 'approved'
  where r.provider_id = p_provider_id
  order by r.created_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;
revoke all on function public.provider_reviews(uuid, int) from public;
grant execute on function public.provider_reviews(uuid, int) to anon, authenticated;

alter table public.reviews drop constraint if exists reviews_comment_len;
alter table public.reviews add constraint reviews_comment_len check (comment is null or char_length(comment) <= 1000);
