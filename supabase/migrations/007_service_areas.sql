-- =========================================================
-- WASEL MVP — Service areas
-- Providers choose where they work (cities and/or ZIP codes).
-- Customers search by city or ZIP and only see providers who serve that place.
-- Run AFTER 006.
-- =========================================================

create table public.provider_service_areas (
  id           uuid primary key default gen_random_uuid(),
  provider_id  uuid not null references public.provider_profiles(id) on delete cascade,
  kind         text not null check (kind in ('zip', 'city')),
  label        text not null check (char_length(label) between 2 and 60),   -- "75038" or "Irving"
  created_at   timestamptz not null default now(),
  check ((kind = 'zip'  and label ~ '^[0-9]{5}$')
      or (kind = 'city' and label ~ '^[A-Za-z][A-Za-z .''-]{1,59}$'))
);
create unique index uq_service_area on public.provider_service_areas (provider_id, lower(label));
create index idx_service_area_label on public.provider_service_areas (lower(label));

alter table public.provider_service_areas enable row level security;
revoke all on public.provider_service_areas from public, anon, authenticated;
grant select on public.provider_service_areas to anon, authenticated;     -- writes only through set_service_areas()

-- Whoever can see a provider can see where that provider works.
create policy "Areas follow provider visibility"
on public.provider_service_areas for select to anon, authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id));

-- Replace my service areas with this list. Each entry is a 5-digit ZIP or a city name.
create or replace function public.set_service_areas(p_areas text[])
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  pid uuid;
  item text;
  clean text;
  kind text;
  seen text[] := '{}';
  n integer := 0;
begin
  select id into pid from public.provider_profiles where user_id = (select auth.uid());
  if pid is null then raise exception 'Only providers can set service areas'; end if;

  delete from public.provider_service_areas where provider_id = pid;

  foreach item in array coalesce(p_areas, '{}') loop
    clean := regexp_replace(btrim(coalesce(item, '')), '\s+', ' ', 'g');
    clean := regexp_replace(clean, ',\s*(tx|texas)$', '', 'i');           -- "Irving, TX" -> "Irving"
    if clean = '' then continue; end if;
    if clean ~ '^[0-9]{5}$' then kind := 'zip';
    elsif clean ~ '^[A-Za-z][A-Za-z .''-]{1,59}$' then
      kind := 'city';
      -- all-lower or ALL-CAPS typing is tidied ("irving" -> "Irving"); mixed case like "McKinney" is kept as typed
      if clean = lower(clean) or clean = upper(clean) then clean := initcap(lower(clean)); end if;
    else raise exception 'Not a valid city or ZIP code: %', left(clean, 40);
    end if;
    if lower(clean) = any (seen) then continue; end if;
    seen := seen || lower(clean);
    n := n + 1;
    if n > 30 then raise exception 'You can list at most 30 areas'; end if;
    insert into public.provider_service_areas (provider_id, kind, label) values (pid, kind, clean);
  end loop;
  return n;
end $$;

-- Which services work in this place? Uses the caller's own visibility (RLS), so
-- customers only ever get active services of approved providers.
create or replace function public.services_in_area(p_place text)
returns setof uuid
language sql stable security invoker set search_path = '' as $$
  with q as (
    select case
      when btrim(p_place) ~ '^[0-9]{5}(-[0-9]{4})?$' then left(btrim(p_place), 5)
      else lower(regexp_replace(regexp_replace(btrim(p_place), '\s+', ' ', 'g'), ',\s*(tx|texas)$', '', 'i'))
    end as place
  )
  select s.id
  from public.services s
  join public.provider_service_areas a on a.provider_id = s.provider_id, q
  where lower(a.label) = q.place
  limit 500;
$$;

revoke all on function public.set_service_areas(text[]) from public, anon, authenticated;
grant execute on function public.set_service_areas(text[]) to authenticated;
revoke all on function public.services_in_area(text) from public, anon, authenticated;
grant execute on function public.services_in_area(text) to anon, authenticated;
