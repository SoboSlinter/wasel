-- =====================================================================
-- Wasel — 027
--   1) Admin permissions by role (the main admin decides what each admin can do)
--   2) Site contact details (main admin adds / edits / deletes them; everyone can read)
--   3) Backup, export and import of data (permission "data")
-- Safe to run more than once.
-- =====================================================================

-- 1) PERMISSIONS ---------------------------------------------------------
-- NULL admin_permissions = "not configured": the admin keeps the Manager set (so older admins keep working).
-- An empty list = no access at all. The main admin always has everything.
alter table public.profiles add column if not exists admin_permissions text[];
alter table public.profiles add column if not exists admin_title text;
revoke update (admin_permissions, admin_title) on public.profiles from anon, authenticated;

create or replace function private.all_perms()
returns text[] language sql immutable set search_path = '' as $$
  select array['providers','catalog','users','bookings','disputes','problems','messages','alerts','content','activity','settings','data'];
$$;

create or replace function private.perm_preset(p_name text)
returns text[] language sql immutable set search_path = '' as $$
  select case lower(coalesce(p_name, ''))
    when 'manager'  then array['providers','catalog','users','bookings','disputes','problems','messages','alerts','content','activity','settings']
    when 'support'  then array['messages','users','bookings','problems']
    when 'reviewer' then array['providers','catalog','alerts','content']
    when 'finance'  then array['bookings','disputes','problems','settings','activity']
    else array['messages','users','bookings','problems']
  end;
$$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_permissions_valid') then
    alter table public.profiles add constraint profiles_permissions_valid
      check (admin_permissions is null or admin_permissions <@ array['providers','catalog','users','bookings','disputes','problems','messages','alerts','content','activity','settings','data']::text[]);
  end if;
end $$;

-- does the signed-in admin hold this permission? (main admin: always)
create or replace function private.has_perm(p_perm text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin' and is_active = true
      and (is_super_admin or p_perm = any (coalesce(admin_permissions, private.perm_preset('manager'))))
  );
$$;
revoke execute on function private.has_perm(text) from public, anon;
grant  execute on function private.has_perm(text) to authenticated;
revoke execute on function private.perm_preset(text), private.all_perms() from public, anon;
grant  execute on function private.perm_preset(text), private.all_perms() to authenticated;

-- stops being an admin => permissions and title are cleared
create or replace function private.profiles_clear_admin()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.role <> 'admin' then new.admin_permissions := null; new.admin_title := null; end if;
  return new;
end $$;
drop trigger if exists profiles_clear_admin on public.profiles;
create trigger profiles_clear_admin before update on public.profiles
  for each row execute function private.profiles_clear_admin();

-- what the signed-in admin may open (the page uses this to show the right tabs)
create or replace function public.my_admin_access()
returns table (is_super boolean, title text, permissions text[])
language sql stable security definer set search_path = '' as $$
  select p.is_super_admin, p.admin_title,
         case when p.is_super_admin then private.all_perms()
              else coalesce(p.admin_permissions, private.perm_preset('manager')) end
  from public.profiles p
  where p.id = (select auth.uid()) and p.role = 'admin' and p.is_active;
$$;

