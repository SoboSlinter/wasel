-- =========================================================
-- WASEL MVP — Storage for service photos
-- Run AFTER 001_initial_schema.sql.
--
-- Upload path convention (the first folder MUST be the provider's user id):
--   <auth user id>/<service id>/<filename>
-- e.g.  3f2a.../9c1b.../before-after.jpg
-- =========================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'service-photos',
  'service-photos',
  true,                                   -- photos are shown publicly
  5242880,                                -- 5 MB
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

create policy "Service photos are publicly readable"
on storage.objects for select
using (bucket_id = 'service-photos');

create policy "Providers can upload to their own folder"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Providers can update files in their own folder"
on storage.objects for update to authenticated
using (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Providers can delete files in their own folder"
on storage.objects for delete to authenticated
using (
  bucket_id = 'service-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
