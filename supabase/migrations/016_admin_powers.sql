-- 016: more admin powers, each one written to an audit log that nobody can edit.
--   * deactivate / reactivate an account (with teeth: a deactivated account cannot book, review, edit services or change bookings)
--   * hide / show a service
--   * remove a review (provider rating is recalculated)
--   * cancel a booking on behalf of the parties (the customer is refunded in full if they had paid)
--   * audit log for these and for the existing admin actions (provider status, user role, problem release)

-- ---------- audit log: append only ----------
create table if not exists public.admin_audit (
  id           uuid primary key default gen_random_uuid(),
  admin_id     uuid references auth.users(id) on delete set null,
  action       text not null,
  target_type  text not null,
  target_id    uuid,
  reason       text,
  details      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists admin_audit_created_idx on public.admin_audit (created_at desc);
alter table public.admin_audit enable row level security;                    -- no policies: only the functions below touch it
revoke all on public.admin_audit from public, anon, authenticated;

create or replace function private.audit_no_change() returns trigger language plpgsql as $$
begin raise exception 'The audit log cannot be changed'; end $$;
drop trigger if exists admin_audit_no_update on public.admin_audit;
create trigger admin_audit_no_update before update or delete on public.admin_audit
for each row execute function private.audit_no_change();
drop trigger if exists admin_audit_no_truncate on public.admin_audit;
create trigger admin_audit_no_truncate before truncate on public.admin_audit
for each statement execute function private.audit_no_change();

create or replace function private.log_admin(p_action text, p_type text, p_target uuid, p_reason text default null, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.admin_audit(admin_id, action, target_type, target_id, reason, details)
  values ((select auth.uid()), p_action, p_type, p_target, nullif(btrim(coalesce(p_reason, '')), ''), coalesce(p_details, '{}'::jsonb));
$$;
revoke all on function private.log_admin(text, text, uuid, text, jsonb) from public, anon, authenticated;

create or replace function private.need_reason(p_reason text) returns text language plpgsql immutable as $$
declare r text := btrim(coalesce(p_reason, ''));
begin
  if char_length(r) < 5 then raise exception 'Please write a reason (at least 5 characters).'; end if;
  if char_length(r) > 500 then raise exception 'Please keep the reason under 500 characters.'; end if;
  return r;
end $$;
revoke all on function private.need_reason(text) from public, anon, authenticated;

-- ---------- is this account switched on? ----------
create or replace function private.account_active() returns boolean
language sql security definer stable set search_path = '' as $$
  select coalesce((select is_active from public.profiles where id = (select auth.uid())), false);
$$;
revoke all on function private.account_active() from public, anon;
grant execute on function private.account_active() to authenticated;

-- a deactivated account cannot do new things (restrictive policies are ANDed with the existing ones)
drop policy if exists "Active accounts only (book)" on public.bookings;
create policy "Active accounts only (book)" on public.bookings as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (review)" on public.reviews;
create policy "Active accounts only (review)" on public.reviews as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (add service)" on public.services;
create policy "Active accounts only (add service)" on public.services as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (edit service)" on public.services;
create policy "Active accounts only (edit service)" on public.services as restrictive for update to authenticated using ((select private.account_active()));
drop policy if exists "Active accounts only (photos)" on public.service_photos;
create policy "Active accounts only (photos)" on public.service_photos as restrictive for insert to authenticated with check ((select private.account_active()));
drop policy if exists "Active accounts only (provider profile)" on public.provider_profiles;
create policy "Active accounts only (provider profile)" on public.provider_profiles as restrictive for update to authenticated using ((select private.account_active()));

-- booking changes (confirm, start, complete, cancel) are blocked too
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

  update public.bookings set status = p_new_status where id = p_booking_id returning * into b;
  return b;
end $$;

-- ---------- existing admin actions now leave a trace ----------
create or replace function public.admin_set_provider_status(p_provider_id uuid, p_status public.provider_status)
returns public.provider_profiles language plpgsql security definer set search_path = '' as $$
declare row public.provider_profiles; old_status public.provider_status;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  select status into old_status from public.provider_profiles where id = p_provider_id;
  update public.provider_profiles set status = p_status where id = p_provider_id returning * into row;
  if not found then raise exception 'Provider not found'; end if;
  perform private.log_admin('provider_status', 'provider', p_provider_id, null, jsonb_build_object('from', old_status, 'to', p_status, 'business', row.business_name));
  return row;
end $$;

create or replace function public.admin_set_user_role(p_user_id uuid, p_role public.user_role)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare row public.profiles; old_role public.user_role;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own role'; end if;
  select role into old_role from public.profiles where id = p_user_id;
  update public.profiles set role = p_role where id = p_user_id returning * into row;
  if not found then raise exception 'User not found'; end if;
  perform private.log_admin('user_role', 'user', p_user_id, null, jsonb_build_object('from', old_role, 'to', p_role, 'name', row.full_name));
  return row;
end $$;

create or replace function public.admin_resolve_problem(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  update public.bookings set confirmed_at = coalesce(confirmed_at, now()), problem_status = 'resolved'
  where id = p_booking_id and status = 'completed' and problem_status = 'open';
  if not found then raise exception 'No open problem on this booking'; end if;
  perform private.log_admin('problem_released', 'booking', p_booking_id, null, '{}'::jsonb);
  return 'ok';
end $$;

-- ---------- 1) deactivate / reactivate an account ----------
create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; target public.profiles; suspended int := 0;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own account'; end if;
  select * into target from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  if target.role = 'admin' then raise exception 'Change this person''s role first. Admins cannot be deactivated directly.'; end if;
  if target.is_active = p_active then raise exception 'The account is already %', case when p_active then 'active' else 'deactivated' end; end if;

  update public.profiles set is_active = p_active where id = p_user_id;
  if not p_active then
    -- a deactivated provider disappears from search; reactivating does NOT approve them again
    update public.provider_profiles set status = 'suspended' where user_id = p_user_id and status <> 'suspended';
    get diagnostics suspended = row_count;
  end if;
  perform private.log_admin(case when p_active then 'user_reactivated' else 'user_deactivated' end, 'user', p_user_id, r,
                            jsonb_build_object('name', target.full_name, 'role', target.role, 'provider_suspended', suspended > 0));
end $$;

-- ---------- 2) hide / show a service ----------
create or replace function public.admin_set_service_status(p_service_id uuid, p_status public.service_status, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; s public.services;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_status = 'draft' then raise exception 'Use hidden (inactive) or active'; end if;
  select * into s from public.services where id = p_service_id;
  if not found then raise exception 'Service not found'; end if;
  if s.status = p_status then raise exception 'The service is already %', p_status; end if;
  update public.services set status = p_status where id = p_service_id;
  perform private.log_admin(case when p_status = 'active' then 'service_shown' else 'service_hidden' end, 'service', p_service_id, r,
                            jsonb_build_object('name', s.name, 'from', s.status, 'to', p_status));
end $$;

-- ---------- 3) remove a review ----------
create or replace function public.admin_remove_review(p_review_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; rv public.reviews;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into rv from public.reviews where id = p_review_id;
  if not found then raise exception 'Review not found'; end if;
  delete from public.reviews where id = p_review_id;
  update public.provider_profiles p
  set rating       = coalesce((select round(avg(x.rating), 2) from public.reviews x where x.provider_id = rv.provider_id), 0),
      review_count = (select count(*) from public.reviews x where x.provider_id = rv.provider_id)
  where p.id = rv.provider_id;
  perform private.log_admin('review_removed', 'review', p_review_id, r,
                            jsonb_build_object('rating', rv.rating, 'comment', left(coalesce(rv.comment, ''), 300), 'provider_id', rv.provider_id, 'booking_id', rv.booking_id));
end $$;

-- ---------- 4) cancel a booking on behalf of both sides ----------
create or replace function public.admin_cancel_booking(p_booking_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = '' as $$
declare r text; b public.bookings;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status not in ('pending', 'confirmed', 'in_progress') then
    raise exception 'Only a booking that is not finished can be cancelled (it is %). For a finished job use Problems.', b.status;
  end if;
  update public.bookings set status = 'cancelled' where id = p_booking_id;
  perform private.log_admin('booking_cancelled', 'booking', p_booking_id, r, jsonb_build_object('was', b.status, 'price', b.service_price));
  return 'ok';
end $$;

-- the refund step must accept an admin as the person asking (the customer is refunded in full)
create or replace function public.claim_refund(p_payment_id uuid, p_caller uuid)
returns table (code text, amount numeric, payment_intent text, booking_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments%rowtype;
  b public.bookings%rowtype;
  owner uuid;
  caller_is_admin boolean := false;
begin
  select * into pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  select * into b from public.bookings where id = pay.booking_id;
  select user_id into owner from public.provider_profiles where id = b.provider_id;
  if p_caller is not null then
    caller_is_admin := exists (select 1 from public.profiles where id = p_caller and role = 'admin' and is_active);
  end if;
  if p_caller is not null and not caller_is_admin and p_caller is distinct from b.customer_id and p_caller is distinct from owner then
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

-- ---------- 5) lists for the admin screens ----------
create or replace function public.admin_audit_log(p_limit int default 100)
returns table (id uuid, created_at timestamptz, admin_name text, action text, target_type text, target_id uuid, reason text, details jsonb)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select a.id, a.created_at, coalesce(p.full_name, 'Admin'), a.action, a.target_type, a.target_id, a.reason, a.details
    from public.admin_audit a left join public.profiles p on p.id = a.admin_id
    order by a.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;

create or replace function public.admin_content(p_limit int default 100)
returns table (kind text, id uuid, title text, subtitle text, body text, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    (select 'service'::text, s.id, s.name, pp.business_name || ' · $' || s.price::text, left(coalesce(s.description, ''), 300), s.status::text, s.created_at
       from public.services s join public.provider_profiles pp on pp.id = s.provider_id
       order by s.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 300)))
    union all
    (select 'review'::text, r.id, repeat('★', r.rating) || repeat('☆', 5 - r.rating), coalesce(cp.full_name, 'Customer') || ' → ' || pp.business_name, coalesce(r.comment, ''), 'visible'::text, r.created_at
       from public.reviews r join public.provider_profiles pp on pp.id = r.provider_id join public.profiles cp on cp.id = r.customer_id
       order by r.created_at desc limit greatest(1, least(coalesce(p_limit, 100), 300)))
    order by 7 desc;
end $$;

-- ---------- grants ----------
revoke all on function public.admin_set_user_active(uuid, boolean, text)                     from public, anon;
revoke all on function public.admin_set_service_status(uuid, public.service_status, text)    from public, anon;
revoke all on function public.admin_remove_review(uuid, text)                                from public, anon;
revoke all on function public.admin_cancel_booking(uuid, text)                               from public, anon;
revoke all on function public.admin_audit_log(int)                                           from public, anon;
revoke all on function public.admin_content(int)                                             from public, anon;
grant execute on function public.admin_set_user_active(uuid, boolean, text)                  to authenticated;
grant execute on function public.admin_set_service_status(uuid, public.service_status, text) to authenticated;
grant execute on function public.admin_remove_review(uuid, text)                             to authenticated;
grant execute on function public.admin_cancel_booking(uuid, text)                            to authenticated;
grant execute on function public.admin_audit_log(int)                                        to authenticated;
grant execute on function public.admin_content(int)                                          to authenticated;
