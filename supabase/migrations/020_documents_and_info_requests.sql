-- =========================================================
-- WASEL MVP — Documents and "more information" requests
--
--   * A provider applying to join uploads documents: an ID, and a license OR proof of insurance.
--   * A provider adding a service uploads at least one supporting document for it.
--   * An admin reviewing an application (or a service) can APPROVE, REJECT (with a reason) or
--     ask for MORE INFORMATION / DOCUMENTS (with a message). The provider answers and sends it back.
--   * An application cannot be approved without its documents, and a service cannot be approved without one.
--   * Emails: the admins hear about each new / re-sent application; the provider hears about every decision.
--
-- Documents live in a PRIVATE bucket ("provider-docs"): only the owner and the admins can read them.
-- Upload path convention (the first folder MUST be the uploader's user id):  <auth user id>/<kind>/<random>-<file name>
-- Run AFTER 019.
-- =========================================================

-- ---------- 1) the state of a provider's application (kept private: the provider page is public) ----------
create table if not exists public.provider_applications (
  provider_id  uuid primary key references public.provider_profiles(id) on delete cascade,
  state        text not null default 'submitted' check (state in ('submitted', 'needs_info', 'rejected', 'approved')),
  note         text check (note is null or char_length(note) <= 500),   -- the admin's message to the provider
  submitted_at timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid references auth.users(id) on delete set null
);
alter table public.provider_applications enable row level security;
revoke all on public.provider_applications from public, anon, authenticated;
grant select on public.provider_applications to authenticated;     -- writes only through the functions below
create policy "Owner reads own application" on public.provider_applications for select to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Admins read applications" on public.provider_applications for select to authenticated
using ((select private.is_admin()));

-- providers that exist today keep the state they have; new ones start as "submitted"
insert into public.provider_applications (provider_id, state)
select p.id, case when p.status = 'pending' then 'submitted' else 'approved' end from public.provider_profiles p
on conflict do nothing;

create or replace function private.application_for_new_provider() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.provider_applications (provider_id, state)
  values (new.id, case when new.status = 'approved' then 'approved' else 'submitted' end)
  on conflict do nothing;
  return new;
end $$;
revoke all on function private.application_for_new_provider() from public, anon, authenticated;
drop trigger if exists provider_profiles_application on public.provider_profiles;
create trigger provider_profiles_application after insert on public.provider_profiles
for each row execute function private.application_for_new_provider();

-- ---------- 2) documents ----------
create table if not exists public.provider_documents (
  id           uuid primary key default gen_random_uuid(),
  provider_id  uuid not null references public.provider_profiles(id) on delete cascade,
  service_id   uuid references public.services(id) on delete cascade,
  kind         text not null check (kind in ('id', 'license', 'insurance', 'other', 'service')),
  storage_path text not null unique check (char_length(storage_path) between 10 and 300),
  file_name    text not null check (char_length(file_name) between 1 and 150),
  size_bytes   integer check (size_bytes is null or size_bytes between 1 and 10485760),
  created_at   timestamptz not null default now(),
  check ((kind = 'service') = (service_id is not null))
);
create index if not exists provider_documents_provider_idx on public.provider_documents (provider_id);
create index if not exists provider_documents_service_idx on public.provider_documents (service_id) where service_id is not null;
alter table public.provider_documents enable row level security;
revoke all on public.provider_documents from public, anon, authenticated;
grant select, delete on public.provider_documents to authenticated;
grant insert (provider_id, service_id, kind, storage_path, file_name, size_bytes) on public.provider_documents to authenticated;

create policy "Owner reads own documents" on public.provider_documents for select to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Admins read documents" on public.provider_documents for select to authenticated
using ((select private.is_admin()));

-- the file must sit in the uploader's own folder, and a service document must belong to the uploader's own service
create policy "Owner adds documents" on public.provider_documents for insert to authenticated
with check (
  exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid()))
  and storage_path like (select auth.uid())::text || '/%'
  and (service_id is null or exists (select 1 from public.services s where s.id = service_id and s.provider_id = provider_documents.provider_id))
);
create policy "Active accounts only (documents)" on public.provider_documents as restrictive for insert to authenticated
with check ((select private.account_active()));

