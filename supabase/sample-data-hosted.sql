-- =========================================================
-- Sample data for testing the Services page.
-- Run in the SQL Editor AFTER you have signed up at least once.
-- The first user in your project becomes the owner of a demo provider.
-- (That user cannot book their own services — test booking with a 2nd account.)
-- Run it once; delete the demo provider to remove everything.
-- =========================================================

do $$
declare
  owner_id uuid := (select id from public.profiles order by created_at limit 1);
  pid uuid;
begin
  if owner_id is null then
    raise exception 'Sign up in the app first, then run this seed.';
  end if;

  insert into public.provider_profiles
    (user_id, business_name, description, phone, email, city, state, zip_code, status)
  values
    (owner_id, 'Demo Auto & Home Co.', 'Demo provider used for testing Wasel.',
     '555-0100', 'demo@example.com', 'Irving', 'TX', '75038', 'approved')
  returning id into pid;

  insert into public.provider_service_areas (provider_id, kind, label) values
    (pid, 'city', 'Irving'), (pid, 'city', 'Dallas'), (pid, 'zip', '75038'), (pid, 'zip', '75039');

  update public.profiles set role = 'provider' where id = owner_id and role = 'customer';

  -- the admin's services list, then what this provider chooses from it
  insert into public.service_catalog (name, description, category, suggested_price, default_duration_minutes) values
    ('Full Interior & Exterior Detail', 'Hand wash, wax, vacuum and interior wipe-down.', 'car_detailing', 149.00, 180),
    ('Express Car Wash', 'Quick exterior wash and tire shine.', 'car_detailing', 35.00, 30),
    ('Standard Home Cleaning', 'Kitchen, bathrooms, floors and dusting for up to 3 bedrooms.', 'home_cleaning', 120.00, 150),
    ('Handyman Hourly', 'Small repairs, mounting, assembly and fixes.', 'handyman', 65.00, 60),
    ('Laptop Tune-up', 'Virus scan, cleanup and speed-up for Windows or Mac.', 'computer_repair', 80.00, 90)
  on conflict do nothing;
  insert into public.services (provider_id, catalog_id, name, description, category, price, duration_minutes, status)
  select pid, c.id, c.name, c.description, c.category, c.suggested_price, c.default_duration_minutes, 'active'
  from public.service_catalog c
  where c.name in ('Full Interior & Exterior Detail', 'Express Car Wash', 'Standard Home Cleaning', 'Handyman Hourly', 'Laptop Tune-up')
  on conflict do nothing;
end $$;