-- the main admin sets title + permissions of another admin
create or replace function public.admin_set_permissions(p_user_id uuid, p_title text, p_permissions text[], p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; target public.profiles; perms text[];
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can change permissions'; end if;
  r := private.need_reason(p_reason);
  select * into target from public.profiles where id = p_user_id;
  if not found or target.role <> 'admin' then raise exception 'This person is not an admin'; end if;
  if target.is_super_admin then raise exception 'The main admin always has every permission'; end if;
  perms := coalesce(p_permissions, '{}');
  if not (perms <@ private.all_perms()) then raise exception 'Unknown permission'; end if;
  select coalesce(array_agg(distinct x order by x), '{}') into perms from unnest(perms) x;
  update public.profiles
     set admin_permissions = perms, admin_title = nullif(left(btrim(coalesce(p_title, '')), 40), '')
   where id = p_user_id;
  perform private.log_admin('admin_permissions', 'user', p_user_id, r,
          jsonb_build_object('name', target.full_name, 'title', p_title, 'permissions', perms,
                             'before', coalesce(target.admin_permissions, private.perm_preset('manager'))));
end $$;

-- promoting someone to admin now starts with the Support set (least access); the main admin widens it
create or replace function public.admin_set_user_role(p_user_id uuid, p_role public.user_role)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare row public.profiles; target public.profiles;
begin
  if not (select private.has_perm('users')) then raise exception 'Admins only'; end if;
  if p_user_id = (select auth.uid()) then raise exception 'You cannot change your own role'; end if;
  select * into target from public.profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
  if target.is_super_admin then raise exception 'The main admin cannot be changed'; end if;
  if (target.role = 'admin' or p_role = 'admin') and not private.is_super_admin() then
    raise exception 'Only the main admin can add or remove admins';
  end if;
  update public.profiles set role = p_role where id = p_user_id returning * into row;
  if p_role = 'admin' and target.role <> 'admin' then
    update public.profiles set admin_permissions = private.perm_preset('support'), admin_title = 'Support'
     where id = p_user_id returning * into row;
  end if;
  perform private.log_admin('user_role', 'user', p_user_id, null,
          jsonb_build_object('from', target.role, 'to', p_role, 'name', row.full_name));
  return row;
end $$;

-- invite codes now carry a title and permissions for the new admin
alter table public.admin_invites add column if not exists title text;
alter table public.admin_invites add column if not exists permissions text[];

drop function if exists public.admin_create_invite(text, integer);
create or replace function public.admin_create_invite(p_note text default null, p_days integer default 7,
                                                      p_title text default 'Support', p_permissions text[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare raw text; shown text; v_id uuid; v_exp timestamptz; perms text[];
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can create invite codes'; end if;
  if p_days is null or p_days < 1 or p_days > 30 then raise exception 'Choose between 1 and 30 days'; end if;
  perms := coalesce(p_permissions, private.perm_preset(p_title));
  if not (perms <@ private.all_perms()) then raise exception 'Unknown permission'; end if;
  raw := upper(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''));
  raw := substr(raw, 1, 32);
  shown := 'WASEL-' || substr(raw,1,8) || '-' || substr(raw,9,8) || '-' || substr(raw,17,8) || '-' || substr(raw,25,8);
  v_exp := now() + make_interval(days => p_days);
  insert into public.admin_invites (code_hash, note, created_by, expires_at, title, permissions)
  values (private.invite_hash(shown), nullif(left(btrim(coalesce(p_note, '')), 120), ''), (select auth.uid()), v_exp,
          nullif(left(btrim(coalesce(p_title, '')), 40), ''), perms)
  returning id into v_id;
  perform private.log_admin('admin_invite_created', 'invite', v_id, null,
          jsonb_build_object('note', p_note, 'expires_at', v_exp, 'title', p_title, 'permissions', perms));
  return jsonb_build_object('id', v_id, 'expires_at', v_exp, 'code', shown);
end $$;

drop function if exists public.admin_list_invites();
create or replace function public.admin_list_invites()
returns table (id uuid, note text, created_at timestamptz, expires_at timestamptz, status text, used_by_name text,
               created_by_name text, title text, permissions text[])
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can see invite codes'; end if;
  return query
  select i.id, i.note, i.created_at, i.expires_at,
         case when i.used_at is not null then 'used'
              when i.revoked_at is not null then 'revoked'
              when i.expires_at <= now() then 'expired' else 'active' end,
         u.full_name, c.full_name, i.title, i.permissions
  from public.admin_invites i
  left join public.profiles u on u.id = i.used_by
  left join public.profiles c on c.id = i.created_by
  order by i.created_at desc limit 100;
end $$;

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

  insert into public.profiles (id, full_name, role, lang, admin_permissions, admin_title)
  values (new.id, new.raw_user_meta_data ->> 'full_name', v_role,
          case when new.raw_user_meta_data ->> 'lang' = 'es' then 'es' else 'en' end,
          case when v_role = 'admin' then coalesce(v_inv.permissions, private.perm_preset('support')) end,
          case when v_role = 'admin' then coalesce(v_inv.title, 'Support') end);

  if v_role = 'admin' then
    update public.admin_invites set used_by = new.id, used_at = now() where id = v_inv.id;
    insert into public.admin_audit (admin_id, action, target_type, target_id, details)
    values (v_inv.created_by, 'admin_invite_used', 'user', new.id,
            jsonb_build_object('invite', v_inv.id, 'name', new.raw_user_meta_data ->> 'full_name'));
  end if;
  return new;
end $$;

-- users overview now also shows title + permissions of admins
drop function if exists public.admin_users_overview(integer);
create or replace function public.admin_users_overview(p_limit integer default 500)
returns table (
  id uuid, email text, full_name text, phone text, role public.user_role, is_active boolean, is_super_admin boolean,
  created_at timestamptz, last_sign_in_at timestamptz, email_confirmed boolean,
  provider_id uuid, provider_status text, business_name text, bookings_count bigint,
  admin_title text, admin_permissions text[]
) language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.has_perm('users') or private.is_super_admin()) then raise exception 'Admins only'; end if;
  return query
  select p.id, u.email::text, p.full_name, p.phone, p.role, p.is_active, p.is_super_admin,
         p.created_at, u.last_sign_in_at, (u.email_confirmed_at is not null),
         pp.id, pp.status::text, pp.business_name,
         (select count(*) from public.bookings b where b.customer_id = p.id),
         p.admin_title,
         case when p.role <> 'admin' then null
              when p.is_super_admin then private.all_perms()
              else coalesce(p.admin_permissions, private.perm_preset('manager')) end
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.provider_profiles pp on pp.user_id = p.id
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit, 500), 1), 1000);
end $$;

