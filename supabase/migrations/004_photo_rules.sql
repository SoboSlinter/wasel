-- =========================================================
-- WASEL MVP — Rules for service photos
-- Run AFTER 001, 002 and 003.
--
-- 1) A photo row must point at a file inside the provider's OWN storage folder
--    (<their user id>/...). Otherwise a provider could point a row at someone
--    else's file.
-- 2) At most 5 photos per service.
-- =========================================================

alter policy "Provider can add own service photos"
on public.service_photos
with check (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
  and split_part(storage_path, '/', 1) = (select auth.uid())::text
);

alter policy "Provider can update own service photos"
on public.service_photos
with check (
  exists (
    select 1
    from public.services s
    join public.provider_profiles p on p.id = s.provider_id
    where s.id = service_photos.service_id and p.user_id = (select auth.uid())
  )
  and split_part(storage_path, '/', 1) = (select auth.uid())::text
);

create or replace function public.limit_service_photos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.service_photos where service_id = new.service_id) >= 5 then
    raise exception 'A service can have at most 5 photos';
  end if;
  return new;
end;
$$;

create trigger service_photos_limit
before insert on public.service_photos
for each row execute function public.limit_service_photos();
