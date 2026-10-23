-- 024: the admin owns the list of services; providers only choose from it
--   * public.service_catalog: the services Wasel offers (name, description, category, suggested price, default duration).
--     Only admins add / change / hide them (every change is written to the audit log).
--   * public.services stays the "offering" row: one provider + one catalog item + the provider's own price, duration and visibility.
--     A provider can no longer type a service name, description or category: they are copied from the catalog.
--   * Because the admin already vetted the list, choosing a catalog item needs no separate approval or supporting document.
--   * Hiding a catalog item hides every provider offering of it (and blocks new bookings); existing bookings are untouched.
--   * Services that exist today become catalog items (hidden ones stay hidden until an admin shows them).

-- ---------- 1) the catalog ----------
create table if not exists public.service_catalog (
  id                       uuid primary key default gen_random_uuid(),
  name                     text not null check (char_length(btrim(name)) between 2 and 80),
  description              text check (description is null or char_length(description) <= 500),
  category                 text not null check (category in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair')),
  suggested_price          numeric(10,2) check (suggested_price is null or (suggested_price >= 1 and suggested_price <= 100000)),
  default_duration_minutes integer not null default 60 check (default_duration_minutes between 15 and 1440),
  is_active                boolean not null default true,
  created_by               uuid references auth.users(id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create unique index if not exists service_catalog_name_idx on public.service_catalog (lower(btrim(name)), category);
create index if not exists service_catalog_active_idx on public.service_catalog (category) where is_active;
drop trigger if exists service_catalog_updated_at on public.service_catalog;
create trigger service_catalog_updated_at before update on public.service_catalog for each row execute function public.set_updated_at();

alter table public.service_catalog enable row level security;
revoke all on public.service_catalog from public, anon, authenticated;
grant select on public.service_catalog to anon, authenticated;          -- no insert / update / delete: only the admin functions below write
create policy "Active catalog is public" on public.service_catalog for select to anon, authenticated using (is_active);
create policy "Admins read the whole catalog" on public.service_catalog for select to authenticated using ((select private.is_admin()));

-- ---------- 2) link offerings to the catalog, and move the services that exist today ----------
alter table public.services add column if not exists catalog_id uuid references public.service_catalog(id) on delete restrict;

do $$
declare r record; cid uuid; nm text;
begin
  -- one catalog item per distinct (name, category); the oldest service supplies the description.
  -- items that only come from services that were never approved stay hidden until an admin looks at them.
  insert into public.service_catalog (name, description, category, suggested_price, default_duration_minutes, is_active)
  select distinct on (lower(btrim(s.name)), s.category)
         btrim(s.name), nullif(btrim(coalesce(s.description, '')), ''), s.category, null, least(1440, greatest(15, s.duration_minutes)),
         exists (select 1 from public.services x where lower(btrim(x.name)) = lower(btrim(s.name)) and x.category = s.category and x.approval = 'approved')
  from public.services s
  where s.catalog_id is null and s.category in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair')
  order by lower(btrim(s.name)), s.category, s.created_at
  on conflict do nothing;

  -- the first offering of each provider for an item links to it; a provider's duplicates get their own numbered item (so nothing is lost)
  for r in
    select s.id, s.name, s.description, s.category, s.duration_minutes, s.approval,
           row_number() over (partition by s.provider_id, lower(btrim(s.name)), s.category order by s.created_at, s.id) as rn
    from public.services s where s.catalog_id is null
  loop
    nm := btrim(r.name);
    if r.rn > 1 then nm := left(nm, 70) || ' (' || r.rn || ')'; end if;
    select id into cid from public.service_catalog where lower(btrim(name)) = lower(nm) and category = r.category;
    if cid is null then
      insert into public.service_catalog (name, description, category, default_duration_minutes, is_active)
      values (nm, nullif(btrim(coalesce(r.description, '')), ''), r.category, least(1440, greatest(15, r.duration_minutes)), r.approval = 'approved')
      returning id into cid;
    end if;
    update public.services set catalog_id = cid where id = r.id;
  end loop;
end $$;

-- the approval workflow is retired: every remaining offering counts as approved (unvetted ones are hidden through their catalog item)
update public.services set approval = 'approved', approval_note = null, reviewed_at = null, reviewed_by = null where approval <> 'approved';
alter table public.services alter column catalog_id set not null;
create unique index if not exists services_provider_catalog_idx on public.services (provider_id, catalog_id);
create index if not exists services_catalog_idx on public.services (catalog_id);

-- ---------- 3) a provider can only pick a catalog item and set price / duration / visibility ----------
revoke insert (name, description, category) on public.services from authenticated;
revoke update (name, description, category) on public.services from authenticated;
grant insert (catalog_id) on public.services to authenticated;

create or replace function private.services_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare c public.service_catalog;
begin
  -- our own SECURITY DEFINER functions and the service role are not restricted; a signed-in user changing the table directly is
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    select * into c from public.service_catalog where id = new.catalog_id and is_active;
    if not found then raise exception 'Please choose a service from the Wasel list.'; end if;
    if exists (select 1 from public.services where provider_id = new.provider_id and catalog_id = new.catalog_id) then
      raise exception 'You already offer this service.';
    end if;
    new.name := c.name; new.description := c.description; new.category := c.category;
    new.approval := 'approved'; new.approval_note := null; new.reviewed_at := null; new.reviewed_by := null;
    if new.price < 1 or new.price > 100000 then raise exception 'The price must be between $1 and $100,000.'; end if;
    return new;
  end if;
  -- update by the provider: what the service IS comes from the catalog and cannot change
  new.catalog_id := old.catalog_id; new.name := old.name; new.description := old.description; new.category := old.category;
  new.approval := old.approval; new.approval_note := old.approval_note; new.reviewed_at := old.reviewed_at; new.reviewed_by := old.reviewed_by;
  if new.price is distinct from old.price and (new.price < 1 or new.price > 100000) then
    raise exception 'The price must be between $1 and $100,000.';
  end if;
  return new;
end $$;
revoke all on function private.services_guard() from public, anon, authenticated;

-- ---------- 4) customers only see / book offerings whose catalog item is shown ----------
drop policy if exists "Active services are publicly visible" on public.services;
create policy "Active services are publicly visible"
on public.services for select to anon, authenticated
using (
  status = 'active' and approval = 'approved'
  and exists (select 1 from public.provider_profiles p where p.id = services.provider_id and p.status = 'approved')
  and exists (select 1 from public.service_catalog c where c.id = services.catalog_id and c.is_active)
);

