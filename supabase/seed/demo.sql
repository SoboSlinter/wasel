-- Demo data for trying Wasel on a test project: 3 approved providers in Austin, Houston and Dallas,
-- a small service catalog and 8 active services. Safe to run more than once.
-- Run it in the Supabase SQL editor. NEVER run it on the live project.
-- The demo providers have no password, so nobody can log in as them. Remove everything with demo-remove.sql.

begin;

-- 1) demo accounts (the on_auth_user_created trigger makes their profiles)
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'demo-provider-1@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"full_name":"Sparkle Auto Spa (demo)","demo":true}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'demo-provider-2@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"full_name":"Fresh Home Cleaning (demo)","demo":true}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'demo-provider-3@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"full_name":"FixIt Pros (demo)","demo":true}', now(), now())
on conflict (id) do nothing;

update public.profiles set role = 'provider'
where id in ('d0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000003');

-- 2) provider profiles, already approved
insert into public.provider_profiles (id, user_id, business_name, description, email, city, state, zip_code, status, business_type, categories, years_experience, languages, rating, review_count, is_pro)
values
  ('d1000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001', 'Sparkle Auto Spa (demo)', 'Mobile car detailing: we come to your home or office.', 'demo-provider-1@example.com', 'Austin', 'TX', '78701', 'approved', 'company', array['car_detailing'], 6, array['English', 'Spanish'], 4.8, 0, true),
  ('d1000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000002', 'Fresh Home Cleaning (demo)', 'Regular and deep cleaning for houses and apartments.', 'demo-provider-2@example.com', 'Houston', 'TX', '77002', 'approved', 'company', array['home_cleaning'], 4, array['English'], 4.6, 0, false),
  ('d1000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000003', 'FixIt Pros (demo)', 'Handyman jobs and computer repair, same-week visits.', 'demo-provider-3@example.com', 'Dallas', 'TX', '75201', 'approved', 'individual', array['handyman', 'computer_repair'], 10, array['English', 'Arabic'], 4.9, 0, false)
on conflict (id) do nothing;

insert into public.provider_service_areas (provider_id, kind, label) values
  ('d1000000-0000-4000-8000-000000000001', 'city', 'Austin'),
  ('d1000000-0000-4000-8000-000000000001', 'zip', '78701'),
  ('d1000000-0000-4000-8000-000000000002', 'city', 'Houston'),
  ('d1000000-0000-4000-8000-000000000002', 'zip', '77002'),
  ('d1000000-0000-4000-8000-000000000003', 'city', 'Dallas'),
  ('d1000000-0000-4000-8000-000000000003', 'zip', '75201')
on conflict do nothing;

-- 3) the service list providers choose from
insert into public.service_catalog (id, name, description, category, suggested_price, default_duration_minutes) values
  ('d2000000-0000-4000-8000-000000000001', 'Full car detailing', 'Inside and outside cleaning, wax and tire shine.', 'car_detailing', 149, 180),
  ('d2000000-0000-4000-8000-000000000002', 'Express car wash', 'Hand wash and interior vacuum.', 'car_detailing', 49, 60),
  ('d2000000-0000-4000-8000-000000000003', 'Standard home cleaning', 'Kitchen, bathrooms, dusting and floors.', 'home_cleaning', 120, 180),
  ('d2000000-0000-4000-8000-000000000004', 'Deep cleaning', 'Top-to-bottom cleaning, inside appliances and cabinets.', 'home_cleaning', 240, 300),
  ('d2000000-0000-4000-8000-000000000005', 'TV wall mounting', 'Mount a TV up to 75 inches and hide the cables.', 'handyman', 99, 90),
  ('d2000000-0000-4000-8000-000000000006', 'Furniture assembly', 'Assembly of beds, desks, shelves and more.', 'handyman', 79, 120),
  ('d2000000-0000-4000-8000-000000000007', 'Computer tune-up', 'Virus removal, updates and speed-up.', 'computer_repair', 89, 90),
  ('d2000000-0000-4000-8000-000000000008', 'Laptop screen replacement', 'Replace a cracked laptop screen (part priced separately).', 'computer_repair', 129, 120)
on conflict (id) do nothing;

-- 4) active services
insert into public.services (id, provider_id, catalog_id, name, description, category, price, duration_minutes, status, approval)
select s.id, s.provider_id, c.id, c.name, c.description, c.category, s.price, c.default_duration_minutes, 'active', 'approved'
from (values
  ('d3000000-0000-4000-8000-000000000001'::uuid, 'd1000000-0000-4000-8000-000000000001'::uuid, 'd2000000-0000-4000-8000-000000000001'::uuid, 139::numeric),
  ('d3000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000002', 45),
  ('d3000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000002', 'd2000000-0000-4000-8000-000000000003', 110),
  ('d3000000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000002', 'd2000000-0000-4000-8000-000000000004', 220),
  ('d3000000-0000-4000-8000-000000000005', 'd1000000-0000-4000-8000-000000000003', 'd2000000-0000-4000-8000-000000000005', 95),
  ('d3000000-0000-4000-8000-000000000006', 'd1000000-0000-4000-8000-000000000003', 'd2000000-0000-4000-8000-000000000006', 75),
  ('d3000000-0000-4000-8000-000000000007', 'd1000000-0000-4000-8000-000000000003', 'd2000000-0000-4000-8000-000000000007', 85),
  ('d3000000-0000-4000-8000-000000000008', 'd1000000-0000-4000-8000-000000000003', 'd2000000-0000-4000-8000-000000000008', 125)
) as s(id, provider_id, catalog_id, price)
join public.service_catalog c on c.id = s.catalog_id
on conflict (id) do nothing;

commit;
