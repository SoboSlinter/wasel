-- =====================================================================
-- Wasel — Super admin, admin invites, full user overview and edits
-- Run ONCE in the Supabase SQL Editor (project wasel-staging), after 001-024.
-- Safe to run again: everything is "if not exists" / "create or replace".
-- =====================================================================

-- 1) Who is the main (super) admin ------------------------------------
alter table public.profiles add column if not exists is_super_admin boolean not null default false;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_super_must_be_admin') then
    alter table public.profiles add constraint profiles_super_must_be_admin
      check (not is_super_admin or role = 'admin');
  end if;
end $$;

-- only one main admin at a time
create unique index if not exists profiles_one_super_admin on public.profiles ((true)) where is_super_admin;

-- clients can never write this column (column-level grants only allow name/phone/avatar)
revoke update (is_super_admin) on public.profiles from anon, authenticated;

create or replace function private.is_super_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin' and is_active = true and is_super_admin = true
  );
$$;
revoke execute on function private.is_super_admin() from public, anon;
grant  execute on function private.is_super_admin() to authenticated;

-- 2) Invite codes ------------------------------------------------------
create table if not exists public.admin_invites (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,              -- only the hash is stored, never the code
  note        text,
  created_by  uuid not null references public.profiles(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_by     uuid references public.profiles(id),
  used_at     timestamptz,
  revoked_at  timestamptz
);
alter table public.admin_invites enable row level security;
revoke all on public.admin_invites from anon, authenticated;   -- reachable only through the functions below

create or replace function private.invite_hash(p_code text)
returns text language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')), 'hex');
$$;

-- super admin creates a one-time code (shown once, valid for p_days)
create or replace function public.admin_create_invite(p_note text default null, p_days integer default 7)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare raw text; shown text; v_id uuid; v_exp timestamptz;
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can create invite codes'; end if;
  if p_days is null or p_days < 1 or p_days > 30 then raise exception 'Choose between 1 and 30 days'; end if;
  raw := upper(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''));
  raw := substr(raw, 1, 32);
  shown := 'WASEL-' || substr(raw,1,8) || '-' || substr(raw,9,8) || '-' || substr(raw,17,8) || '-' || substr(raw,25,8);
  v_exp := now() + make_interval(days => p_days);
  insert into public.admin_invites (code_hash, note, created_by, expires_at)
  values (private.invite_hash(shown), nullif(left(btrim(coalesce(p_note, '')), 120), ''), (select auth.uid()), v_exp)
  returning id into v_id;
  perform private.log_admin('admin_invite_created', 'invite', v_id, null, jsonb_build_object('note', p_note, 'expires_at', v_exp));
  return jsonb_build_object(
    'id', v_id, 'expires_at', v_exp,
    'code', shown);
end $$;

create or replace function public.admin_list_invites()
returns table (id uuid, note text, created_at timestamptz, expires_at timestamptz, status text, used_by_name text, created_by_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can see invite codes'; end if;
  return query
  select i.id, i.note, i.created_at, i.expires_at,
         case when i.used_at is not null then 'used'
              when i.revoked_at is not null then 'revoked'
              when i.expires_at <= now() then 'expired' else 'active' end,
         u.full_name, c.full_name
  from public.admin_invites i
  left join public.profiles u on u.id = i.used_by
  left join public.profiles c on c.id = i.created_by
  order by i.created_at desc limit 100;
end $$;

create or replace function public.admin_revoke_invite(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can cancel invite codes'; end if;
  update public.admin_invites set revoked_at = now() where id = p_id and used_at is null and revoked_at is null;
  if not found then raise exception 'This code is already used, cancelled or does not exist'; end if;
  perform private.log_admin('admin_invite_revoked', 'invite', p_id, null, '{}'::jsonb);
end $$;

-- the sign-up page asks this before creating the account (true/false only)
create or replace function public.check_admin_invite(p_code text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.admin_invites
    where code_hash = private.invite_hash(p_code) and used_at is null and revoked_at is null and expires_at > now()
  );
$$;

-- 3) Account creation: a valid invite code makes the new account an admin ----
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_code text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'admin_invite', '')), '');
        v_inv  public.admin_invites;
        v_role public.user_role := 'customer';
begin
  if v_code is not null then
    select * into v_inv from public.admin_invites
    where code_hash = private.invite_hash(v_code) and used_at is null and revoked_at is null and expires_at > now()
    for update;
    if not found then raise exception 'invalid_admin_invite'; end if;   -- the account is NOT created
    v_role := 'admin';
  end if;

  insert into public.profiles (id, full_name, role, lang)
  values (new.id, new.raw_user_meta_data ->> 'full_name', v_role,
          case when new.raw_user_meta_data ->> 'lang' = 'es' then 'es' else 'en' end);

  if v_role = 'admin' then
    update public.admin_invites set used_by = new.id, used_at = now() where id = v_inv.id;
    insert into public.admin_audit (admin_id, action, target_type, target_id, details)
    values (v_inv.created_by, 'admin_invite_used', 'user', new.id,
            jsonb_build_object('invite', v_inv.id, 'name', new.raw_user_meta_data ->> 'full_name'));
  end if;
  return new;
end $$;