drop policy if exists "Photos of active services are publicly visible" on public.service_photos;
create policy "Photos of active services are publicly visible"
on public.service_photos for select to anon, authenticated
using (
  exists (
    select 1 from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    join public.service_catalog c on c.id = s.catalog_id
    where s.id = service_photos.service_id and s.status = 'active' and s.approval = 'approved' and p.status = 'approved' and c.is_active
  )
);

create or replace function public.prepare_booking()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  select sv.price, sv.provider_id, p.commission_rate, p.user_id as provider_user_id
    into s
  from public.services sv
  join public.provider_profiles p on p.id = sv.provider_id
  join public.service_catalog c on c.id = sv.catalog_id
  where sv.id = new.service_id
    and sv.status = 'active'
    and sv.approval = 'approved'
    and p.status  = 'approved'
    and c.is_active;

  if not found then raise exception 'Service is not available for booking'; end if;
  if s.provider_user_id = new.customer_id then raise exception 'You cannot book your own service'; end if;
  if new.scheduled_at <= now() then raise exception 'Booking time must be in the future'; end if;
  if new.quoted_price is not null and new.quoted_price <> s.price then
    raise exception 'The price changed to $%. Please check it and try again.', to_char(s.price, 'FM999999990.00');
  end if;

  new.provider_id         := s.provider_id;
  new.service_price       := s.price;
  new.platform_commission := round(s.price * s.commission_rate / 100, 2);
  new.provider_payout     := s.price - new.platform_commission;
  new.status              := 'pending';
  return new;
end $$;
revoke all on function public.prepare_booking() from public, anon, authenticated;

-- ---------- 5) retire the per-service approval workflow ----------
drop trigger if exists services_email_review on public.services;
drop function if exists public.email_on_service_review();
drop function if exists public.admin_service_queue();
drop function if exists public.admin_review_service(uuid, boolean, text);
drop function if exists public.admin_request_service_info(uuid, text);
drop function if exists public.resubmit_service(uuid);

-- ---------- 6) admin: manage the catalog ----------
create or replace function private.check_catalog_fields(p_name text, p_description text, p_category text, p_price numeric, p_duration integer)
returns void language plpgsql immutable as $$
begin
  if char_length(btrim(coalesce(p_name, ''))) < 2 or char_length(btrim(p_name)) > 80 then raise exception 'The service name must be 2 to 80 characters.'; end if;
  if char_length(coalesce(p_description, '')) > 500 then raise exception 'Please keep the description under 500 characters.'; end if;
  if p_category is null or p_category not in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair') then raise exception 'Choose a category.'; end if;
  if p_price is not null and (p_price < 1 or p_price > 100000) then raise exception 'The suggested price must be between $1 and $100,000.'; end if;
  if p_duration is null or p_duration < 15 or p_duration > 1440 then raise exception 'The default duration must be between 15 and 1440 minutes.'; end if;
