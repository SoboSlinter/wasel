-- =====================================================================
-- Wasel — 028  Provider profile changes need the admin's approval
--   An approved provider asks for a change (with supporting documents if any);
--   an admin with the "providers" permission approves or rejects it.
--   Providers still waiting for approval keep editing directly. Safe to run twice.
-- =====================================================================

create table if not exists public.provider_change_requests (
  id           uuid primary key default gen_random_uuid(),
  provider_id  uuid not null references public.provider_profiles(id) on delete cascade,
  changes      jsonb not null check (jsonb_typeof(changes) = 'object' and changes <> '{}'::jsonb),
  note         text check (note is null or char_length(note) <= 500),
  status       text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  admin_note   text check (admin_note is null or char_length(admin_note) <= 500),
  reviewed_by  uuid references public.profiles(id) on delete set null,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now()
);
create unique index if not exists provider_change_one_pending on public.provider_change_requests (provider_id) where status = 'pending';
create index if not exists provider_change_status_idx on public.provider_change_requests (status, created_at desc);
alter table public.provider_change_requests enable row level security;
revoke all on public.provider_change_requests from public, anon, authenticated;
grant select on public.provider_change_requests to authenticated;
drop policy if exists "Owner reads own change requests" on public.provider_change_requests;
create policy "Owner reads own change requests" on public.provider_change_requests for select to authenticated
  using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
drop policy if exists "Admins read change requests" on public.provider_change_requests;
create policy "Admins read change requests" on public.provider_change_requests for select to authenticated
  using ((select private.has_perm('providers')));

-- supporting documents are linked to the request they belong to
alter table public.provider_documents add column if not exists request_id uuid references public.provider_change_requests(id) on delete set null;

-- room for supporting documents: 12 business documents instead of 8
create or replace function private.limit_documents() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.service_id is null then
    if (select count(*) from public.provider_documents where provider_id = new.provider_id and service_id is null) >= 12 then
      raise exception 'You can upload up to 12 documents for your business.';
    end if;
  elsif (select count(*) from public.provider_documents where service_id = new.service_id) >= 5 then
    raise exception 'You can upload up to 5 documents for one service.';
  end if;
  return new;
end $$;

-- an APPROVED provider can no longer write the profile directly: the change goes through a request
drop policy if exists "Approved providers use change requests" on public.provider_profiles;
create policy "Approved providers use change requests" on public.provider_profiles as restrictive for update to authenticated
  using (status <> 'approved' or (select private.has_perm('providers')));
drop policy if exists "Approved providers use change requests (private)" on public.provider_private;
create policy "Approved providers use change requests (private)" on public.provider_private as restrictive for update to authenticated
  using (not exists (select 1 from public.provider_profiles p where p.id = provider_id and p.status = 'approved') or (select private.has_perm('providers')));

-- the fields a request may change
create or replace function private.change_fields() returns text[] language sql immutable set search_path = '' as $$
  select array['business_name','description','phone','email','address','city','state','zip_code','business_type',
               'categories','years_experience','languages','website','license_info'];
$$;
revoke all on function private.change_fields() from public, anon, authenticated;

-- checks the values of a change set. Returns the clean version.
create or replace function private.clean_changes(p jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare k text; v jsonb; res jsonb := '{}'::jsonb; t text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Nothing to change.'; end if;
  for k, v in select * from jsonb_each(p) loop
    if not (k = any (private.change_fields())) then raise exception 'You cannot change "%" this way.', k; end if;
    if k in ('categories','languages') then
      if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) > 8 then raise exception 'Too many values for %.', k; end if;
      res := res || jsonb_build_object(k, v);
    elsif jsonb_typeof(v) = 'null' then
      if k = 'business_name' then raise exception 'The business name cannot be empty.'; end if;
      res := res || jsonb_build_object(k, null);
    elsif k = 'years_experience' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric not between 0 and 60 then raise exception 'Years of experience must be between 0 and 60.'; end if;
      res := res || jsonb_build_object(k, v);
    else
      if jsonb_typeof(v) <> 'string' then raise exception 'Invalid value for %.', k; end if;
      t := btrim(v #>> '{}');
      if t = '' then
        if k = 'business_name' then raise exception 'The business name cannot be empty.'; end if;
        res := res || jsonb_build_object(k, null);
      else
        if char_length(t) > (select case k when 'description' then 1000 when 'license_info' then 300 else 160 end) then raise exception 'Value for % is too long.', k; end if;
        if k = 'email' and t !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
        if k = 'phone' and t !~ '^[0-9+()\-\s.]{7,25}$' then raise exception 'Enter a valid phone number.'; end if;
        if k = 'website' and t !~* '^https?://[^\s]+$' then raise exception 'The website must start with https://'; end if;
        if k = 'business_type' and t not in ('individual','company') then raise exception 'Invalid business type.'; end if;
        res := res || jsonb_build_object(k, t);
      end if;
    end if;
  end loop;
  if res = '{}'::jsonb then raise exception 'Nothing to change.'; end if;
  return res;
end $$;
revoke all on function private.clean_changes(jsonb) from public, anon, authenticated;

-- provider: ask for a change
create or replace function public.submit_provider_change(p_changes jsonb, p_note text default null, p_doc_ids uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = '' as $$
declare pr public.provider_profiles; v_id uuid; clean jsonb; n int;
begin
  select * into pr from public.provider_profiles where user_id = (select auth.uid());
  if not found then raise exception 'You have no provider account.'; end if;
  if not (select private.account_active()) then raise exception 'Your account is switched off.'; end if;
  if pr.status <> 'approved' then raise exception 'Your profile is still being reviewed: you can edit it directly.'; end if;
  if exists (select 1 from public.provider_change_requests where provider_id = pr.id and status = 'pending') then
    raise exception 'You already have a change waiting for approval. Cancel it first to send a new one.';
  end if;
  clean := private.clean_changes(p_changes);
  if p_note is not null and char_length(btrim(p_note)) > 500 then raise exception 'Please keep the note under 500 characters.'; end if;
  insert into public.provider_change_requests (provider_id, changes, note)
  values (pr.id, clean, nullif(btrim(coalesce(p_note, '')), '')) returning id into v_id;
  if coalesce(cardinality(p_doc_ids), 0) > 0 then
    update public.provider_documents set request_id = v_id
     where id = any (p_doc_ids) and provider_id = pr.id and service_id is null and kind = 'other' and request_id is null;
    get diagnostics n = row_count;
    if n <> cardinality(p_doc_ids) then raise exception 'One of the documents could not be attached.'; end if;
  end if;
  return v_id;
end $$;

-- provider: take the request back
create or replace function public.cancel_provider_change(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.provider_change_requests c set status = 'cancelled', reviewed_at = now()
   where c.id = p_id and c.status = 'pending'
     and exists (select 1 from public.provider_profiles p where p.id = c.provider_id and p.user_id = (select auth.uid()));
  if not found then raise exception 'That request is no longer waiting.'; end if;
end $$;

-- admin: the list (with the current values next to the requested ones, and the supporting documents)
create or replace function public.admin_change_requests(p_status text default 'pending')
returns table (id uuid, provider_id uuid, business_name text, status text, changes jsonb, current jsonb, note text, admin_note text,
               created_at timestamptz, reviewed_at timestamptz, docs jsonb)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.has_perm('providers') then raise exception 'Not allowed'; end if;
  return query
  select c.id, c.provider_id, pr.business_name, c.status, c.changes,
         (select jsonb_object_agg(k, case k
              when 'license_info' then to_jsonb(pv.license_info)
              else to_jsonb(pr) -> k end)
            from jsonb_object_keys(c.changes) k),
         c.note, c.admin_note, c.created_at, c.reviewed_at,
         coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'file_name', d.file_name, 'storage_path', d.storage_path, 'kind', d.kind) order by d.created_at)
                     from public.provider_documents d where d.request_id = c.id), '[]'::jsonb)
  from public.provider_change_requests c
  join public.provider_profiles pr on pr.id = c.provider_id
  left join public.provider_private pv on pv.provider_id = c.provider_id
  where (p_status = 'all' or c.status = p_status)
  order by c.created_at desc limit 200;