-- ID / license / insurance can't be removed after approval (the admin relied on them); service documents and "other" can
create policy "Owner removes documents" on public.provider_documents for delete to authenticated
using (
  exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid()))
  and (kind in ('service', 'other') or exists (select 1 from public.provider_applications a where a.provider_id = provider_documents.provider_id and a.state <> 'approved'))
);

create or replace function private.limit_documents() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.service_id is null then
    if (select count(*) from public.provider_documents where provider_id = new.provider_id and service_id is null) >= 8 then
      raise exception 'You can upload up to 8 documents for your business.';
    end if;
  elsif (select count(*) from public.provider_documents where service_id = new.service_id) >= 5 then
    raise exception 'You can upload up to 5 documents for one service.';
  end if;
  return new;
end $$;
revoke all on function private.limit_documents() from public, anon, authenticated;
drop trigger if exists provider_documents_limit on public.provider_documents;
create trigger provider_documents_limit before insert on public.provider_documents
for each row execute function private.limit_documents();

-- what must an application contain before it can be approved?  an ID + (a license or proof of insurance)
create or replace function private.missing_provider_docs(p_provider uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select array_remove(array[
    case when not exists (select 1 from public.provider_documents d where d.provider_id = p_provider and d.kind = 'id') then 'an ID' end,
    case when not exists (select 1 from public.provider_documents d where d.provider_id = p_provider and d.kind in ('license', 'insurance')) then 'a license or proof of insurance' end
  ], null);
$$;
revoke all on function private.missing_provider_docs(uuid) from public, anon, authenticated;

-- private storage bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('provider-docs', 'provider-docs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "Owner uploads own documents" on storage.objects for insert to authenticated
with check (bucket_id = 'provider-docs' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Owner and admins read documents" on storage.objects for select to authenticated
using (bucket_id = 'provider-docs' and ((storage.foldername(name))[1] = (select auth.uid())::text or (select private.is_admin())));
create policy "Owner deletes own documents" on storage.objects for delete to authenticated
using (bucket_id = 'provider-docs' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------- 3) the admin decides on a provider application ----------
create or replace function public.admin_review_provider(p_provider_id uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare pr public.provider_profiles; app public.provider_applications; r text; missing text[];
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  if p_action not in ('approve', 'reject', 'request_info') then raise exception 'Unknown action'; end if;
  select * into pr from public.provider_profiles where id = p_provider_id for update;
  if not found then raise exception 'Provider not found'; end if;
  select * into app from public.provider_applications where provider_id = p_provider_id for update;
  if pr.status <> 'pending' or app.state = 'approved' then raise exception 'This application was already approved.'; end if;

  if p_action = 'approve' then
    missing := private.missing_provider_docs(p_provider_id);
    if cardinality(missing) > 0 then raise exception 'Cannot approve yet: the application is missing %.', array_to_string(missing, ' and '); end if;
    r := nullif(btrim(coalesce(p_note, '')), '');
    if r is not null and char_length(r) > 500 then raise exception 'Please keep the note under 500 characters.'; end if;
    update public.provider_profiles set status = 'approved' where id = p_provider_id;
    update public.provider_applications set state = 'approved', note = r, reviewed_at = now(), reviewed_by = (select auth.uid()) where provider_id = p_provider_id;
  else
    r := private.need_reason(p_note);
    update public.provider_applications
    set state = case when p_action = 'reject' then 'rejected' else 'needs_info' end, note = r, reviewed_at = now(), reviewed_by = (select auth.uid())
    where provider_id = p_provider_id;
  end if;
  perform private.log_admin(case p_action when 'approve' then 'provider_approved' when 'reject' then 'provider_rejected' else 'provider_info_requested' end,
    'provider', p_provider_id, r, jsonb_build_object('business', pr.business_name));
end $$;
revoke all on function public.admin_review_provider(uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_review_provider(uuid, text, text) to authenticated;

-- the provider answers a "more information" request and sends the application back
create or replace function public.resubmit_application()
returns void language plpgsql security definer set search_path = '' as $$
declare pid uuid;
begin
  if not private.account_active() then raise exception 'You cannot do this right now. If your account was deactivated, please contact us.'; end if;
  select id into pid from public.provider_profiles where user_id = (select auth.uid());
  if pid is null then raise exception 'Provider profile not found'; end if;
  update public.provider_applications set state = 'submitted', note = null, submitted_at = now(), reviewed_at = null, reviewed_by = null
  where provider_id = pid and state = 'needs_info';
  if not found then raise exception 'There is nothing to send again.'; end if;
end $$;
revoke all on function public.resubmit_application() from public, anon, authenticated;
grant execute on function public.resubmit_application() to authenticated;

-- approving a waiting provider goes through admin_review_provider (it checks the documents);
-- this older function still suspends and reinstates
create or replace function public.admin_set_provider_status(p_provider_id uuid, p_status public.provider_status)
returns public.provider_profiles language plpgsql security definer set search_path = '' as $$
declare row public.provider_profiles; old_status public.provider_status;
begin
  if not (select private.is_admin()) then raise exception 'Admins only'; end if;
  select status into old_status from public.provider_profiles where id = p_provider_id;
  if old_status = 'pending' and p_status = 'approved' then raise exception 'Review the application to approve it (documents are checked there).'; end if;
  update public.provider_profiles set status = p_status where id = p_provider_id returning * into row;
  if not found then raise exception 'Provider not found'; end if;
  perform private.log_admin('provider_status', 'provider', p_provider_id, null, jsonb_build_object('from', old_status, 'to', p_status, 'business', row.business_name));
  return row;
end $$;

-- ---------- 4) services: "more information" state, documents required ----------
alter table public.services drop constraint if exists services_approval_check;
alter table public.services add constraint services_approval_check check (approval in ('pending', 'approved', 'rejected', 'needs_info'));

drop function if exists public.admin_service_queue();
create or replace function public.admin_service_queue()
returns table (id uuid, name text, description text, category text, price numeric, duration_minutes integer,
               business_name text, provider_status text, photo_count bigint, created_at timestamptz, updated_at timestamptz, doc_count bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select s.id, s.name, s.description, s.category::text, s.price, s.duration_minutes, pp.business_name, pp.status::text,
           (select count(*) from public.service_photos ph where ph.service_id = s.id), s.created_at, s.updated_at,
           (select count(*) from public.provider_documents d where d.service_id = s.id)
    from public.services s join public.provider_profiles pp on pp.id = s.provider_id
    where s.approval = 'pending'
    order by s.updated_at asc;
end $$;
revoke all on function public.admin_service_queue() from public, anon, authenticated;
grant execute on function public.admin_service_queue() to authenticated;

-- approving needs at least one supporting document
create or replace function public.admin_review_service(p_service_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services; r text;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  select * into s from public.services where id = p_service_id for update;
  if not found then raise exception 'Service not found'; end if;
  if s.approval <> 'pending' then raise exception 'This service is not waiting for review.'; end if;
  if p_approve then
    if not exists (select 1 from public.provider_documents d where d.service_id = p_service_id) then
      raise exception 'Cannot approve yet: the provider has not uploaded a supporting document for this service.';
    end if;
    r := nullif(btrim(coalesce(p_note, '')), '');
    if r is not null and char_length(r) > 500 then raise exception 'Please keep the note under 500 characters.'; end if;
  else
    r := private.need_reason(p_note);
  end if;
  update public.services
  set approval = case when p_approve then 'approved' else 'rejected' end,
      approval_note = r, reviewed_at = now(), reviewed_by = (select auth.uid())
  where id = p_service_id;
  perform private.log_admin(case when p_approve then 'service_approved' else 'service_rejected' end, 'service', p_service_id, r,
    jsonb_build_object('name', s.name, 'price', s.price, 'provider_id', s.provider_id));
end $$;

create or replace function public.admin_request_service_info(p_service_id uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services; r text;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  select * into s from public.services where id = p_service_id for update;
  if not found then raise exception 'Service not found'; end if;
  if s.approval <> 'pending' then raise exception 'This service is not waiting for review.'; end if;
  r := private.need_reason(p_note);
  update public.services set approval = 'needs_info', approval_note = r, reviewed_at = now(), reviewed_by = (select auth.uid()) where id = p_service_id;
  perform private.log_admin('service_info_requested', 'service', p_service_id, r, jsonb_build_object('name', s.name, 'provider_id', s.provider_id));
end $$;
revoke all on function public.admin_request_service_info(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_request_service_info(uuid, text) to authenticated;

-- the provider sends a rejected service, or one the admin asked about, back for review
create or replace function public.resubmit_service(p_service_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.services;
begin
  if not private.account_active() then raise exception 'You cannot do this right now. If your account was deactivated, please contact us.'; end if;
  select sv.* into s from public.services sv join public.provider_profiles p on p.id = sv.provider_id
  where sv.id = p_service_id and p.user_id = (select auth.uid()) for update of sv;
  if not found then raise exception 'Service not found'; end if;
  if s.approval not in ('rejected', 'needs_info') then raise exception 'Only a rejected service, or one the admin asked about, can be sent for review again.'; end if;
  update public.services set approval = 'pending', approval_note = null, reviewed_at = null, reviewed_by = null where id = p_service_id;
end $$;

-- ---------- 5) emails ----------
alter table public.email_outbox add column if not exists provider_id uuid references public.provider_profiles(id) on delete cascade;
alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('booking_new','booking_confirmed','booking_declined','booking_cancelled','refund_done',
                  'booking_completed','completion_confirmed','problem_reported','completion_reminder',
                  'service_pending','service_approved','service_rejected','service_needs_info','contact_new',
                  'provider_new','provider_approved','provider_rejected','provider_needs_info'));
alter table public.email_outbox drop constraint if exists email_outbox_subject_check;
alter table public.email_outbox add constraint email_outbox_subject_check
  check ((kind like 'service\_%' and service_id is not null)
         or (kind = 'contact_new' and contact_id is not null)
         or (kind like 'provider\_%' and provider_id is not null)
         or (kind not like 'service\_%' and kind <> 'contact_new' and kind not like 'provider\_%' and booking_id is not null));

-- services: also tell the provider when the admin asks for more
create or replace function public.email_on_service_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid; key text := new.id::text || ':' || extract(epoch from clock_timestamp())::text;
begin
  if new.approval = 'pending' and (tg_op = 'INSERT' or old.approval is distinct from 'pending') then
    insert into public.email_outbox(kind, service_id, to_user, dedupe)
    select 'service_pending', new.id, p.id, key from public.profiles p where p.role = 'admin' and p.is_active
    on conflict do nothing;
  elsif tg_op = 'UPDATE' and old.approval = 'pending' and new.approval in ('approved', 'rejected', 'needs_info') then
    select user_id into pu from public.provider_profiles where id = new.provider_id;
    if pu is not null then
      insert into public.email_outbox(kind, service_id, to_user, dedupe)
      values (case new.approval when 'approved' then 'service_approved' when 'rejected' then 'service_rejected' else 'service_needs_info' end, new.id, pu, key)
      on conflict do nothing;
    end if;
  end if;
  return new;
end $$;

-- provider applications: admins hear about a new / re-sent one, the provider hears about the decision
create or replace function public.email_on_application()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pu uuid; key text := new.provider_id::text || ':' || extract(epoch from clock_timestamp())::text;
begin
  if new.state = 'submitted' and (tg_op = 'INSERT' or old.state is distinct from 'submitted') then
    insert into public.email_outbox(kind, provider_id, to_user, dedupe)
    select 'provider_new', new.provider_id, p.id, key from public.profiles p where p.role = 'admin' and p.is_active
    on conflict do nothing;
  elsif tg_op = 'UPDATE' and old.state is distinct from new.state and new.state in ('approved', 'rejected', 'needs_info') then
    select user_id into pu from public.provider_profiles where id = new.provider_id;
    if pu is not null then
      insert into public.email_outbox(kind, provider_id, to_user, dedupe)
      values (case new.state when 'approved' then 'provider_approved' when 'rejected' then 'provider_rejected' else 'provider_needs_info' end, new.provider_id, pu, key)
      on conflict do nothing;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.email_on_application() from public, anon, authenticated;
drop trigger if exists applications_email on public.provider_applications;
create trigger applications_email after insert or update of state on public.provider_applications
for each row execute function public.email_on_application();

-- claim_emails: same as 019, also understands the new kinds (the note comes from the service or from the application)
drop function if exists public.claim_emails(int);
create function public.claim_emails(p_limit int default 20)
returns table (
  id uuid, kind text, attempts int, to_email text, to_name text, to_is_provider boolean,
  service_name text, business_name text, customer_name text, scheduled_at timestamptz,
  city text, price numeric, refund_amount numeric, completed_at timestamptz,
  to_is_admin boolean, approval_note text, contact_name text, contact_email text, contact_topic text, contact_message text,
  to_lang text
) language plpgsql security definer set search_path = '' as $$
begin
  perform public.queue_completion_reminders();

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.bookings b
  where o.booking_id = b.id and o.kind = 'completion_reminder' and o.status = 'pending'
    and (b.status <> 'completed' or b.confirmed_at is not null or b.problem_status <> 'none');

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.services s
  where o.service_id = s.id and o.status = 'pending'
    and ((o.kind = 'service_pending' and s.approval <> 'pending')
      or (o.kind = 'service_approved' and s.approval <> 'approved')
      or (o.kind = 'service_rejected' and s.approval <> 'rejected')
      or (o.kind = 'service_needs_info' and s.approval <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no longer needed'
  from public.provider_applications a
  where o.provider_id = a.provider_id and o.status = 'pending'
    and ((o.kind = 'provider_new' and a.state <> 'submitted')
      or (o.kind = 'provider_approved' and a.state <> 'approved')
      or (o.kind = 'provider_rejected' and a.state <> 'rejected')
      or (o.kind = 'provider_needs_info' and a.state <> 'needs_info'));

  update public.email_outbox o set status = 'skipped', last_error = 'no deliverable address'
  where o.status = 'pending' and o.next_attempt_at <= now()
    and not exists (select 1 from auth.users u join public.profiles p on p.id = u.id
                    where u.id = o.to_user and coalesce(u.email,'') <> '' and p.is_active);

  return query
  with picked as (
    select o.id from public.email_outbox o
    where (o.status = 'pending' and o.next_attempt_at <= now())
       or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
    order by o.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id
    returning o.*
  )
  select upd.id, upd.kind, upd.attempts, u.email::text, coalesce(tp.full_name, ''),
         coalesce(pp.user_id = upd.to_user, false), sv.name, pp.business_name, coalesce(cp.full_name, ''),
         b.scheduled_at, b.customer_city, coalesce(b.service_price, sv.price), pay.amount, b.completed_at,
         (tp.role = 'admin'), coalesce(sv.approval_note, app.note), cm.name, cm.email, cm.topic, cm.message, tp.lang
  from upd
  join auth.users u on u.id = upd.to_user
  join public.profiles tp on tp.id = upd.to_user
  left join public.bookings b on b.id = upd.booking_id
  left join public.services sv on sv.id = coalesce(b.service_id, upd.service_id)
  left join public.provider_profiles pp on pp.id = coalesce(b.provider_id, sv.provider_id, upd.provider_id)
  left join public.provider_applications app on app.provider_id = upd.provider_id
  left join public.profiles cp on cp.id = b.customer_id
  left join public.payments pay on pay.booking_id = b.id
  left join public.contact_messages cm on cm.id = upd.contact_id;
end $$;
revoke all on function public.claim_emails(int) from public, anon, authenticated;
grant execute on function public.claim_emails(int) to service_role;

-- admins can also see the application state and documents count in one call
create or replace function public.admin_provider_extras()
returns table (provider_id uuid, state text, note text, submitted_at timestamptz, id_docs bigint, license_docs bigint, insurance_docs bigint, other_docs bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select a.provider_id, a.state, a.note, a.submitted_at,
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'id'),
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'license'),
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'insurance'),
      (select count(*) from public.provider_documents d where d.provider_id = a.provider_id and d.kind = 'other')
    from public.provider_applications a;
end $$;
revoke all on function public.admin_provider_extras() from public, anon, authenticated;
grant execute on function public.admin_provider_extras() to authenticated;