end $$;
revoke all on function private.check_catalog_fields(text, text, text, numeric, integer) from public, anon, authenticated;

create or replace function public.admin_catalog_list()
returns table (id uuid, name text, description text, category text, suggested_price numeric, default_duration_minutes integer,
               is_active boolean, offered_by bigint, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select c.id, c.name, c.description, c.category, c.suggested_price, c.default_duration_minutes, c.is_active,
           (select count(*) from public.services s where s.catalog_id = c.id), c.created_at, c.updated_at
    from public.service_catalog c
    order by c.category, lower(c.name);
end $$;

create or replace function public.admin_create_catalog_item(p_name text, p_description text, p_category text, p_suggested_price numeric, p_duration integer)
returns uuid language plpgsql security definer set search_path = '' as $$
declare cid uuid; nm text := btrim(coalesce(p_name, ''));
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  perform private.check_catalog_fields(nm, p_description, p_category, p_suggested_price, p_duration);
  if exists (select 1 from public.service_catalog c where lower(btrim(c.name)) = lower(nm) and c.category = p_category) then
    raise exception 'This service is already in the list.';
  end if;
  insert into public.service_catalog (name, description, category, suggested_price, default_duration_minutes, created_by)
  values (nm, nullif(btrim(coalesce(p_description, '')), ''), p_category, p_suggested_price, p_duration, (select auth.uid()))
  returning id into cid;
  perform private.log_admin('catalog_added', 'catalog', cid, null, jsonb_build_object('name', nm, 'category', p_category));
  return cid;
end $$;

-- change a catalog item (a reason is required). The name / description / category are copied to every provider offering of it.
create or replace function public.admin_update_catalog_item(p_id uuid, p_name text, p_description text, p_category text,
                                                            p_suggested_price numeric, p_duration integer, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; nm text := btrim(coalesce(p_name, '')); old public.service_catalog; act text;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into old from public.service_catalog where id = p_id for update;
  if not found then raise exception 'Service not found in the list.'; end if;
  perform private.check_catalog_fields(nm, p_description, p_category, p_suggested_price, p_duration);
  if exists (select 1 from public.service_catalog c where c.id <> p_id and lower(btrim(c.name)) = lower(nm) and c.category = p_category) then
    raise exception 'This service is already in the list.';
  end if;
  update public.service_catalog
  set name = nm, description = nullif(btrim(coalesce(p_description, '')), ''), category = p_category,
      suggested_price = p_suggested_price, default_duration_minutes = p_duration, is_active = coalesce(p_active, old.is_active)
  where id = p_id;
  update public.services
  set name = nm, description = nullif(btrim(coalesce(p_description, '')), ''), category = p_category
  where catalog_id = p_id and (name, description, category) is distinct from (nm, nullif(btrim(coalesce(p_description, '')), ''), p_category);
  act := case when old.is_active and not coalesce(p_active, old.is_active) then 'catalog_hidden'
              when not old.is_active and coalesce(p_active, old.is_active) then 'catalog_shown'
              else 'catalog_updated' end;
  perform private.log_admin(act, 'catalog', p_id, r, jsonb_build_object('name', nm, 'was', old.name, 'category', p_category, 'active', coalesce(p_active, old.is_active)));
end $$;

-- delete is only possible while no provider offers the item (otherwise hide it)
create or replace function public.admin_delete_catalog_item(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text; old public.service_catalog;
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  r := private.need_reason(p_reason);
  select * into old from public.service_catalog where id = p_id for update;
  if not found then raise exception 'Service not found in the list.'; end if;
  if exists (select 1 from public.services where catalog_id = p_id) then
    raise exception 'Providers already offer this service, so it cannot be deleted. Hide it instead.';
  end if;
  delete from public.service_catalog where id = p_id;
  perform private.log_admin('catalog_deleted', 'catalog', p_id, r, jsonb_build_object('name', old.name, 'category', old.category));
end $$;

-- ---------- grants ----------
revoke all on function public.admin_catalog_list()                                                         from public, anon, authenticated;
revoke all on function public.admin_create_catalog_item(text, text, text, numeric, integer)                from public, anon, authenticated;
revoke all on function public.admin_update_catalog_item(uuid, text, text, text, numeric, integer, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_delete_catalog_item(uuid, text)                                        from public, anon, authenticated;
grant execute on function public.admin_catalog_list()                                                      to authenticated;
grant execute on function public.admin_create_catalog_item(text, text, text, numeric, integer)             to authenticated;
grant execute on function public.admin_update_catalog_item(uuid, text, text, text, numeric, integer, boolean, text) to authenticated;
grant execute on function public.admin_delete_catalog_item(uuid, text)                                     to authenticated;