-- every other admin function / read rule now asks for its own permission instead of "any admin"
do $$
declare
  m jsonb := '{
    "admin_alerts_list":"alerts","admin_handle_alert":"alerts",
    "admin_rating_policy":"settings","admin_update_rating_policy":"settings","admin_update_fees":"settings",
    "admin_audit_log":"activity",
    "admin_cancel_booking":"bookings",
    "admin_catalog_list":"catalog","admin_create_catalog_item":"catalog","admin_delete_catalog_item":"catalog",
    "admin_update_catalog_item":"catalog","admin_review_service":"catalog","admin_service_queue":"catalog",
    "admin_request_service_info":"catalog","admin_set_service_status":"catalog",
    "admin_contact_handled":"messages","admin_contact_messages":"messages",
    "admin_content":"content","admin_remove_review":"content",
    "admin_problems":"problems","admin_resolve_problem":"problems",
    "admin_provider_extras":"providers","admin_review_provider":"providers","admin_set_provider_status":"providers",
    "admin_set_user_active":"users"}'::jsonb;
  k text; oid_ oid; def text;
begin
  for k in select jsonb_object_keys(m) loop
    for oid_ in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = k loop
      def := pg_get_functiondef(oid_);
      if def like '%private.has_perm(%' then continue; end if;          -- already converted (re-run)
      if def not like '%private.is_admin()%' then raise exception 'function % does not check is_admin()', k; end if;
      execute replace(def, 'private.is_admin()', format('private.has_perm(%L)', m ->> k));
    end loop;
  end loop;

  -- disputes list checks the role inline
  select p.oid into oid_ from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_disputes';
  def := pg_get_functiondef(oid_);
  if def not like '%private.has_perm(%' then
    def := regexp_replace(def, 'exists \(select 1 from public\.profiles me where me\.id = \(select auth\.uid\(\)\) and me\.role = ''admin''\)',
                          'private.has_perm(''disputes'')');
    if def not like '%private.has_perm(%' then raise exception 'admin_disputes not converted'; end if;
    execute def;
  end if;
end $$;