-- 4) Who can change roles / deactivate (admins are managed by the main admin only) ----
create or replace function public.admin_set_user_role(p_user_id uuid, p_role public.user_role)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare row public.profiles; target public.profiles;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own role'; end if;
  select * into target from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  if target.is_super_admin then raise exception 'The main admin cannot be changed'; end if;
  if (target.role = 'admin' or p_role = 'admin') and not private.is_super_admin() then
    raise exception 'Only the main admin can add or remove admins';
  end if;
  update public.profiles set role = p_role where id = p_user_id returning * into row;
  perform private.log_admin('user_role', 'user', p_user_id, null,
          jsonb_build_object('from', target.role, 'to', p_role, 'name', row.full_name));
  return row;
end $$;

create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; target public.profiles; suspended int := 0;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own account'; end if;
  select * into target from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  if target.is_super_admin then raise exception 'The main admin cannot be deactivated'; end if;
  if target.role = 'admin' and not private.is_super_admin() then
    raise exception 'Only the main admin can deactivate an admin';
  end if;
  if target.is_active = p_active then raise exception 'The account is already %', case when p_active then 'active' else 'deactivated' end; end if;

  update public.profiles set is_active = p_active where id = p_user_id;
  if not p_active then
    update public.provider_profiles set status = 'suspended' where user_id = p_user_id and status <> 'suspended';
    get diagnostics suspended = row_count;
  end if;
  perform private.log_admin(case when p_active then 'user_reactivated' else 'user_deactivated' end, 'user', p_user_id, r,
                            jsonb_build_object('name', target.full_name, 'role', target.role, 'provider_suspended', suspended > 0));
end $$;

-- 5) Every user with status, email and last sign-in (admins only) -------------
create or replace function public.admin_users_overview(p_limit integer default 500)
returns table (
  id uuid, email text, full_name text, phone text, role public.user_role, is_active boolean, is_super_admin boolean,
  created_at timestamptz, last_sign_in_at timestamptz, email_confirmed boolean,
  provider_id uuid, provider_status text, business_name text, bookings_count bigint
) language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Admins only'; end if;
  return query
  select p.id, u.email::text, p.full_name, p.phone, p.role, p.is_active, p.is_super_admin,
         p.created_at, u.last_sign_in_at, (u.email_confirmed_at is not null),
         pp.id, pp.status::text, pp.business_name,
         (select count(*) from public.bookings b where b.customer_id = p.id)
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.provider_profiles pp on pp.user_id = p.id
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit, 500), 1), 1000);
end $$;

-- 6) Edit a user / a provider (main admin only, always logged) ---------------
create or replace function public.admin_update_user(p_user_id uuid, p_full_name text, p_phone text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.profiles; n text := nullif(btrim(coalesce(p_full_name, '')), ''); ph text := nullif(btrim(coalesce(p_phone, '')), '');
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can edit user data'; end if;
  r := private.need_reason(p_reason);
  if n is null or char_length(n) > 120 then raise exception 'Name is required (up to 120 characters)'; end if;
  if ph is not null and char_length(ph) > 40 then raise exception 'Phone is too long'; end if;
  select * into old from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  update public.profiles set full_name = n, phone = ph where id = p_user_id;
  perform private.log_admin('user_edited', 'user', p_user_id, r,
          jsonb_build_object('name', old.full_name, 'new_name', n, 'old_phone', old.phone, 'new_phone', ph));
end $$;

create or replace function public.admin_update_provider(
  p_provider_id uuid, p_business_name text, p_description text, p_phone text, p_email text, p_website text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.provider_profiles; b text := nullif(btrim(coalesce(p_business_name, '')), '');
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can edit provider data'; end if;
  r := private.need_reason(p_reason);
  if b is null or char_length(b) > 120 then raise exception 'Business name is required (up to 120 characters)'; end if;
  if char_length(coalesce(p_description, '')) > 2000 then raise exception 'Description is too long'; end if;
  select * into old from public.provider_profiles where id = p_provider_id;
  if not found then raise exception 'Provider not found'; end if;
  update public.provider_profiles set
    business_name = b,
    description   = nullif(btrim(coalesce(p_description, '')), ''),
    phone         = nullif(left(btrim(coalesce(p_phone, '')), 40), ''),
    email         = nullif(left(btrim(coalesce(p_email, '')), 200), ''),
    website       = nullif(left(btrim(coalesce(p_website, '')), 300), '')
  where id = p_provider_id;
  perform private.log_admin('provider_edited', 'provider', p_provider_id, r,
          jsonb_build_object('name', old.business_name, 'new_name', b));
end $$;

-- 7) Permissions: nobody but signed-in users, and each function re-checks the role itself
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_create_invite(text,integer)', 'public.admin_list_invites()', 'public.admin_revoke_invite(uuid)',
    'public.admin_users_overview(integer)', 'public.admin_update_user(uuid,text,text,text)',
    'public.admin_update_provider(uuid,text,text,text,text,text,text)',
    'public.admin_set_user_role(uuid,public.user_role)', 'public.admin_set_user_active(uuid,boolean,text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
revoke execute on function public.check_admin_invite(text) from public;
grant  execute on function public.check_admin_invite(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- FIRST MAIN ADMIN (one time): sign up on the admin page is not possible
-- without a code, so make yourself the main admin like this.
-- 1) create a normal account on the site (customer sign-up) and confirm the email
-- 2) run this with YOUR email:
--
--   update public.profiles
--      set role = 'admin', is_super_admin = true
--    where id = (select id from auth.users where email = 'YOUR-EMAIL@example.com');
-- ---------------------------------------------------------------------
