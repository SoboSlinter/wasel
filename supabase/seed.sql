-- =========================================================
-- LOCAL TEST DATA — runs automatically on `npm run db:reset`.
-- Never run this on a real/production project.
--
-- All test accounts use the password:  Test1234!
--   admin@wasel.test             admin
--   customer@wasel.test          customer (has bookings)
--   customer2@wasel.test         customer (no bookings)
--   provider@wasel.test          provider, approved, 5 services
--   pending-provider@wasel.test  provider waiting for approval
-- =========================================================

-- 1) Auth users (the on_auth_user_created trigger creates their profiles)
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
select
  '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  u.email, crypt('Test1234!', gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', u.full_name),
  now(), now(), '', '', '', ''
from (values
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'admin@wasel.test',            'Test Admin'),
  ('b0000000-0000-0000-0000-000000000002'::uuid, 'customer@wasel.test',         'Test Customer'),
  ('b0000000-0000-0000-0000-000000000003'::uuid, 'customer2@wasel.test',        'Second Customer'),
  ('c0000000-0000-0000-0000-000000000004'::uuid, 'provider@wasel.test',         'Test Provider'),
  ('c0000000-0000-0000-0000-000000000005'::uuid, 'pending-provider@wasel.test', 'Pending Provider')
) as u(id, email, full_name);

-- email/password login also needs an identity row
insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id::text, u.id,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
from auth.users u
where u.email like '%@wasel.test';

-- 2) Roles (seed runs as the database owner, so the column lock does not apply)
update public.profiles set role = 'admin'    where id = 'a0000000-0000-0000-0000-000000000001';
update public.profiles set role = 'provider' where id in ('c0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000005');

-- 3) Providers
insert into public.provider_profiles
  (id, user_id, business_name, description, phone, email, city, state, zip_code, status)
values
  ('d0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000004',
   'Sparkle Auto & Home', 'Detailing, cleaning and small repairs across Irving and Dallas.',
   '555-0100', 'provider@wasel.test', 'Irving', 'TX', '75038', 'approved'),
  ('d0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000005',
   'Newcomer Cleaning', 'Waiting for admin approval.',
   '555-0101', 'pending-provider@wasel.test', 'Dallas', 'TX', '75201', 'pending');

-- 3b) Service areas (who works where)
insert into public.provider_service_areas (provider_id, kind, label) values
  ('d0000000-0000-0000-0000-000000000001', 'city', 'Irving'),
  ('d0000000-0000-0000-0000-000000000001', 'city', 'Dallas'),
  ('d0000000-0000-0000-0000-000000000001', 'zip',  '75038'),
  ('d0000000-0000-0000-0000-000000000001', 'zip',  '75039'),
  ('d0000000-0000-0000-0000-000000000001', 'zip',  '75201'),
  ('d0000000-0000-0000-0000-000000000002', 'city', 'Plano'),
  ('d0000000-0000-0000-0000-000000000002', 'zip',  '75024');

-- 4) The services list (owned by the admin) and what each provider chooses from it
insert into public.service_catalog (id, name, description, category, suggested_price, default_duration_minutes) values
  ('90000000-0000-0000-0000-000000000001', 'Full Interior & Exterior Detail', 'Hand wash, wax, vacuum and interior wipe-down.', 'car_detailing', 149.00, 180),
  ('90000000-0000-0000-0000-000000000002', 'Express Car Wash', 'Quick exterior wash and tire shine.', 'car_detailing', 35.00, 30),
  ('90000000-0000-0000-0000-000000000003', 'Standard Home Cleaning', 'Kitchen, bathrooms, floors and dusting for up to 3 bedrooms.', 'home_cleaning', 120.00, 150),
  ('90000000-0000-0000-0000-000000000004', 'Handyman Hourly', 'Small repairs, mounting, assembly and fixes.', 'handyman', 65.00, 60),
  ('90000000-0000-0000-0000-000000000005', 'Laptop Tune-up', 'Virus scan, cleanup and speed-up for Windows or Mac.', 'computer_repair', 80.00, 90),
  ('90000000-0000-0000-0000-000000000006', 'Ceramic Coating (draft)', 'Not published yet — only the provider sees this.', 'car_detailing', 450.00, 360),
  ('90000000-0000-0000-0000-000000000007', 'Deep Clean (pending provider)', 'Hidden from the public until the provider is approved.', 'home_cleaning', 200.00, 240);

insert into public.services (id, provider_id, catalog_id, name, description, category, price, duration_minutes, status) values
  ('e0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', 'Full Interior & Exterior Detail', 'Hand wash, wax, vacuum and interior wipe-down.', 'car_detailing', 149.00, 180, 'active'),
  ('e0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002', 'Express Car Wash', 'Quick exterior wash and tire shine.', 'car_detailing', 35.00, 30, 'active'),
  ('e0000000-0000-0000-0000-000000000003', 'd0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000003', 'Standard Home Cleaning', 'Kitchen, bathrooms, floors and dusting for up to 3 bedrooms.', 'home_cleaning', 120.00, 150, 'active'),
  ('e0000000-0000-0000-0000-000000000004', 'd0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000004', 'Handyman Hourly', 'Small repairs, mounting, assembly and fixes.', 'handyman', 65.00, 60, 'active'),
  ('e0000000-0000-0000-0000-000000000005', 'd0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000005', 'Laptop Tune-up', 'Virus scan, cleanup and speed-up for Windows or Mac.', 'computer_repair', 80.00, 90, 'active'),
  ('e0000000-0000-0000-0000-000000000006', 'd0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000006', 'Ceramic Coating (draft)', 'Not published yet — only the provider sees this.', 'car_detailing', 450.00, 360, 'draft'),
  ('e0000000-0000-0000-0000-000000000007', 'd0000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000007', 'Deep Clean (pending provider)', 'Hidden from the public until the provider is approved.', 'home_cleaning', 200.00, 240, 'active');

-- 5) Bookings (the trigger computes price/commission/payout; then we move them along)
insert into public.bookings (id, customer_id, service_id, scheduled_at, customer_address, customer_city, customer_zip_code, customer_notes)
values
  ('f0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', now() + interval '1 hour', '100 Main St', 'Irving', '75038', 'Gate code 1234'),
  ('f0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000003', now() + interval '3 days', '100 Main St', 'Irving', '75038', null),
  ('f0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000004', now() + interval '5 days', '100 Main St', 'Irving', '75038', null);

update public.bookings set status = 'completed' where id = 'f0000000-0000-0000-0000-000000000001';
update public.bookings set status = 'confirmed' where id = 'f0000000-0000-0000-0000-000000000002';
-- f...0003 stays 'pending'

-- 6) One review on the completed booking (trigger updates the provider rating)
insert into public.reviews (booking_id, customer_id, provider_id, rating, comment)
values ('f0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002',
        'd0000000-0000-0000-0000-000000000001', 5, 'Great job, car looks new!');