do $$
declare pol record; perm text; q text; w text; clause text := '';
begin
  for pol in select schemaname, tablename, policyname, qual, with_check from pg_policies
              where qual like '%private.is_admin()%' or with_check like '%private.is_admin()%' loop
    perm := case
      when pol.tablename = 'profiles' then 'users'
      when pol.tablename in ('provider_profiles','provider_private','provider_applications','provider_documents') then 'providers'
      when pol.tablename in ('services','service_photos','service_catalog') then 'catalog'
      when pol.tablename in ('bookings','payments','subscriptions','booking_messages','booking_work_photos') then 'bookings'
      when pol.tablename = 'customer_reviews' then 'content'
      when pol.tablename = 'objects' and pol.policyname = 'Owner and admins read documents' then 'providers'
      when pol.tablename = 'objects' and pol.policyname = 'Booking people read work photo files' then 'bookings'
      else null end;
    if perm is null then raise exception 'No permission mapped for policy % on %', pol.policyname, pol.tablename; end if;
    clause := '';
    if pol.qual like '%private.is_admin()%' then
      clause := clause || format(' using (%s)', replace(pol.qual, 'private.is_admin()', format('private.has_perm(%L)', perm)));
    end if;
    if pol.with_check like '%private.is_admin()%' then
      clause := clause || format(' with check (%s)', replace(pol.with_check, 'private.is_admin()', format('private.has_perm(%L)', perm)));
    end if;
    execute format('alter policy %I on %I.%I%s', pol.policyname, pol.schemaname, pol.tablename, clause);
  end loop;
end $$;

-- the Stripe price function (service role) now needs the "settings" permission
create or replace function public.check_admin(p_user_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = p_user_id and role = 'admin' and is_active
      and (is_super_admin or 'settings' = any (coalesce(admin_permissions, private.perm_preset('manager'))))
  );
$$;

-- 2) SITE CONTACT DETAILS -------------------------------------------------
create table if not exists public.site_contacts (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('email','phone','whatsapp','address','hours','website','social','other')),
  label       text not null check (char_length(btrim(label)) between 1 and 60),
  value       text not null check (char_length(btrim(value)) between 1 and 200),
  sort_order  integer not null default 0 check (sort_order between 0 and 999),
  is_public   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.site_contacts enable row level security;
revoke all on public.site_contacts from anon, authenticated;
grant select on public.site_contacts to anon, authenticated;
drop policy if exists "Public contact details are visible" on public.site_contacts;
create policy "Public contact details are visible" on public.site_contacts
  for select to anon, authenticated using (is_public);
drop policy if exists "Main admin reads all contact details" on public.site_contacts;
create policy "Main admin reads all contact details" on public.site_contacts
  for select to authenticated using ((select private.is_super_admin()));

create or replace function private.check_contact(p_kind text, p_value text)
returns void language plpgsql immutable set search_path = '' as $$
declare v text := btrim(coalesce(p_value, ''));
begin
  if p_kind = 'email' and v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  if p_kind in ('phone','whatsapp') and v !~ '^[0-9+()\-\s.]{7,25}$' then raise exception 'Enter a valid phone number.'; end if;
  if p_kind in ('website','social') and v !~* '^https?://[^\s]+$' then raise exception 'The link must start with https://'; end if;
end $$;