end $$;

-- admin: approve (applies the change) or reject (needs a reason)
create or replace function public.admin_review_change(p_id uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.provider_change_requests; r text; ch jsonb; pr public.provider_profiles;
begin
  if not private.has_perm('providers') then raise exception 'Not allowed'; end if;
  if p_action not in ('approve','reject') then raise exception 'Unknown action'; end if;
  select * into c from public.provider_change_requests where id = p_id for update;
  if not found or c.status <> 'pending' then raise exception 'That request is no longer waiting.'; end if;
  if p_action = 'reject' then
    r := private.need_reason(p_note);
    update public.provider_change_requests set status = 'rejected', admin_note = r, reviewed_by = (select auth.uid()), reviewed_at = now() where id = p_id;
  else
    r := nullif(btrim(coalesce(p_note, '')), '');
    if r is not null and char_length(r) > 500 then raise exception 'Please keep the note under 500 characters.'; end if;
    ch := private.clean_changes(c.changes);
    select * into pr from public.provider_profiles where id = c.provider_id for update;
    update public.provider_profiles set
      business_name    = case when ch ? 'business_name'    then ch ->> 'business_name'    else business_name end,
      description      = case when ch ? 'description'      then ch ->> 'description'      else description end,
      phone            = case when ch ? 'phone'            then ch ->> 'phone'            else phone end,
      email            = case when ch ? 'email'            then ch ->> 'email'            else email end,
      address          = case when ch ? 'address'          then ch ->> 'address'          else address end,
      city             = case when ch ? 'city'             then ch ->> 'city'             else city end,
      state            = case when ch ? 'state'            then ch ->> 'state'            else state end,
      zip_code         = case when ch ? 'zip_code'         then ch ->> 'zip_code'         else zip_code end,
      business_type    = case when ch ? 'business_type'    then ch ->> 'business_type'    else business_type end,
      website          = case when ch ? 'website'          then ch ->> 'website'          else website end,
      years_experience = case when ch ? 'years_experience' then (ch ->> 'years_experience')::int else years_experience end,
      categories       = case when ch ? 'categories'       then (select nullif(array_agg(x), '{}') from jsonb_array_elements_text(ch -> 'categories') x) else categories end,
      languages        = case when ch ? 'languages'        then (select nullif(array_agg(x), '{}') from jsonb_array_elements_text(ch -> 'languages') x) else languages end
    where id = c.provider_id;
    if ch ? 'license_info' then
      update public.provider_private set license_info = ch ->> 'license_info' where provider_id = c.provider_id;
    end if;
    update public.provider_change_requests set status = 'approved', admin_note = r, reviewed_by = (select auth.uid()), reviewed_at = now() where id = p_id;
  end if;
  perform private.log_admin(case p_action when 'approve' then 'provider_change_approved' else 'provider_change_rejected' end,
    'provider', c.provider_id, r, jsonb_build_object('fields', (select jsonb_agg(k) from jsonb_object_keys(c.changes) k)));
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.submit_provider_change(jsonb,text,uuid[])','public.cancel_provider_change(uuid)',
                           'public.admin_change_requests(text)','public.admin_review_change(uuid,text,text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
