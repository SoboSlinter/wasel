-- Removes everything demo.sql added. Deleting the demo accounts removes their profiles, provider profiles,
-- services and service areas (ON DELETE CASCADE). Bookings made on demo services are removed with them.
-- If a demo booking was paid, delete its payment rows first (the script stops with an error instead of guessing).
begin;
delete from public.reviews where provider_id::text like 'd1000000-%';
delete from public.bookings where service_id in (select id from public.services where provider_id::text like 'd1000000-%');
delete from auth.users where id::text like 'd0000000-0000-4000-8000-%' and email like 'demo-provider-%@example.com';
delete from public.service_catalog c
where c.id::text like 'd2000000-%' and not exists (select 1 from public.services s where s.catalog_id = c.id);
commit;