create or replace function public.admin_save_site_contact(p_id uuid, p_kind text, p_label text, p_value text,
                                                          p_sort integer, p_public boolean, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r text; v_id uuid;
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can change the contact details'; end if;
  r := private.need_reason(p_reason);
  perform private.check_contact(p_kind, p_value);
  if p_id is null then
    if (select count(*) from public.site_contacts) >= 30 then raise exception 'You can keep at most 30 contact details'; end if;
    insert into public.site_contacts (kind, label, value, sort_order, is_public)
    values (p_kind, btrim(p_label), btrim(p_value), coalesce(p_sort, 0), coalesce(p_public, true)) returning id into v_id;
    perform private.log_admin('contact_added', 'site_contact', v_id, r, jsonb_build_object('kind', p_kind, 'label', p_label));
  else
    update public.site_contacts
       set kind = p_kind, label = btrim(p_label), value = btrim(p_value), sort_order = coalesce(p_sort, 0),
           is_public = coalesce(p_public, true), updated_at = now()
     where id = p_id returning id into v_id;
    if v_id is null then raise exception 'That contact detail no longer exists'; end if;
    perform private.log_admin('contact_updated', 'site_contact', v_id, r, jsonb_build_object('kind', p_kind, 'label', p_label));
  end if;
  return v_id;
end $$;

create or replace function public.admin_delete_site_contact(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.site_contacts;
begin
  if not private.is_super_admin() then raise exception 'Only the main admin can change the contact details'; end if;
  r := private.need_reason(p_reason);
  delete from public.site_contacts where id = p_id returning * into old;
  if not found then raise exception 'That contact detail no longer exists'; end if;
  perform private.log_admin('contact_deleted', 'site_contact', p_id, r, jsonb_build_object('kind', old.kind, 'label', old.label));
end $$;

-- 3) BACKUP / EXPORT / IMPORT ---------------------------------------------
-- Export returns the rows as JSON. Every export is written to the activity log.
create or replace function public.admin_export_data(p_dataset text, p_purpose text default 'export')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare out jsonb;
begin
  if not private.has_perm('data') then raise exception 'You do not have the data permission'; end if;
  if p_dataset = 'catalog' then
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'description', description, 'category', category,
           'suggested_price', suggested_price, 'default_duration_minutes', default_duration_minutes, 'is_active', is_active)
           order by category, name), '[]') into out from public.service_catalog;
  elsif p_dataset = 'contacts' then
    select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'label', label, 'value', value, 'sort_order', sort_order,
           'is_public', is_public) order by sort_order, label), '[]') into out from public.site_contacts;
  elsif p_dataset = 'settings' then
    select coalesce(jsonb_agg(jsonb_build_object('free_fee_percent', free_fee_percent, 'pro_fee_percent', pro_fee_percent,
           'alert_min_reviews', alert_min_reviews, 'alert_max_avg', alert_max_avg)), '[]') into out from public.platform_settings;
  elsif p_dataset = 'providers' then
    select coalesce(jsonb_agg(to_jsonb(pp) order by pp.created_at), '[]') into out from public.provider_profiles pp;
  elsif p_dataset = 'services' then
    select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at), '[]') into out from public.services s;
  elsif p_dataset = 'users' then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'email', u.email, 'full_name', p.full_name, 'phone', p.phone,
           'role', p.role, 'is_active', p.is_active, 'created_at', p.created_at) order by p.created_at), '[]')
      into out from public.profiles p join auth.users u on u.id = p.id;
  elsif p_dataset = 'bookings' then
    select coalesce(jsonb_agg(to_jsonb(b) order by b.created_at), '[]') into out from public.bookings b;
  elsif p_dataset = 'messages' then
    select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]') into out from public.contact_messages m;
  else
    raise exception 'Unknown dataset';
  end if;
  perform private.log_admin(case when p_purpose = 'backup' then 'data_backup' else 'data_export' end, 'dataset', null, null,
          jsonb_build_object('dataset', p_dataset, 'rows', jsonb_array_length(out)));
  return out;
end $$;

-- Import (all or nothing). Only data that is safe to restore: catalog, contact details, fee/alert settings.
create or replace function public.admin_import_data(p_dataset text, p_rows jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r text; el jsonb; ins int := 0; upd int := 0; n int; v_id uuid;
begin
  if not private.has_perm('data') then raise exception 'You do not have the data permission'; end if;
  r := private.need_reason(p_reason);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'The file must contain a list of rows'; end if;
  n := jsonb_array_length(p_rows);
  if n = 0 then raise exception 'The file has no rows'; end if;
  if n > 1000 then raise exception 'Import at most 1000 rows at a time'; end if;

  if p_dataset = 'catalog' then
    if not private.has_perm('catalog') then raise exception 'You also need the catalog permission'; end if;
    for el in select * from jsonb_array_elements(p_rows) loop
      update public.service_catalog
         set description = nullif(el ->> 'description', ''),
             suggested_price = nullif(el ->> 'suggested_price', '')::numeric,
             default_duration_minutes = coalesce(nullif(el ->> 'default_duration_minutes', '')::int, default_duration_minutes),
             is_active = coalesce((el ->> 'is_active')::boolean, is_active), updated_at = now()
       where lower(btrim(name)) = lower(btrim(el ->> 'name')) and category = el ->> 'category'
       returning id into v_id;
      if v_id is not null then upd := upd + 1; v_id := null;
      else
        insert into public.service_catalog (name, description, category, suggested_price, default_duration_minutes, is_active, created_by)
        values (btrim(el ->> 'name'), nullif(el ->> 'description', ''), el ->> 'category',
                nullif(el ->> 'suggested_price', '')::numeric, coalesce(nullif(el ->> 'default_duration_minutes', '')::int, 60),
                coalesce((el ->> 'is_active')::boolean, true), (select auth.uid()));
        ins := ins + 1;
      end if;
    end loop;
  elsif p_dataset = 'contacts' then
    if not private.is_super_admin() then raise exception 'Only the main admin can import contact details'; end if;
    for el in select * from jsonb_array_elements(p_rows) loop
      perform private.check_contact(el ->> 'kind', el ->> 'value');
      update public.site_contacts
         set sort_order = coalesce(nullif(el ->> 'sort_order', '')::int, sort_order),
             is_public = coalesce((el ->> 'is_public')::boolean, is_public), updated_at = now()
       where kind = el ->> 'kind' and lower(label) = lower(btrim(el ->> 'label')) and value = btrim(el ->> 'value')
       returning id into v_id;
      if v_id is not null then upd := upd + 1; v_id := null;
      else
        insert into public.site_contacts (kind, label, value, sort_order, is_public)
        values (el ->> 'kind', btrim(el ->> 'label'), btrim(el ->> 'value'),
                coalesce(nullif(el ->> 'sort_order', '')::int, 0), coalesce((el ->> 'is_public')::boolean, true));
        ins := ins + 1;
      end if;
    end loop;
    if (select count(*) from public.site_contacts) > 30 then raise exception 'You can keep at most 30 contact details'; end if;
  elsif p_dataset = 'settings' then
    if not private.has_perm('settings') then raise exception 'You also need the settings permission'; end if;
    el := p_rows -> 0;
    update public.platform_settings
       set free_fee_percent = coalesce(nullif(el ->> 'free_fee_percent', '')::numeric, free_fee_percent),
           pro_fee_percent = coalesce(nullif(el ->> 'pro_fee_percent', '')::numeric, pro_fee_percent),
           alert_min_reviews = coalesce(nullif(el ->> 'alert_min_reviews', '')::int, alert_min_reviews),
           alert_max_avg = coalesce(nullif(el ->> 'alert_max_avg', '')::numeric, alert_max_avg),
           updated_at = now()
     where id;
    upd := 1;
  else
    raise exception 'This kind of data cannot be imported';
  end if;
  perform private.log_admin('data_import', 'dataset', null, r, jsonb_build_object('dataset', p_dataset, 'inserted', ins, 'updated', upd));
  return jsonb_build_object('inserted', ins, 'updated', upd);
end $$;

-- 4) Who may call what ------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.my_admin_access()', 'public.admin_set_permissions(uuid,text,text[],text)',
    'public.admin_set_user_role(uuid,public.user_role)',
    'public.admin_create_invite(text,integer,text,text[])', 'public.admin_list_invites()',
    'public.admin_users_overview(integer)',
    'public.admin_save_site_contact(uuid,text,text,text,integer,boolean,text)',
    'public.admin_delete_site_contact(uuid,text)',
    'public.admin_export_data(text,text)', 'public.admin_import_data(text,jsonb,text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
revoke execute on function public.check_admin(uuid) from public, anon, authenticated;
grant  execute on function public.check_admin(uuid) to service_role;
revoke execute on function private.check_contact(text, text) from public, anon;
