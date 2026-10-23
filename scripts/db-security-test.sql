-- =========================================================
-- Wasel database security tests.
-- Run with:  npm run db:test      (needs `npm run db:start` first)
-- Everything happens inside one transaction that is ROLLED BACK at the
-- end, so your local data is not changed.
-- =========================================================
begin;
create schema t;
create table t.results(n serial, label text, ok boolean, detail text);

-- run SQL as a role; expect: 'ok' | 'err' | integer row count
-- test helper: mark every in-progress job as "arrived" with one photo of the work (the rule a provider must meet before completing)
create or replace function t.prep_all() returns void language plpgsql as $$
begin
  update public.bookings set arrived_at = coalesce(arrived_at, now()) where status = 'in_progress';
  insert into public.booking_work_photos(booking_id, storage_path)
  select b.id, 'p/' || b.id || '/x.jpg' from public.bookings b
  where b.status = 'in_progress' and not exists (select 1 from public.booking_work_photos w where w.booking_id = b.id);
end $$;

create or replace function t.run(p_label text, p_uid uuid, p_role text, p_sql text, p_expect text) returns void language plpgsql as $$
declare n bigint; msg text := ''; got text; pass boolean;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  execute format('set local role %I', p_role);
  begin
    execute p_sql; get diagnostics n = row_count; got := 'ok:'||n;
  exception when others then got := 'err'; msg := sqlerrm; end;
  reset role;
  pass := case when p_expect='err' then got='err'
               when p_expect='ok'  then got like 'ok:%'
               else got = 'ok:'||p_expect end;
  insert into t.results(label, ok, detail) values (p_label, pass, got||' '||msg);
end $$;

create or replace function t.chk(p_label text, p_cond boolean) returns void language sql as
$$ insert into t.results(label, ok, detail) values (p_label, coalesce(p_cond,false), 'check') $$;

-- fixtures
delete from public.reviews; delete from public.payments; delete from public.subscriptions;
delete from public.bookings; delete from public.service_photos; delete from public.services;
delete from public.provider_profiles; delete from auth.users;
insert into auth.users(id,email,raw_user_meta_data) values
 ('a0000000-0000-0000-0000-000000000001','alice@x.com','{"full_name":"Alice","role":"admin"}'),
 ('b0000000-0000-0000-0000-000000000002','bob@x.com','{}'),
 ('c0000000-0000-0000-0000-000000000003','carol@x.com','{}'),
 ('d0000000-0000-0000-0000-000000000004','dave@x.com','{}'),
 ('e0000000-0000-0000-0000-000000000005','eve@x.com','{}');
update public.profiles set role='admin' where id='d0000000-0000-0000-0000-000000000004';
select t.chk('signup ignores role in metadata (alice stays customer)', (select role='customer' from public.profiles where id='a0000000-0000-0000-0000-000000000001'));

\set alice '''a0000000-0000-0000-0000-000000000001'''
\set bob   '''b0000000-0000-0000-0000-000000000002'''
\set carol '''c0000000-0000-0000-0000-000000000003'''
\set dave  '''d0000000-0000-0000-0000-000000000004'''
\set eve   '''e0000000-0000-0000-0000-000000000005'''

-- PROFILES / ESCALATION
select t.run('customer cannot set own role=admin', :alice, 'authenticated', $q$update public.profiles set role='admin' where id=auth.uid()$q$, 'err');
select t.run('customer cannot set own is_active', :alice, 'authenticated', $q$update public.profiles set is_active=true where id=auth.uid()$q$, 'err');
select t.run('customer can edit own name', :alice, 'authenticated', $q$update public.profiles set full_name='Alice A' where id=auth.uid()$q$, '1');
select t.run('customer cannot edit someone elses profile', :alice, 'authenticated', $q$update public.profiles set full_name='x' where id='e0000000-0000-0000-0000-000000000005'$q$, '0');
select t.run('customer sees only own profile', :alice, 'authenticated', $q$select * from public.profiles$q$, '1');
select t.run('customer cannot insert profile', :alice, 'authenticated', $q$insert into public.profiles(id,role) values (gen_random_uuid(),'admin')$q$, 'err');

-- PROVIDER ONBOARDING
select t.run('customer cannot insert provider_profiles directly', :alice, 'authenticated', $q$insert into public.provider_profiles(user_id,business_name,status) values (auth.uid(),'Hack','approved')$q$, 'err');
select t.run('bob registers as provider', :bob, 'authenticated', $q$select public.register_provider('Bob Wash','individual',array['car_detailing'],'(214) 555-0101',true)$q$, 'ok');
select t.run('carol registers as provider', :carol, 'authenticated', $q$select public.register_provider('Carol Detail','company',array['car_detailing','handyman','car_detailing'],'214-555-0102',true,'desc',null,null,null,'TX',null,7,'TX lic 123 + insurance',array['English','Arabic','english',' '],'https://carol.example.com','friend')$q$, 'ok');
select t.run('bob cannot register twice', :bob, 'authenticated', $q$select public.register_provider('Bob 2','individual',array['handyman'],'2145550103',true)$q$, 'err');
select t.chk('register_provider sets role=provider', (select role='provider' from public.profiles where id='b0000000-0000-0000-0000-000000000002'));
-- PROVIDER SIGN-UP DETAILS
select t.chk('register: categories de-duplicated and stored', (select categories = array['car_detailing','handyman'] from public.provider_profiles where business_name='Carol Detail'));
select t.chk('register: type, years, website stored', (select business_type='company' and years_experience=7 and website='https://carol.example.com' from public.provider_profiles where business_name='Carol Detail'));
select t.chk('register: languages trimmed, de-duplicated, blanks dropped', (select languages is not null and cardinality(languages)=3 from public.provider_profiles where business_name='Carol Detail'));
select t.chk('register: private details saved with terms time', (select license_info like 'TX lic%' and referral_source='friend' and terms_accepted_at is not null and terms_version is not null from public.provider_private pr join public.provider_profiles p on p.id=pr.provider_id where p.business_name='Carol Detail'));
select t.run('register: terms must be accepted', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'2145550111',false)$q$, 'err');
select t.run('register: terms null refused', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'2145550111',null)$q$, 'err');
select t.run('register: business type required', :eve, 'authenticated', $q$select public.register_provider('E1',null,array['handyman'],'2145550111',true)$q$, 'err');
select t.run('register: business type must be valid', :eve, 'authenticated', $q$select public.register_provider('E1','corp',array['handyman'],'2145550111',true)$q$, 'err');
select t.run('register: category required', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array[]::text[],'2145550111',true)$q$, 'err');
select t.run('register: unknown category refused', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['hacking'],'2145550111',true)$q$, 'err');
select t.run('register: phone required', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],null,true)$q$, 'err');
select t.run('register: short phone refused', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'555-1234',true)$q$, 'err');
select t.run('register: letters-only phone refused', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'call me maybe',true)$q$, 'err');
select t.run('register: 11-digit phone must start with 1', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'22145550111',true)$q$, 'err');
select t.run('register: years above 60 refused', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'2145550111',true,null,null,null,null,'TX',null,99)$q$, 'err');
select t.run('register: javascript: website refused', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'2145550111',true,null,null,null,null,'TX',null,1,null,null,'javascript:alert(1)')$q$, 'err');
select t.run('register: bad referral option refused', :eve, 'authenticated', $q$select public.register_provider('E1','individual',array['handyman'],'2145550111',true,null,null,null,null,'TX',null,1,null,null,null,'spam')$q$, 'err');
select t.run('register: overlong license info refused', :eve, 'authenticated', format($q$select public.register_provider('E1','individual',array['handyman'],'2145550111',true,null,null,null,null,'TX',null,1,%L)$q$, repeat('x',301)), 'err');
select t.chk('failed registrations created nothing for eve', (select count(*)=0 from public.provider_profiles where user_id='e0000000-0000-0000-0000-000000000005'));
select t.run('anon can read the public details columns', null, 'anon', $q$select business_type, categories, years_experience, languages, website from public.provider_profiles$q$, 'ok');
select t.run('anon cannot read private details', null, 'anon', $q$select * from public.provider_private$q$, 'err');
select t.run('customer cannot read private details', :alice, 'authenticated', $q$select * from public.provider_private$q$, '0');
select t.run('other provider cannot read carols private details', :bob, 'authenticated', $q$select * from public.provider_private$q$, '1');
select t.run('carol reads own private details', :carol, 'authenticated', $q$select * from public.provider_private$q$, '1');
select t.run('admin reads all private details', :dave, 'authenticated', $q$select * from public.provider_private$q$, '2');
select t.run('provider edits own license info', :carol, 'authenticated', $q$update public.provider_private set license_info='Updated' $q$, '1');
select t.run('provider cannot edit terms date', :carol, 'authenticated', $q$update public.provider_private set terms_accepted_at=null$q$, 'err');
select t.run('provider cannot edit referral', :carol, 'authenticated', $q$update public.provider_private set referral_source='other'$q$, 'err');
select t.run('provider edits public details', :carol, 'authenticated', $q$update public.provider_profiles set years_experience=8, languages=array['English'], website='https://new.example.com'$q$, '1');
select t.run('DB rejects javascript: website on update', :carol, 'authenticated', $q$update public.provider_profiles set website='javascript:alert(1)'$q$, 'err');
select t.run('DB rejects 11 categories on update', :carol, 'authenticated', $q$update public.provider_profiles set categories=array['a','b','c','d','e','f','g','h','i','j','k']$q$, 'err');
select t.run('provider cannot insert private row for someone else', :carol, 'authenticated', $q$insert into public.provider_private(provider_id) select id from public.provider_profiles limit 1$q$, 'err');

select t.run('provider cannot self-approve', :bob, 'authenticated', $q$update public.provider_profiles set status='approved' where user_id=auth.uid()$q$, 'err');
select t.run('provider cannot change commission', :bob, 'authenticated', $q$update public.provider_profiles set commission_rate=0 where user_id=auth.uid()$q$, 'err');
select t.run('provider cannot change rating', :bob, 'authenticated', $q$update public.provider_profiles set rating=5 where user_id=auth.uid()$q$, 'err');
select t.run('provider can edit business_name', :bob, 'authenticated', $q$update public.provider_profiles set business_name='Bob Wash 2' where user_id=auth.uid()$q$, '1');
select t.run('pending provider sees own profile', :bob, 'authenticated', $q$select * from public.provider_profiles$q$, '1');
select t.run('anon sees no pending providers', null, 'anon', $q$select * from public.provider_profiles$q$, '0');
select t.run('non-admin cannot approve via RPC', :bob, 'authenticated', $q$select public.admin_set_provider_status((select id from public.provider_profiles where user_id=auth.uid()),'approved')$q$, 'err');
select t.run('admin cannot approve a pending provider through the old status function', :dave, 'authenticated', $q$select public.admin_set_provider_status((select id from public.provider_profiles where business_name='Carol Detail'),'approved')$q$, 'err');
select t.run('admin cannot approve an application without documents', :dave, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where business_name='Carol Detail'),'approve',null)$q$, 'err');
insert into public.provider_documents(provider_id,kind,storage_path,file_name)
select id,'id',user_id||'/id/x-id.pdf','id.pdf' from public.provider_profiles where business_name='Carol Detail';
select t.run('admin cannot approve with only an ID', :dave, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where business_name='Carol Detail'),'approve',null)$q$, 'err');
insert into public.provider_documents(provider_id,kind,storage_path,file_name)
select id,'license',user_id||'/license/x-lic.pdf','lic.pdf' from public.provider_profiles where business_name='Carol Detail';
select t.run('admin approves carol (ID + license present)', :dave, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where business_name='Carol Detail'),'approve',null)$q$, 'ok');
select t.run('anon sees approved carol only', null, 'anon', $q$select * from public.provider_profiles$q$, '1');
select t.run('admin cannot change own role', :dave, 'authenticated', $q$select public.admin_set_user_role(auth.uid(),'customer')$q$, 'err');
select t.run('non-admin cannot set roles', :alice, 'authenticated', $q$select public.admin_set_user_role(auth.uid(),'admin')$q$, 'err');

-- SERVICES
insert into public.service_catalog(name,description,category,suggested_price,default_duration_minutes) values
 ('Full Detail','Complete inside and out','car_detailing',100,120),('Draft','Draft service','car_detailing',50,60),('Window Tint','Ceramic film','car_detailing',80,90);
select t.run('approved provider picks a catalog service (active)', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price,status) select id,(select id from public.service_catalog where name='Full Detail'),100,'active' from public.provider_profiles where user_id=auth.uid()$q$, 'ok');
select t.run('approved provider picks another one as a draft', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price,status) select id,(select id from public.service_catalog where name='Draft'),50,'draft' from public.provider_profiles where user_id=auth.uid()$q$, 'ok');
select t.run('pending provider cannot pick a service', :bob, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price) select id,(select id from public.service_catalog where name='Full Detail'),10 from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.chk('the name, description and category come from the catalog', (select count(*)=2 and bool_and(s.name=c.name and s.description is not distinct from c.description and s.category=c.category and s.approval='approved') from public.services s join public.service_catalog c on c.id=s.catalog_id));
select t.run('provider cannot type her own service name', :carol, 'authenticated', $q$insert into public.services(provider_id,name,price) select id,'My Own Thing',10 from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('provider cannot send a name along with a catalog pick', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,name,price) select id,(select id from public.service_catalog where name='Window Tint'),'Sneaky name',10 from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('provider cannot pick the same service twice', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price) select id,(select id from public.service_catalog where name='Full Detail'),10 from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('provider cannot pick an id that is not in the list', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price) select id,gen_random_uuid(),10 from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('anon sees the active service', null, 'anon', $q$select * from public.services$q$, '1');
select id as fd_id from public.services where name='Full Detail' \gset
select t.run('provider cannot rename her service', :carol, 'authenticated', $q$update public.services set name='Renamed' where name='Full Detail'$q$, 'err');
select t.run('provider cannot change its description or category', :carol, 'authenticated', $q$update public.services set description='x', category='handyman' where name='Full Detail'$q$, 'err');
select t.run('provider cannot point it at another catalog item', :carol, 'authenticated', $q$update public.services set catalog_id=(select id from public.service_catalog where name='Window Tint') where name='Full Detail'$q$, 'err');
select t.run('provider cannot change the approval', :carol, 'authenticated', $q$update public.services set approval='rejected' where name='Full Detail'$q$, 'err');
select t.run('provider cannot create an already approved service', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price,approval) select id,(select id from public.service_catalog where name='Window Tint'),10,'approved' from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('provider sees own services incl draft', :carol, 'authenticated', $q$select * from public.services$q$, '2');
select t.run('anon sees only active service', null, 'anon', $q$select * from public.services$q$, '1');
select t.run('customer cannot change others service price', :alice, 'authenticated', $q$update public.services set price=1$q$, '0');
select t.run('provider cannot move service to another provider', :carol, 'authenticated', $q$update public.services set provider_id=(select id from public.provider_profiles where business_name like 'Bob%') where name='Draft'$q$, 'err');

-- PHOTOS
select t.run('provider adds photo to own service (own folder)', :carol, 'authenticated', $q$insert into public.service_photos(service_id,storage_path) select id,auth.uid()::text||'/x.jpg' from public.services where name='Full Detail'$q$, 'ok');
select t.run('photo row cannot point at another users folder', :carol, 'authenticated', $q$insert into public.service_photos(service_id,storage_path) select id,'e0000000-0000-0000-0000-000000000005/stolen.jpg' from public.services where name='Full Detail'$q$, 'err');
select t.run('photo path cannot be rewritten to another users folder', :carol, 'authenticated', $q$update public.service_photos set storage_path='e0000000-0000-0000-0000-000000000005/stolen.jpg'$q$, 'err');
select t.run('other user cannot add photo to carols service', :bob, 'authenticated', $q$insert into public.service_photos(service_id,storage_path) select id,'b/x.jpg' from public.services where name='Full Detail'$q$, 'err');
select t.run('anon sees photo of active service', null, 'anon', $q$select * from public.service_photos$q$, '1');
select t.run('provider can add up to 5 photos (4 more)', :carol, 'authenticated', $q$insert into public.service_photos(service_id,storage_path) select id,auth.uid()::text||'/p'||g||'.jpg' from public.services, generate_series(1,4) g where name='Full Detail'$q$, '4');
select t.run('6th photo is rejected', :carol, 'authenticated', $q$insert into public.service_photos(service_id,storage_path) select id,auth.uid()::text||'/p6.jpg' from public.services where name='Full Detail'$q$, 'err');
select t.run('anon cannot see photos of a draft service', null, 'anon', $q$select * from public.service_photos sp join public.services s on s.id=sp.service_id where s.status='draft'$q$, '0');

-- BOOKINGS
select t.run('customer cannot set service_price', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address,service_price) select auth.uid(),id,now()+interval '1 day','1 Main',0 from public.services where name='Full Detail'$q$, 'err');
select t.run('customer cannot set status=completed', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address,status) select auth.uid(),id,now()+interval '1 day','1 Main','completed' from public.services where name='Full Detail'$q$, 'err');
select t.run('customer cannot book draft service', :alice, 'authenticated', format($q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) values (auth.uid(),%L,now()+interval '1 day','1 Main')$q$, (select id from public.services where name='Draft')), 'err');
select t.run('customer cannot book in the past', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()-interval '1 day','1 Main' from public.services where name='Full Detail'$q$, 'err');
select t.run('provider cannot book own service', :carol, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '1 day','1 Main' from public.services where name='Full Detail'$q$, 'err');
select t.run('customer cannot book as someone else', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select 'e0000000-0000-0000-0000-000000000005',id,now()+interval '1 day','1 Main' from public.services where name='Full Detail'$q$, 'err');
select t.run('customer books valid service', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '1 day','1 Main' from public.services where name='Full Detail'$q$, 'ok');
select t.chk('price/commission/payout/status computed by DB', (select service_price=100 and platform_commission=10 and provider_payout=90 and status='pending' and provider_id=(select id from public.provider_profiles where business_name='Carol Detail') from public.bookings));
select t.run('customer cannot UPDATE booking directly', :alice, 'authenticated', $q$update public.bookings set status='completed'$q$, 'err');
select t.run('provider cannot UPDATE booking directly', :carol, 'authenticated', $q$update public.bookings set service_price=500$q$, 'err');
select t.run('customer cannot DELETE booking', :alice, 'authenticated', $q$delete from public.bookings$q$, 'err');
select t.run('stranger sees no bookings', :eve, 'authenticated', $q$select * from public.bookings$q$, '0');
select t.run('provider sees their booking', :carol, 'authenticated', $q$select * from public.bookings$q$, '1');
select t.run('customer sees own booking', :alice, 'authenticated', $q$select * from public.bookings$q$, '1');
select t.run('provider can read booking customer profile', :carol, 'authenticated', $q$select * from public.profiles where id='a0000000-0000-0000-0000-000000000001'$q$, '1');
select t.run('provider cannot read unrelated profile', :carol, 'authenticated', $q$select * from public.profiles where id='e0000000-0000-0000-0000-000000000005'$q$, '0');

-- TRANSITIONS
select t.run('stranger cannot transition', :eve, 'authenticated', $q$select public.transition_booking((select id from public.bookings limit 1),'cancelled')$q$, 'err');
select t.run('customer cannot complete', :alice, 'authenticated', $q$select public.transition_booking((select id from public.bookings limit 1),'completed')$q$, 'err');
select t.run('provider cannot skip pending->completed', :carol, 'authenticated', $q$select public.transition_booking((select id from public.bookings limit 1),'completed')$q$, 'err');
select t.run('review before completion rejected', :alice, 'authenticated', $q$insert into public.reviews(booking_id,rating) select id,5 from public.bookings limit 1$q$, 'err');
select t.run('provider confirms', :carol, 'authenticated', $q$select public.transition_booking((select id from public.bookings limit 1),'confirmed')$q$, 'ok');
select t.run('provider starts', :carol, 'authenticated', $q$select public.transition_booking((select id from public.bookings limit 1),'in_progress')$q$, 'ok');
select t.run('customer cannot cancel in_progress', :alice, 'authenticated', $q$select public.transition_booking((select id from public.bookings limit 1),'cancelled')$q$, 'err');
select t.prep_all();
select t.run('provider completes', :carol, 'authenticated', $q$select public.transition_booking((select id from public.bookings limit 1),'completed')$q$, 'ok');
select t.run('customer books again', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '2 day','1 Main' from public.services where name='Full Detail'$q$, 'ok');
select t.run('customer cancels pending booking', :alice, 'authenticated', $q$select public.transition_booking((select id from public.bookings where status='pending'),'cancelled')$q$, 'ok');
select t.run('cannot cancel twice', :alice, 'authenticated', $q$select public.transition_booking((select id from public.bookings where status='cancelled'),'cancelled')$q$, 'err');

-- REVIEWS
select t.run('stranger cannot review alices booking', :eve, 'authenticated', format($q$insert into public.reviews(booking_id,rating) values (%L,1)$q$, (select id from public.bookings where status='completed')), 'err');
select t.run('customer cannot pass customer_id column', :alice, 'authenticated', $q$insert into public.reviews(booking_id,customer_id,rating) select id,auth.uid(),5 from public.bookings where status='completed'$q$, 'err');
select t.run('cannot review cancelled booking', :alice, 'authenticated', $q$insert into public.reviews(booking_id,rating) select id,5 from public.bookings where status='cancelled'$q$, 'err');
select t.run('customer reviews completed booking', :alice, 'authenticated', $q$insert into public.reviews(booking_id,rating,comment) select id,4,'good' from public.bookings where status='completed'$q$, 'ok');
select t.run('cannot review twice', :alice, 'authenticated', $q$insert into public.reviews(booking_id,rating) select id,5 from public.bookings where status='completed'$q$, 'err');
select t.chk('provider rating/review_count updated by trigger', (select rating=4 and review_count=1 from public.provider_profiles where business_name='Carol Detail'));
select t.run('customer cannot edit review', :alice, 'authenticated', $q$update public.reviews set rating=5$q$, 'err');
select t.run('anon can read reviews', null, 'anon', $q$select * from public.reviews$q$, '1');

-- PAYMENTS / SUBSCRIPTIONS
select t.run('customer cannot insert payment', :alice, 'authenticated', $q$insert into public.payments(booking_id,customer_id,amount,status) select id,customer_id,1,'paid' from public.bookings limit 1$q$, 'err');
select t.run('customer reads own payments (0, no error)', :alice, 'authenticated', $q$select * from public.payments$q$, '0');
select t.run('anon cannot read payments', null, 'anon', $q$select * from public.payments$q$, 'err');
select t.run('provider cannot insert subscription', :carol, 'authenticated', $q$insert into public.subscriptions(provider_id,status) select id,'active' from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('provider reads own subscription (0, no error)', :carol, 'authenticated', $q$select * from public.subscriptions$q$, '0');

-- ADMIN READ
select t.run('admin sees all bookings', :dave, 'authenticated', $q$select * from public.bookings$q$, '2');
select t.run('admin sees all profiles', :dave, 'authenticated', $q$select * from public.profiles$q$, '5');
select t.run('admin cannot UPDATE bookings directly', :dave, 'authenticated', $q$update public.bookings set service_price=0$q$, 'err');

-- ANON
select t.run('anon cannot read bookings', null, 'anon', $q$select * from public.bookings$q$, 'err');
select t.run('anon cannot read profiles', null, 'anon', $q$select * from public.profiles$q$, 'err');
select t.run('anon cannot call register_provider', null, 'anon', $q$select public.register_provider('x','individual',array['handyman'],'2145550100',true)$q$, 'err');
select t.run('anon cannot call transition_booking', null, 'anon', $q$select public.transition_booking(gen_random_uuid(),'cancelled')$q$, 'err');
select t.run('anon cannot call admin RPC', null, 'anon', $q$select public.admin_set_user_role(gen_random_uuid(),'admin')$q$, 'err');
select t.run('anon cannot call is_admin', null, 'anon', $q$select private.is_admin()$q$, 'err');

-- BOOKING HISTORY SURVIVES (migration 003)
update public.services set status='inactive' where name='Full Detail';
select t.run('customer still sees deactivated service they booked', :alice, 'authenticated', $q$select * from public.services where name='Full Detail'$q$, '1');
select t.run('stranger cannot see deactivated service', :eve, 'authenticated', $q$select * from public.services where name='Full Detail'$q$, '0');
select t.run('anon cannot see deactivated service', null, 'anon', $q$select * from public.services where name='Full Detail'$q$, '0');
update public.provider_profiles set status='suspended' where business_name='Carol Detail';
select t.run('customer still sees suspended provider they booked', :alice, 'authenticated', $q$select * from public.provider_profiles where business_name='Carol Detail'$q$, '1');
select t.run('stranger cannot see suspended provider', :eve, 'authenticated', $q$select * from public.provider_profiles where business_name='Carol Detail'$q$, '0');
select t.run('anon cannot see suspended provider', null, 'anon', $q$select * from public.provider_profiles where business_name='Carol Detail'$q$, '0');

-- PAYMENTS (migration 005)
select t.run('anon cannot call start_booking_payment', null, 'anon', $q$select * from public.start_booking_payment(gen_random_uuid(), gen_random_uuid())$q$, 'err');
select t.run('customer cannot call start_booking_payment', :alice, 'authenticated', $q$select * from public.start_booking_payment(gen_random_uuid(), auth.uid())$q$, 'err');
select t.run('customer cannot call record_payment_result (fake paid)', :alice, 'authenticated', $q$select public.record_payment_result('cs_x','pi_x',100,'paid')$q$, 'err');
select t.run('customer cannot call attach_checkout_session', :alice, 'authenticated', $q$select public.attach_checkout_session(gen_random_uuid(),'cs_x')$q$, 'err');
select t.run('customer cannot insert a paid payment', :alice, 'authenticated', $q$insert into public.payments(booking_id,customer_id,amount,status) select id,customer_id,100,'paid' from public.bookings limit 1$q$, 'err');
update public.services set status='active' where name='Full Detail';
update public.provider_profiles set status='approved' where business_name='Carol Detail';
select t.run('alice books again for payment tests', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '3 day','1 Main' from public.services where name='Full Detail'$q$, 'ok');
select t.run('alice makes a second booking', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '4 day','2 Main' from public.services where name='Full Detail'$q$, 'ok');
select id as conf_pre from public.bookings where status='pending' order by created_at limit 1 \gset
select t.run('provider confirms one of them', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'conf_pre'), 'ok');
select id as pend_id, customer_id as pend_cust from public.bookings where status='pending' limit 1 \gset
select id as conf_id, customer_id as conf_cust from public.bookings where status='confirmed' limit 1 \gset
select t.chk('payment test fixtures exist', :'pend_id' is not null and :'conf_id' is not null);
select t.run('cannot pay a booking the provider has not confirmed', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'pend_id', :'pend_cust'), 'err');
select t.run('cannot pay for someone elses booking', null, 'service_role', format($q$select * from public.start_booking_payment(%L,'e0000000-0000-0000-0000-000000000005')$q$, :'conf_id'), 'err');
select t.run('server starts payment for confirmed booking', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'conf_id', :'conf_cust'), '1');
select t.chk('payment amount and fee come from the booking (100 / 10 / 90)', (select amount=100 and platform_fee=10 and provider_amount=90 and status='pending' from public.payments));
select id as pay_id from public.payments limit 1 \gset
select t.run('server attaches session 1', null, 'service_role', format($q$select public.attach_checkout_session(%L,'cs_test_1')$q$, :'pay_id'), 'ok');
select t.run('wrong amount from Stripe is not accepted', null, 'service_role', $q$select public.record_payment_result('cs_test_1','pi_1',1,'paid')$q$, 'ok');
select t.chk('amount mismatch marks payment failed, not paid', (select status='failed' from public.payments));
select t.run('customer can retry payment after failure', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'conf_id', :'conf_cust'), '1');
select t.run('server attaches session 2', null, 'service_role', format($q$select public.attach_checkout_session(%L,'cs_test_2')$q$, :'pay_id'), 'ok');
select t.run('unknown session is ignored', null, 'service_role', $q$select public.record_payment_result('cs_nope','pi_x',100,'paid')$q$, 'ok');
select t.chk('unknown session did not mark anything paid', (select status='pending' from public.payments));
select t.run('correct amount marks paid', null, 'service_role', $q$select public.record_payment_result('cs_test_2','pi_2',100,'paid')$q$, 'ok');
select t.chk('payment is paid with intent saved', (select status='paid' and stripe_payment_intent_id='pi_2' from public.payments));
select t.run('webhook replay does nothing', null, 'service_role', $q$select public.record_payment_result('cs_test_2','pi_2',100,'failed')$q$, 'ok');
select t.chk('replay did not undo paid status', (select status='paid' from public.payments));
select t.run('cannot pay twice', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'conf_id', :'conf_cust'), 'err');
select t.run('customer sees own payment', :alice, 'authenticated', $q$select * from public.payments$q$, '1');
select t.run('stranger sees no payments', :eve, 'authenticated', $q$select * from public.payments$q$, '0');
select t.run('customer cannot edit payment status', :alice, 'authenticated', $q$update public.payments set status='refunded'$q$, 'err');
select t.run('admin sees all payments', :dave, 'authenticated', $q$select * from public.payments$q$, '1');

-- PROVIDER PAYOUTS (migration 006)
select id as carol_prov from public.provider_profiles where business_name='Carol Detail' \gset
select t.run('customer cannot call claim_payout', :alice, 'authenticated', $q$select * from public.claim_payout(gen_random_uuid(), null)$q$, 'err');
select t.run('provider cannot call finish_payout (fake payout)', :carol, 'authenticated', $q$select public.finish_payout(gen_random_uuid(),'tr_x')$q$, 'err');
select t.run('provider cannot save a payout account directly', :carol, 'authenticated', format($q$select public.save_payout_account(%L,'acct_evil')$q$, :'carol_prov'), 'err');
select t.run('provider cannot enable own payout account', :carol, 'authenticated', $q$select public.set_payout_account_status('acct_x', true)$q$, 'err');
select t.run('anon cannot call payments_awaiting_payout', null, 'anon', $q$select public.payments_awaiting_payout('acct_x')$q$, 'err');
select t.run('users cannot read payout accounts table', :carol, 'authenticated', $q$select * from public.provider_payout_accounts$q$, 'err');
select t.run('anon cannot read payout accounts table', null, 'anon', $q$select * from public.provider_payout_accounts$q$, 'err');
select t.run('users cannot write payout accounts table', :carol, 'authenticated', format($q$insert into public.provider_payout_accounts(provider_id,stripe_account_id,payouts_enabled) values (%L,'acct_evil',true)$q$, :'carol_prov'), 'err');
select t.run('payout setup refused for a pending provider', null, 'service_role', format($q$select * from public.payout_account_for_user(%L)$q$, 'b0000000-0000-0000-0000-000000000002'), 'err');
select t.run('payout setup allowed for approved provider', null, 'service_role', format($q$select * from public.payout_account_for_user(%L)$q$, 'c0000000-0000-0000-0000-000000000003'), '1');

select code as c1 from public.claim_payout(:'pay_id', null) \gset
select t.chk('no payout before the service is completed', :'c1' = 'not_completed');
select t.run('provider starts job', :carol, 'authenticated', format($q$select public.transition_booking(%L,'in_progress')$q$, :'conf_id'), 'ok');
select t.prep_all();
select t.run('provider completes job', :carol, 'authenticated', format($q$select public.transition_booking(%L,'completed')$q$, :'conf_id'), 'ok');
select t.chk('completed but customer has not confirmed -> payout waits', (select code from public.claim_payout(:'pay_id', null)) = 'awaiting_confirmation');
select t.run('customer confirms the job is done', :alice, 'authenticated', format($q$select public.confirm_completion(%L)$q$, :'conf_id'), 'ok');
select code as c2 from public.claim_payout(:'pay_id', null) \gset
select t.chk('completed + paid but provider has no Stripe account -> waits', :'c2' = 'no_account');
select public.save_payout_account(:'carol_prov', 'acct_carol');
select code as c3 from public.claim_payout(:'pay_id', null) \gset
select t.chk('account exists but setup unfinished -> still waits', :'c3' = 'no_account');
select t.chk('status flag starts false', (select not connected_ok from (select payouts_enabled as connected_ok from public.provider_payout_accounts) x));
select t.chk('unknown Stripe account changes nothing', public.set_payout_account_status('acct_unknown', true) is null);
select t.chk('account marked ready returns the provider', public.set_payout_account_status('acct_carol', true) = :'carol_prov'::uuid);
select t.chk('waiting payout is listed for that account', (select count(*) from public.payments_awaiting_payout('acct_carol')) = 1);
select t.run('someone else cannot trigger the payout', null, 'postgres', format($q$select * from public.claim_payout(%L,'e0000000-0000-0000-0000-000000000005')$q$, :'pay_id'), 'err');
select code as c4, amount as a4, account_id as acc4 from public.claim_payout(:'pay_id', 'c0000000-0000-0000-0000-000000000003') \gset
select t.chk('owner can claim: ok, provider share 90, right account', :'c4'='ok' and :'a4'::numeric = 90 and :'acc4'='acct_carol');
select code as c5 from public.claim_payout(:'pay_id', null) \gset
select t.chk('second claim while processing is refused (no double payout)', :'c5' = 'already');
select t.chk('processing payment is not listed as waiting', (select count(*) from public.payments_awaiting_payout('acct_carol')) = 0);
select public.fail_payout(:'pay_id');
select t.chk('failed payout is listed again for retry', (select count(*) from public.payments_awaiting_payout('acct_carol')) = 1);
select code as c6 from public.claim_payout(:'pay_id', null) \gset
select t.chk('retry after failure is allowed', :'c6' = 'ok');
select public.finish_payout(:'pay_id', 'tr_123');
select t.chk('payout recorded as sent with transfer id', (select payout_status='sent' and stripe_transfer_id='tr_123' from public.payments));
select code as c7 from public.claim_payout(:'pay_id', null) \gset
select t.chk('sent payout can never be claimed again', :'c7' = 'already');
select public.fail_payout(:'pay_id');
select t.chk('fail_payout cannot undo a sent payout', (select payout_status='sent' from public.payments));
select t.run('provider sees own payout status', :carol, 'authenticated', $q$select * from public.my_payout_status()$q$, '1');
select t.chk('status reports connected and enabled', (select connected and payouts_enabled from (select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000003',true)) s, lateral public.my_payout_status()));
select t.run('customer gets no payout status', :alice, 'authenticated', $q$select * from public.my_payout_status()$q$, '0');
select t.run('provider sees payout state of own bookings', :carol, 'authenticated', $q$select * from public.my_booking_payouts()$q$, '1');
select t.run('customer sees no provider payout rows', :alice, 'authenticated', $q$select * from public.my_booking_payouts()$q$, '0');
select t.run('other provider sees nothing of carols payouts', :bob, 'authenticated', $q$select * from public.my_booking_payouts()$q$, '0');

-- SERVICE AREAS (migration 007)
select t.run('anyone can call services_in_area (anon)', null, 'anon', $q$select * from public.services_in_area('75038')$q$, 'ok');
select t.run('customer cannot write areas directly', :alice, 'authenticated', format($q$insert into public.provider_service_areas(provider_id,kind,label) values (%L,'zip','75001')$q$, :'carol_prov'), 'err');
select t.run('customer cannot call set_service_areas (not a provider)', :alice, 'authenticated', $q$select public.set_service_areas(array['Irving'])$q$, 'err');
select t.run('anon cannot call set_service_areas', null, 'anon', $q$select public.set_service_areas(array['Irving'])$q$, 'err');
select t.run('provider sets areas: city + ZIP', :carol, 'authenticated', $q$select public.set_service_areas(array['irving','  75038 ','Dallas, TX','IRVING','75039'])$q$, 'ok');
select t.chk('areas are cleaned, de-duplicated and capitalised (4: Irving, Dallas, 75038, 75039)', (select count(*)=4 and bool_and(label in ('Irving','Dallas','75038','75039')) from public.provider_service_areas where provider_id=:'carol_prov'));
select t.run('bad ZIP/city rejected (4 digits)', :carol, 'authenticated', $q$select public.set_service_areas(array['7503'])$q$, 'err');
select t.run('bad characters rejected (SQL-ish text)', :carol, 'authenticated', $q$select public.set_service_areas(array['Irving; drop table x'])$q$, 'err');
select t.run('more than 30 areas rejected', :carol, 'authenticated', $q$select public.set_service_areas((select array_agg(lpad(g::text,5,'0')) from generate_series(1,31) g))$q$, 'err');
select t.chk('failed attempts changed nothing (still 4 areas)', (select count(*)=4 from public.provider_service_areas where provider_id=:'carol_prov'));
select t.run('another provider only ever changes their own areas', :bob, 'authenticated', $q$select public.set_service_areas(array['Plano'])$q$, 'ok');
select t.chk('carols areas untouched by bob', (select count(*)=4 from public.provider_service_areas where provider_id=:'carol_prov'));
select t.run('anon sees areas of approved provider', null, 'anon', $q$select * from public.provider_service_areas$q$, '4');
select t.run('search by ZIP finds carols services', null, 'anon', $q$select * from public.services_in_area('75038')$q$, '1');
select t.run('search by ZIP+4 works', null, 'anon', $q$select * from public.services_in_area('75038-1234')$q$, '1');
select t.run('search by city is case-insensitive', null, 'anon', $q$select * from public.services_in_area('  iRVing ')$q$, '1');
select t.run('search "Irving, TX" works', null, 'anon', $q$select * from public.services_in_area('Irving, TX')$q$, '1');
select t.run('place nobody serves finds nothing', null, 'anon', $q$select * from public.services_in_area('90210')$q$, '0');
select t.run('percent sign is not a wildcard', null, 'anon', $q$select * from public.services_in_area('%')$q$, '0');
select t.run('anon cannot see pending providers area', null, 'anon', $q$select * from public.provider_service_areas where label='Plano'$q$, '0');
select t.run('pending providers area gives no search results', null, 'anon', $q$select * from public.services_in_area('Plano')$q$, '0');
select t.run('provider can see own pending areas', :bob, 'authenticated', $q$select * from public.provider_service_areas where label='Plano'$q$, '1');
select t.run('admin sees every area', :dave, 'authenticated', $q$select * from public.provider_service_areas$q$, '5');
select t.run('provider clears areas with empty list', :bob, 'authenticated', $q$select public.set_service_areas(array[]::text[])$q$, 'ok');
select t.chk('empty list removes all areas', (select count(*)=0 from public.provider_service_areas where label='Plano'));
update public.services set status='draft' where name='Full Detail';
select t.run('draft services are not found by area search', null, 'anon', $q$select * from public.services_in_area('75038')$q$, '0');
update public.services set status='active' where name='Full Detail';

-- REFUNDS
select t.run('alice makes booking R1', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '6 day','R1' from public.services where name='Full Detail'$q$, 'ok');
select t.run('alice makes booking R2', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '7 day','R2' from public.services where name='Full Detail'$q$, 'ok');
select id as r1 from public.bookings where customer_address='R1' \gset
select id as r2 from public.bookings where customer_address='R2' \gset
select customer_id as r_cust from public.bookings where id=:'r1' \gset
select t.run('carol confirms R1', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'r1'), 'ok');
select t.run('carol confirms R2', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'r2'), 'ok');
select t.run('start payment R1', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'r1', :'r_cust'), '1');
select t.run('start payment R2', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'r2', :'r_cust'), '1');
select id as rp1 from public.payments where booking_id=:'r1' \gset
select id as rp2 from public.payments where booking_id=:'r2' \gset
select t.run('attach R1 session', null, 'service_role', format($q$select public.attach_checkout_session(%L,'cs_r1')$q$, :'rp1'), 'ok');
select t.run('attach R2 session', null, 'service_role', format($q$select public.attach_checkout_session(%L,'cs_r2')$q$, :'rp2'), 'ok');
select amount as r_amt from public.payments where id=:'rp1' \gset
select t.chk('paid result is plain "paid" for a live booking', (select public.record_payment_result('cs_r1','pi_r1',:r_amt,'paid'))='paid');
select t.chk('no refund requested while booking is alive', (select refund_status='none' from public.payments where id=:'rp1'));
select t.run('refund not allowed while booking not cancelled', null, 'service_role', format($q$select * from public.claim_refund(%L,null)$q$, :'rp1'), '1');
select t.chk('...and says not_cancelled', (select code from public.claim_refund(:'rp1', null))='not_cancelled');
select t.run('customer cannot call claim_refund directly', :alice, 'authenticated', format($q$select * from public.claim_refund(%L,null)$q$, :'rp1'), 'err');
select t.run('anon cannot call record_refund_event', null, 'anon', $q$select public.record_refund_event('pi_r1','re_x')$q$, 'err');
select t.run('customer cannot mark own payment refunded', :alice, 'authenticated', format($q$update public.payments set refund_status='done', status='refunded' where id=%L$q$, :'rp1'), 'err');
select t.run('customer cancels paid booking R1', :alice, 'authenticated', format($q$select public.transition_booking(%L,'cancelled')$q$, :'r1'), 'ok');
select t.chk('cancelling a paid booking requests a refund automatically', (select refund_status='requested' from public.payments where id=:'rp1'));
select t.chk('payment still "paid" until the money is returned', (select status='paid' from public.payments where id=:'rp1'));
select t.run('stranger (eve) cannot start someone elses refund', null, 'service_role', format($q$select * from public.claim_refund(%L,'e0000000-0000-0000-0000-000000000005')$q$, :'rp1'), 'err');
select code as rc1 from public.claim_refund(:'rp1', :'r_cust') \gset
select t.chk('customer claims refund: ok', :'rc1'='ok');
select t.chk('claim locks it (processing)', (select refund_status='processing' from public.payments where id=:'rp1'));
select t.chk('second claim says already (no double refund)', (select code from public.claim_refund(:'rp1', :carol))='already');
select public.fail_refund(:'rp1');
select t.chk('failed refund can be retried', (select refund_status='failed' from public.payments where id=:'rp1'));
select code as rc2 from public.claim_refund(:'rp1', null) \gset
select t.chk('retry claim ok after failure', :'rc2'='ok');
select public.finish_refund(:'rp1','re_1');
select t.chk('finished: payment refunded + refund done + id stored', (select status='refunded' and refund_status='done' and stripe_refund_id='re_1' from public.payments where id=:'rp1'));
select t.chk('claim after done says already', (select code from public.claim_refund(:'rp1', null))='already');
select t.chk('webhook replay after a refund does not revive the payment', (select public.record_payment_result('cs_r1','pi_r1',:r_amt,'paid'))='already_paid' and (select status='refunded' from public.payments where id=:'rp1'));
select t.chk('refund webhook is idempotent', (select public.record_refund_event('pi_r1','re_1'))='already_refunded');
select t.chk('refund webhook unknown payment', (select public.record_refund_event('pi_nope','re_1'))='unknown_payment');
select t.run('customer sees refunded state', :alice, 'authenticated', format($q$select * from public.payments where id=%L and status='refunded'$q$, :'rp1'), '1');
-- provider declines/cancels a paid booking -> also refund; late payment after cancel -> refund
select t.run('carol cancels confirmed R2 (unpaid yet)', :carol, 'authenticated', format($q$select public.transition_booking(%L,'cancelled')$q$, :'r2'), 'ok');
select t.chk('unpaid cancel requests no refund', (select refund_status='none' from public.payments where id=:'rp2'));
select t.chk('late payment for cancelled booking -> paid_cancelled', (select public.record_payment_result('cs_r2','pi_r2',(select amount from public.payments where id=:'rp2'),'paid'))='paid_cancelled');
select t.chk('...and a refund is requested', (select refund_status='requested' from public.payments where id=:'rp2'));
select code as rc3 from public.claim_refund(:'rp2', :carol) \gset
select t.chk('provider can trigger the refund too', :'rc3'='ok');
select t.chk('refund webhook (dashboard refund) closes it', (select public.record_refund_event('pi_r2','re_2'))='refunded');
select t.chk('payout never offered for refunded booking', (select code from public.claim_payout(:'rp2', null))<>'ok');

-- DISPUTES
select public.set_payout_account_status('acct_carol', true);
select t.run('alice books D1', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '8 day','D1' from public.services where name='Full Detail'$q$, 'ok');
select t.run('alice books D2', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '9 day','D2' from public.services where name='Full Detail'$q$, 'ok');
select id as d1 from public.bookings where customer_address='D1' \gset
select id as d2 from public.bookings where customer_address='D2' \gset
select customer_id as d_cust from public.bookings where id=:'d1' \gset
select t.run('carol confirms D1', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'d1'), 'ok');
select t.run('carol confirms D2', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'d2'), 'ok');
select t.run('start payment D1', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'d1', :'d_cust'), '1');
select t.run('start payment D2', null, 'service_role', format($q$select * from public.start_booking_payment(%L,%L)$q$, :'d2', :'d_cust'), '1');
select id as dp1 from public.payments where booking_id=:'d1' \gset
select id as dp2 from public.payments where booking_id=:'d2' \gset
select public.attach_checkout_session(:'dp1','cs_d1');
select public.attach_checkout_session(:'dp2','cs_d2');
select amount as d_amt from public.payments where id=:'dp1' \gset
select public.record_payment_result('cs_d1','pi_d1',:d_amt,'paid');
select public.record_payment_result('cs_d2','pi_d2',:d_amt,'paid');
select t.run('carol starts D1', :carol, 'authenticated', format($q$select public.transition_booking(%L,'in_progress')$q$, :'d1'), 'ok');
select t.prep_all();
select t.run('carol completes D1', :carol, 'authenticated', format($q$select public.transition_booking(%L,'completed')$q$, :'d1'), 'ok');
update public.bookings set confirmed_at = now() where id = :'d1';
select t.chk('before any dispute the payout is allowed', (select code from public.claim_payout(:'dp1', null))='ok');
select public.fail_payout(:'dp1');
select t.chk('new payments start with dispute none', (select dispute_status='none' from public.payments where id=:'dp1'));
select t.run('anon cannot record disputes', null, 'anon', $q$select public.record_dispute_event('pi_d1','dp_x','created',null)$q$, 'err');
select t.run('customer cannot record disputes', :alice, 'authenticated', $q$select public.record_dispute_event('pi_d1','dp_x','created',null)$q$, 'err');
select t.run('provider cannot record disputes', :carol, 'authenticated', $q$select public.record_dispute_event('pi_d1','dp_x','created',null)$q$, 'err');
select t.run('customer cannot edit dispute status', :alice, 'authenticated', format($q$update public.payments set dispute_status='won' where id=%L$q$, :'dp1'), 'err');
select t.chk('unknown payment is harmless', (select public.record_dispute_event('pi_nope','dp_x','created',null))='unknown_payment');
select t.chk('dispute opens', (select public.record_dispute_event('pi_d1','dp_1','created',null))='opened');
select t.chk('dispute opened is stored with id', (select dispute_status='open' and stripe_dispute_id='dp_1' from public.payments where id=:'dp1'));
select t.chk('replayed created event is "already"', (select public.record_dispute_event('pi_d1','dp_1','created',null))='already');
select t.chk('payout blocked while disputed', (select code from public.claim_payout(:'dp1', null))='disputed');
select t.chk('waiting-payout list skips disputed payment', not exists (select 1 from public.payments_awaiting_payout('acct_carol') x where x=:'dp1'));
select t.chk('provider sees dispute on own booking', (select count(*)=1 from (select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000003',true)) s, lateral public.my_booking_payouts() m where m.booking_id=:'d1' and m.dispute_status='open'));
select t.run('admin sees the dispute', :dave, 'authenticated', 'select * from public.admin_disputes()', '1');
select t.run('customer gets no rows from admin_disputes', :alice, 'authenticated', 'select * from public.admin_disputes()', '0');
select t.run('provider gets no rows from admin_disputes', :carol, 'authenticated', 'select * from public.admin_disputes()', '0');
select t.run('anon cannot call admin_disputes', null, 'anon', 'select * from public.admin_disputes()', 'err');
select t.chk('closed with unknown outcome is ignored', (select public.record_dispute_event('pi_d1','dp_1','closed','needs_response'))='ignored');
select t.chk('dispute won', (select public.record_dispute_event('pi_d1','dp_1','closed','won'))='won');
select t.chk('won twice is "already"', (select public.record_dispute_event('pi_d1','dp_1','closed','won'))='already');
select t.chk('after winning, payout is allowed again', (select code from public.claim_payout(:'dp1', null))='ok');
select public.finish_payout(:'dp1','tr_d1');
select t.chk('dispute on an already-paid-out payment opens', (select public.record_dispute_event('pi_d1','dp_2','created',null))='opened');
select t.chk('...and admin sees it flagged "provider already paid"', (select payout_already_sent from (select set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000004',true)) s, lateral public.admin_disputes() d where d.payment_id=:'dp1'));
select t.chk('lost dispute', (select public.record_dispute_event('pi_d1','dp_2','closed','lost'))='lost');
select t.chk('a lost dispute cannot be reopened by replay', (select public.record_dispute_event('pi_d1','dp_2','created',null))='already');
-- refunds vs disputes (D2: paid, then cancelled by customer)
select t.chk('D2 dispute opens', (select public.record_dispute_event('pi_d2','dp_3','created',null))='opened');
select t.run('customer cancels disputed D2', :alice, 'authenticated', format($q$select public.transition_booking(%L,'cancelled')$q$, :'d2'), 'ok');
select t.chk('refund blocked while the bank holds the money', (select code from public.claim_refund(:'dp2', null))='disputed');
select t.chk('refund request stays flagged (not lost)', (select refund_status='requested' from public.payments where id=:'dp2'));
select public.record_dispute_event('pi_d2','dp_3','closed','won');
select t.chk('after winning, the cancelled booking can be refunded', (select code from public.claim_refund(:'dp2', null))='ok');

-- SUBSCRIPTIONS
select t.run('anon cannot call subscription_context', null, 'anon', format($q$select * from public.subscription_context(%L)$q$, 'c0000000-0000-0000-0000-000000000003'), 'err');
select t.run('provider cannot call subscription_context directly', :carol, 'authenticated', format($q$select * from public.subscription_context(%L)$q$, 'c0000000-0000-0000-0000-000000000003'), 'err');
select t.run('provider cannot apply subscription state to self', :carol, 'authenticated', format($q$select public.apply_subscription_state(%L,'cus_1','sub_1','active',now(),now())$q$, :'carol_prov'), 'err');
select t.run('provider cannot make themselves Pro by update', :carol, 'authenticated', $q$update public.provider_profiles set is_pro = true$q$, 'err');
select t.run('provider cannot lower own commission', :carol, 'authenticated', $q$update public.provider_profiles set commission_rate = 0$q$, 'err');
select t.run('customer cannot start a subscription', null, 'service_role', format($q$select * from public.subscription_context(%L)$q$, 'e0000000-0000-0000-0000-000000000005'), 'err');
select t.run('pending provider cannot subscribe yet', null, 'service_role', format($q$select * from public.subscription_context(%L)$q$, 'b0000000-0000-0000-0000-000000000002'), 'err');
select t.run('approved provider can start', null, 'service_role', format($q$select * from public.subscription_context(%L)$q$, 'c0000000-0000-0000-0000-000000000003'), '1');
select t.chk('new providers are not Pro, fee 10%', (select not is_pro and commission_rate=10 from public.provider_profiles where id=:'carol_prov'));
select t.chk('state before any customer saved: unknown_provider', (select public.apply_subscription_state(:'carol_prov','cus_1','sub_1','active',now(),now()+interval '30 day'))='unknown_provider');
select public.save_subscription_customer(:'carol_prov','cus_1');
select t.chk('saved customer id is kept (second save does not replace)', (select public.save_subscription_customer(:'carol_prov','cus_other') is null) and (select stripe_customer_id='cus_1' from public.subscriptions where provider_id=:'carol_prov'));
select t.chk('wrong Stripe customer is refused', (select public.apply_subscription_state(:'carol_prov','cus_evil','sub_1','active',now(),now()+interval '30 day'))='customer_mismatch');
select t.chk('refused update changed nothing', (select not is_pro from public.provider_profiles where id=:'carol_prov'));
select t.chk('active subscription -> pro', (select public.apply_subscription_state(:'carol_prov','cus_1','sub_1','active',now(),now()+interval '30 day'))='pro');
select t.chk('Pro: flag on, fee 5%, plan stored', (select is_pro and commission_rate=5 from public.provider_profiles where id=:'carol_prov') and (select plan_name='pro' and status='active' and stripe_subscription_id='sub_1' from public.subscriptions where provider_id=:'carol_prov'));
select t.run('anon sees the Pro flag (for search order)', null, 'anon', $q$select * from public.provider_profiles where is_pro$q$, '1');
select t.chk('provider already Pro cannot start again', (select already_pro from public.subscription_context('c0000000-0000-0000-0000-000000000003')));
select t.chk('my_subscription reports plan', (select is_pro and status='active' and commission_rate=5 and has_customer from (select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000003',true)) s, lateral public.my_subscription()));
select t.run('new booking while Pro gets 5% fee', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '20 day','SubPro' from public.services where name='Full Detail'$q$, 'ok');
select t.chk('...fee snapshot is 5% of price', (select platform_commission = round(service_price*0.05,2) from public.bookings where customer_address='SubPro'));
select t.chk('past_due keeps Pro while the card is retried', (select public.apply_subscription_state(:'carol_prov','cus_1','sub_1','past_due',now(),now()+interval '30 day'))='pro');
select t.chk('cancelled -> free', (select public.apply_subscription_state(:'carol_prov','cus_1','sub_1','canceled',now(),now()))='free');
select t.chk('Free again: flag off, fee 10%', (select not is_pro and commission_rate=10 from public.provider_profiles where id=:'carol_prov'));
select t.chk('earlier Pro booking keeps its 5% fee', (select platform_commission = round(service_price*0.05,2) from public.bookings where customer_address='SubPro'));
select t.chk('unpaid -> free', (select public.apply_subscription_state(:'carol_prov','cus_1','sub_9','unpaid',now(),now()))='free');
select t.chk('resubscribe with a new subscription works', (select public.apply_subscription_state(:'carol_prov','cus_1','sub_2','active',now(),now()+interval '30 day'))='pro');
select t.chk('an old subscription cancelling later does not drop the new one', (select public.apply_subscription_state(:'carol_prov','cus_1','sub_1','canceled',now(),now()))='pro' and (select is_pro from public.provider_profiles where id=:'carol_prov'));
select t.run('provider sees own subscription row', :carol, 'authenticated', $q$select * from public.subscriptions$q$, '1');
select t.run('other provider sees no subscription rows', :bob, 'authenticated', $q$select * from public.subscriptions$q$, '0');
select t.run('customer sees no subscription rows', :alice, 'authenticated', $q$select * from public.subscriptions$q$, '0');
select t.run('provider cannot write subscriptions', :carol, 'authenticated', $q$update public.subscriptions set status='active'$q$, 'err');
select t.run('admin sees subscriptions', :dave, 'authenticated', $q$select * from public.subscriptions$q$, '1');

-- EMAIL NOTIFICATIONS
select t.run('customer books a service (email test)', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '25 day','EmailT' from public.services where name='Full Detail' limit 1$q$, '1');
select t.chk('new booking queued one email for the provider', (select count(*) from public.email_outbox o join public.bookings b on b.id=o.booking_id where b.customer_address='EmailT' and o.kind='booking_new' and o.to_user='c0000000-0000-0000-0000-000000000003')=1);
select t.chk('nothing queued for the customer yet', (select count(*) from public.email_outbox o join public.bookings b on b.id=o.booking_id where b.customer_address='EmailT' and o.to_user=b.customer_id)=0);
select t.run('provider confirms (email test)', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, (select id from public.bookings where customer_address='EmailT')), 'ok');
select t.chk('confirm queued an email for the customer', (select count(*) from public.email_outbox o join public.bookings b on b.id=o.booking_id where b.customer_address='EmailT' and o.kind='booking_confirmed' and o.to_user=b.customer_id)=1);
select t.run('customer cancels (email test)', :alice, 'authenticated', format($q$select public.transition_booking(%L,'cancelled')$q$, (select id from public.bookings where customer_address='EmailT')), 'ok');
select t.chk('customer cancel emails ONLY the provider', (select string_agg(o.to_user::text, ',') from public.email_outbox o join public.bookings b on b.id=o.booking_id where b.customer_address='EmailT' and o.kind='booking_cancelled')='c0000000-0000-0000-0000-000000000003');
select public.queue_email('booking_new', (select id from public.bookings where customer_address='EmailT'), 'c0000000-0000-0000-0000-000000000003');
select t.chk('queueing the same email again changes nothing', (select count(*) from public.email_outbox o join public.bookings b on b.id=o.booking_id where b.customer_address='EmailT' and o.kind='booking_new')=1);
select t.run('customer cannot read the email queue', :alice, 'authenticated', $q$select * from public.email_outbox$q$, 'err');
select t.run('anon cannot read the email queue', null, 'anon', $q$select * from public.email_outbox$q$, 'err');
select t.run('provider cannot write the email queue', :carol, 'authenticated', $q$delete from public.email_outbox$q$, 'err');
select t.run('customer cannot queue an email', :alice, 'authenticated', format($q$select public.queue_email('booking_new',%L,%L)$q$, (select id from public.bookings where customer_address='EmailT'), :'alice'), 'err');
select t.run('customer cannot claim emails', :alice, 'authenticated', $q$select * from public.claim_emails(5)$q$, 'err');
select t.run('customer cannot mark emails sent', :alice, 'authenticated', $q$select public.finish_email(gen_random_uuid(), true)$q$, 'err');
select t.run('anon cannot claim emails', null, 'anon', $q$select * from public.claim_emails(5)$q$, 'err');
select t.run('service_role can claim emails', null, 'service_role', $q$select * from public.claim_emails(5)$q$, 'ok');
select t.chk('claimed rows are now being sent (attempt 1)', (select count(*) from public.email_outbox where status='sending' and attempts=1)>=1);

-- COMPLETION CONFIRMATION + REVIEWS
select t.run('alice books for confirmation test', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '30 day','CompT' from public.services where name='Full Detail' limit 1$q$, '1');
select id as cb from public.bookings where customer_address='CompT' \gset
select t.run('carol confirms CompT', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'cb'), 'ok');
select t.run('carol starts CompT', :carol, 'authenticated', format($q$select public.transition_booking(%L,'in_progress')$q$, :'cb'), 'ok');
select t.run('customer cannot confirm completion before the provider completes', :alice, 'authenticated', format($q$select public.confirm_completion(%L)$q$, :'cb'), 'err');
select t.prep_all();
select t.run('carol completes CompT', :carol, 'authenticated', format($q$select public.transition_booking(%L,'completed')$q$, :'cb'), 'ok');
select t.chk('completed_at is stamped by the database', (select completed_at is not null and confirmed_at is null and problem_status='none' from public.bookings where id=:'cb'));
select t.chk('customer was emailed to confirm', (select count(*) from public.email_outbox where booking_id=:'cb' and kind='booking_completed' and to_user='a0000000-0000-0000-0000-000000000001')=1);
select t.chk('not released yet', not public.payout_released((select b from public.bookings b where id=:'cb')));
-- reminder 24 h before the automatic confirmation
select t.run('service_role claims emails (nothing due yet)', null, 'service_role', $q$select * from public.claim_emails(5)$q$, 'ok');
select t.chk('no reminder while the job is brand new', (select count(*) from public.email_outbox where booking_id=:'cb' and kind='completion_reminder')=0);
update public.bookings set completed_at = now() - interval '73 hours' where id = :'cb';
select t.run('claim after the 72 h point', null, 'service_role', $q$select * from public.claim_emails(5)$q$, 'ok');
select t.chk('no reminder once the 72 h point has passed', (select count(*) from public.email_outbox where booking_id=:'cb' and kind='completion_reminder')=0);
update public.bookings set completed_at = now() - interval '49 hours' where id = :'cb';
select t.run('claim at 49 h', null, 'service_role', $q$select * from public.claim_emails(5)$q$, 'ok');
select t.chk('one reminder queued for the customer', (select count(*) from public.email_outbox where booking_id=:'cb' and kind='completion_reminder' and to_user='a0000000-0000-0000-0000-000000000001')=1);
select t.run('claim again', null, 'service_role', $q$select * from public.claim_emails(5)$q$, 'ok');
select t.chk('running again does not queue a second reminder', (select count(*) from public.email_outbox where booking_id=:'cb' and kind='completion_reminder')=1);
select t.run('customer cannot queue reminders', :alice, 'authenticated', $q$select public.queue_completion_reminders()$q$, 'err');
select t.run('anon cannot queue reminders', null, 'anon', $q$select public.queue_completion_reminders()$q$, 'err');
select t.chk('claim_emails returns completed_at', exists (select 1 from information_schema.parameters where specific_schema='public' and parameter_mode='OUT' and parameter_name='completed_at' and specific_name like 'claim_emails%'));
update public.bookings set completed_at = now() where id = :'cb';
select t.run('provider cannot confirm for the customer', :carol, 'authenticated', format($q$select public.confirm_completion(%L)$q$, :'cb'), 'err');
select t.run('stranger cannot confirm', :eve, 'authenticated', format($q$select public.confirm_completion(%L)$q$, :'cb'), 'err');
select t.run('anon cannot confirm', null, 'anon', format($q$select public.confirm_completion(%L)$q$, :'cb'), 'err');
select t.run('provider cannot report a problem', :carol, 'authenticated', format($q$select public.report_problem(%L,'it was bad enough')$q$, :'cb'), 'err');
select t.run('problem text too short is refused', :alice, 'authenticated', format($q$select public.report_problem(%L,'no')$q$, :'cb'), 'err');
select t.run('customer cannot write confirmed_at directly', :alice, 'authenticated', format($q$update public.bookings set confirmed_at=now() where id=%L$q$, :'cb'), 'err');
select t.chk('just after completion the payout is still held', (select public.payout_released(b) from (select * from public.bookings where id=:'cb') b) is false);
update public.bookings set completed_at = now() - interval '73 hours' where id = :'cb';
select t.chk('...after 72 h the payout is released', (select public.payout_released(b) from (select * from public.bookings where id=:'cb') b));
update public.bookings set completed_at = now() where id = :'cb';
select t.run('customer reports a problem', :alice, 'authenticated', format($q$select public.report_problem(%L,'The car was not cleaned inside')$q$, :'cb'), 'ok');
select t.chk('provider was emailed about the problem', (select count(*) from public.email_outbox where booking_id=:'cb' and kind='problem_reported')=1);
select t.run('reporting twice is harmless', :alice, 'authenticated', format($q$select public.report_problem(%L,'The car was not cleaned inside')$q$, :'cb'), 'ok');
update public.bookings set completed_at = now() - interval '100 hours' where id = :'cb';
select t.chk('an open problem blocks release even after 72 h', not public.payout_released((select b from public.bookings b where id=:'cb')));
select t.run('customer cannot resolve a problem', :alice, 'authenticated', format($q$select public.admin_resolve_problem(%L)$q$, :'cb'), 'err');
select t.run('provider cannot list problems', :carol, 'authenticated', $q$select * from public.admin_problems()$q$, 'err');
select t.run('admin lists the open problem', :dave, 'authenticated', $q$select * from public.admin_problems()$q$, '1');
select t.run('admin resolves it', :dave, 'authenticated', format($q$select public.admin_resolve_problem(%L)$q$, :'cb'), 'ok');
select t.chk('resolved: confirmed and released', (select public.payout_released(b) and b.problem_status='resolved' from (select * from public.bookings where id=:'cb') b));
select t.run('resolving again fails (no open problem)', :dave, 'authenticated', format($q$select public.admin_resolve_problem(%L)$q$, :'cb'), 'err');
select t.chk('provider was told the job was confirmed', (select count(*) from public.email_outbox where booking_id=:'cb' and kind='completion_confirmed')=1);
update public.email_outbox set status='pending', next_attempt_at=now() where booking_id=:'cb' and kind='completion_reminder';
select t.run('claim with a stale reminder waiting', null, 'service_role', $q$select * from public.claim_emails(5)$q$, 'ok');
select t.chk('a reminder is dropped once the job is confirmed', (select status='skipped' from public.email_outbox where booking_id=:'cb' and kind='completion_reminder'));
select t.run('alice reviews CompT with a comment', :alice, 'authenticated', format($q$insert into public.reviews(booking_id,rating,comment) values (%L,5,'Great work')$q$, :'cb'), 'ok');
select t.run('rating 6 is refused', :alice, 'authenticated', format($q$insert into public.reviews(booking_id,rating) values (%L,6)$q$, :'cb'), 'err');
select t.run('anon can read provider reviews', null, 'anon', format($q$select * from public.provider_reviews(%L)$q$, :'carol_prov'), '2');
select t.chk('reviewer is shown as first name only', (select bool_and(reviewer !~ '@' and char_length(reviewer) < 20) from public.provider_reviews(:'carol_prov')));
select t.chk('service page ratings update', (select review_count=2 from public.provider_profiles where id=:'carol_prov'));

-- CONTACT MESSAGES
select t.run('anon sends a contact message', null, 'anon', $q$select public.submit_contact('Sam','sam@example.com','general','Hello, I have a question about booking.')$q$, 'ok');
select t.run('signed-in user sends one', :alice, 'authenticated', $q$select public.submit_contact('Alice','alice@example.com','payment','My refund has not arrived yet, please check.')$q$, 'ok');
select t.chk('signed-in message is linked to the account, anon is not', (select count(*) filter (where user_id is not null)=1 and count(*) filter (where user_id is null)=1 from public.contact_messages));
select t.run('empty name refused', null, 'anon', $q$select public.submit_contact('  ','a@b.co','general','long enough message here')$q$, 'err');
select t.run('bad email refused', null, 'anon', $q$select public.submit_contact('Sam','not-an-email','general','long enough message here')$q$, 'err');
select t.run('unknown topic refused', null, 'anon', $q$select public.submit_contact('Sam','a@b.co','hack','long enough message here')$q$, 'err');
select t.run('too-short message refused', null, 'anon', $q$select public.submit_contact('Sam','a@b.co','general','hi')$q$, 'err');
select t.run('too-long message refused', null, 'anon', $q$select public.submit_contact('Sam','a@b.co','general',repeat('x',2001))$q$, 'err');
select t.run('anon cannot read the table', null, 'anon', $q$select * from public.contact_messages$q$, 'err');
select t.run('customer cannot read the table', :alice, 'authenticated', $q$select * from public.contact_messages$q$, 'err');
select t.run('customer cannot insert directly', :alice, 'authenticated', $q$insert into public.contact_messages(name,email,topic,message) values ('x','x@x.co','general','direct insert attempt')$q$, 'err');
select t.run('customer cannot list messages', :alice, 'authenticated', $q$select * from public.admin_contact_messages()$q$, 'err');
select t.run('anon cannot list messages', null, 'anon', $q$select * from public.admin_contact_messages()$q$, 'err');
select t.run('admin lists new messages', :dave, 'authenticated', $q$select * from public.admin_contact_messages()$q$, '2');
select id as cm1 from public.contact_messages where email='sam@example.com' \gset
select t.run('customer cannot mark handled', :alice, 'authenticated', format($q$select public.admin_contact_handled(%L)$q$, :'cm1'), 'err');
select t.run('admin marks one handled', :dave, 'authenticated', format($q$select public.admin_contact_handled(%L)$q$, :'cm1'), 'ok');
select t.run('new list now has one', :dave, 'authenticated', $q$select * from public.admin_contact_messages()$q$, '1');
select t.run('unknown message id fails', :dave, 'authenticated', $q$select public.admin_contact_handled('00000000-0000-0000-0000-000000000009')$q$, 'err');
select t.run('same sender 2nd message', null, 'anon', $q$select public.submit_contact('Sam','SAM@example.com','general','Second message from the same person.')$q$, 'ok');
select t.run('same sender 3rd', null, 'anon', $q$select public.submit_contact('Sam','sam@example.com','general','Third message from the same person.')$q$, 'ok');
select t.run('same sender 4th', null, 'anon', $q$select public.submit_contact('Sam','sam@example.com','general','Fourth message from the same person.')$q$, 'ok');
select t.run('same sender 5th', null, 'anon', $q$select public.submit_contact('Sam','sam@example.com','general','Fifth message from the same person.')$q$, 'ok');
select t.run('6th in an hour is refused (case-insensitive email)', null, 'anon', $q$select public.submit_contact('Sam','Sam@Example.com','general','Sixth message from the same person.')$q$, 'err');

-- ADMIN POWERS + AUDIT LOG
select t.chk('earlier admin actions were logged', (select count(*) from public.admin_audit where action='problem_released')=1);
select t.run('customer cannot read the audit log', :alice, 'authenticated', $q$select * from public.admin_audit_log()$q$, 'err');
select t.run('anon cannot read the audit log', null, 'anon', $q$select * from public.admin_audit_log()$q$, 'err');
select t.run('nobody can read the audit table directly', :dave, 'authenticated', $q$select * from public.admin_audit$q$, 'err');
select t.run('nobody can edit the audit log', :dave, 'authenticated', $q$update public.admin_audit set reason='x'$q$, 'err');
select t.run('the owner role cannot edit it either', null, 'service_role', $q$update public.admin_audit set reason='x'$q$, 'err');
select t.run('nor delete from it', null, 'service_role', $q$delete from public.admin_audit$q$, 'err');
select t.run('admin reads the audit log', :dave, 'authenticated', $q$select * from public.admin_audit_log()$q$, 'ok');

-- provider status + role changes are logged
select t.run('admin suspends carols business', :dave, 'authenticated', format($q$select * from public.admin_set_provider_status(%L,'suspended')$q$, :'carol_prov'), 'ok');
select t.run('admin approves it again', :dave, 'authenticated', format($q$select * from public.admin_set_provider_status(%L,'approved')$q$, :'carol_prov'), 'ok');
select t.chk('provider status changes are logged with from/to', (select count(*)>=2 and bool_and(details ? 'from' and details ? 'to') from public.admin_audit where action='provider_status'));
select t.run('admin promotes eve to provider', :dave, 'authenticated', $q$select * from public.admin_set_user_role('e0000000-0000-0000-0000-000000000005','provider')$q$, 'ok');
select t.run('...and back', :dave, 'authenticated', $q$select * from public.admin_set_user_role('e0000000-0000-0000-0000-000000000005','customer')$q$, 'ok');
select t.chk('role changes are logged', (select count(*)>=2 from public.admin_audit where action='user_role'));

-- deactivate / reactivate
select t.run('customer cannot deactivate', :alice, 'authenticated', format($q$select public.admin_set_user_active(%L,false,'trying my luck')$q$, :bob), 'err');
select t.run('anon cannot deactivate', null, 'anon', format($q$select public.admin_set_user_active(%L,false,'trying my luck')$q$, :bob), 'err');
select t.run('a reason is required', :dave, 'authenticated', format($q$select public.admin_set_user_active(%L,false,'no')$q$, :bob), 'err');
select t.run('cannot deactivate yourself', :dave, 'authenticated', format($q$select public.admin_set_user_active(%L,false,'by mistake please')$q$, :dave), 'err');
select t.run('cannot deactivate an admin directly', :dave, 'authenticated', $q$select public.admin_set_user_active('a0000000-0000-0000-0000-000000000099',false,'testing admins')$q$, 'err');
select t.run('unknown user', :dave, 'authenticated', $q$select public.admin_set_user_active('00000000-0000-0000-0000-000000000009',false,'does not exist')$q$, 'err');
select t.run('bob books while active', :bob, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '3 days','Bob St' from public.services where name='Full Detail'$q$, 'ok');
select t.run('admin deactivates bob', :dave, 'authenticated', format($q$select public.admin_set_user_active(%L,false,'Repeated no-shows and abuse')$q$, :bob), 'ok');
select t.chk('bob is deactivated and the reason is logged', (select not is_active from public.profiles where id=:bob) and (select reason='Repeated no-shows and abuse' from public.admin_audit where action='user_deactivated' order by created_at desc limit 1));
select t.run('deactivating twice is refused', :dave, 'authenticated', format($q$select public.admin_set_user_active(%L,false,'again for fun')$q$, :bob), 'err');
select t.run('deactivated bob cannot book', :bob, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '4 days','Bob St' from public.services where name='Full Detail'$q$, 'err');
select t.run('deactivated bob cannot cancel his booking', :bob, 'authenticated', $q$select public.transition_booking(id,'cancelled') from public.bookings where customer_address='Bob St' limit 1$q$, 'err');
select t.run('deactivated bob can still write to support', :bob, 'authenticated', $q$select public.submit_contact('Bob','bob@example.com','account','Please tell me why my account is off.')$q$, 'ok');
select t.run('admin reactivates bob', :dave, 'authenticated', format($q$select public.admin_set_user_active(%L,true,'Appeal accepted, warned')$q$, :bob), 'ok');
select t.run('bob can cancel again', :bob, 'authenticated', $q$select public.transition_booking(id,'cancelled') from public.bookings where customer_address='Bob St' limit 1$q$, 'ok');
select t.run('bob can book again', :bob, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '5 days','Bob St 2' from public.services where name='Full Detail'$q$, 'ok');
-- a deactivated provider
select t.run('admin deactivates carol (provider)', :dave, 'authenticated', format($q$select public.admin_set_user_active(%L,false,'Reported for fraud, under review')$q$, :carol), 'ok');
select t.chk('her business is suspended too', (select status='suspended' from public.provider_profiles where id=:'carol_prov'));
select t.run('deactivated provider cannot add a service', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price) select id,(select id from public.service_catalog where name='Window Tint'),10 from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('deactivated provider cannot edit her profile', :carol, 'authenticated', $q$update public.provider_profiles set description='x' where user_id=auth.uid()$q$, '0');
select t.run('deactivated provider cannot confirm a booking', :carol, 'authenticated', $q$select public.transition_booking(id,'confirmed') from public.bookings where status='pending' and provider_id=(select id from public.provider_profiles where user_id=auth.uid()) limit 1$q$, 'err');
select t.run('admin reactivates carol', :dave, 'authenticated', format($q$select public.admin_set_user_active(%L,true,'Cleared after review')$q$, :carol), 'ok');
select t.chk('reactivating does NOT approve the business again', (select status='suspended' from public.provider_profiles where id=:'carol_prov'));
select t.run('admin approves her business', :dave, 'authenticated', format($q$select * from public.admin_set_provider_status(%L,'approved')$q$, :'carol_prov'), 'ok');

-- hide / show a service
select id as hs from public.services where name='Full Detail' \gset
select t.run('customer cannot hide a service', :alice, 'authenticated', format($q$select public.admin_set_service_status(%L,'inactive','I do not like it')$q$, :'hs'), 'err');
select t.run('reason required to hide', :dave, 'authenticated', format($q$select public.admin_set_service_status(%L,'inactive','')$q$, :'hs'), 'err');
select t.run('draft is not a valid admin status', :dave, 'authenticated', format($q$select public.admin_set_service_status(%L,'draft','not valid here')$q$, :'hs'), 'err');
select t.run('unknown service', :dave, 'authenticated', $q$select public.admin_set_service_status('00000000-0000-0000-0000-000000000009','inactive','does not exist')$q$, 'err');
select t.run('anon sees the service before', null, 'anon', format($q$select * from public.services where id=%L$q$, :'hs'), '1');
select t.run('admin hides it', :dave, 'authenticated', format($q$select public.admin_set_service_status(%L,'inactive','Misleading photos and price')$q$, :'hs'), 'ok');
select t.run('anon no longer sees it', null, 'anon', format($q$select * from public.services where id=%L$q$, :'hs'), '0');
select t.run('hiding twice is refused', :dave, 'authenticated', format($q$select public.admin_set_service_status(%L,'inactive','already hidden now')$q$, :'hs'), 'err');
select t.run('admin shows it again', :dave, 'authenticated', format($q$select public.admin_set_service_status(%L,'active','Fixed by the provider')$q$, :'hs'), 'ok');
select t.run('anon sees it again', null, 'anon', format($q$select * from public.services where id=%L$q$, :'hs'), '1');
select t.chk('hide and show are logged', (select count(*)=2 from public.admin_audit where target_id=:'hs'::uuid and action in ('service_hidden','service_shown')));

-- remove a review
select id as rv1 from public.reviews order by created_at limit 1 \gset
select t.chk('two reviews before', (select review_count=2 from public.provider_profiles where id=:'carol_prov'));
select t.run('customer cannot remove a review', :alice, 'authenticated', format($q$select public.admin_remove_review(%L,'because I can')$q$, :'rv1'), 'err');
select t.run('reason required to remove a review', :dave, 'authenticated', format($q$select public.admin_remove_review(%L,'')$q$, :'rv1'), 'err');
select t.run('unknown review', :dave, 'authenticated', $q$select public.admin_remove_review('00000000-0000-0000-0000-000000000009','does not exist')$q$, 'err');
select t.run('admin removes it', :dave, 'authenticated', format($q$select public.admin_remove_review(%L,'Abusive language in the comment')$q$, :'rv1'), 'ok');
select t.chk('count and rating recalculated', (select review_count=1 and rating=(select rating::numeric from public.reviews limit 1) from public.provider_profiles where id=:'carol_prov'));
select t.chk('removal logged with the old comment and rating', (select (details ? 'rating') and (details ? 'comment') and reason='Abusive language in the comment' from public.admin_audit where action='review_removed'));
select t.run('removing it again fails', :dave, 'authenticated', format($q$select public.admin_remove_review(%L,'twice is too much')$q$, :'rv1'), 'err');

-- cancel a booking for both sides
select id as ab from public.bookings where customer_address='Bob St 2' \gset
select t.run('customer cannot cancel as admin', :alice, 'authenticated', format($q$select public.admin_cancel_booking(%L,'sneaky attempt')$q$, :'ab'), 'err');
select t.run('reason required to cancel', :dave, 'authenticated', format($q$select public.admin_cancel_booking(%L,'')$q$, :'ab'), 'err');
select t.run('admin cancels a pending booking', :dave, 'authenticated', format($q$select public.admin_cancel_booking(%L,'Provider unreachable, customer asked us')$q$, :'ab'), 'ok');
select t.chk('booking is cancelled', (select status='cancelled' from public.bookings where id=:'ab'));
select t.chk('both sides were emailed', (select count(*)=2 from public.email_outbox where booking_id=:'ab' and kind='booking_cancelled'));
select t.run('cancelling twice is refused', :dave, 'authenticated', format($q$select public.admin_cancel_booking(%L,'cancel again please')$q$, :'ab'), 'err');
select t.run('a finished job cannot be cancelled this way', :dave, 'authenticated', format($q$select public.admin_cancel_booking(%L,'finished job attempt')$q$, :'cb'), 'err');
select t.chk('cancel is logged', (select count(*)=1 from public.admin_audit where action='booking_cancelled' and target_id=:'ab'::uuid));
select t.chk('claim_refund accepts an admin as the asker', (select code from public.claim_refund(:'pay_id', :dave::uuid)) in ('not_cancelled','ok','already','not_paid','disputed','nothing_to_refund'));
select t.run('claim_refund still refuses a stranger', null, 'service_role', format($q$select * from public.claim_refund(%L, %L)$q$, :'pay_id', 'e0000000-0000-0000-0000-000000000005'), 'err');

-- content list
select t.run('admin lists services and reviews', :dave, 'authenticated', $q$select * from public.admin_content()$q$, 'ok');
select t.run('customer cannot list content', :alice, 'authenticated', $q$select * from public.admin_content()$q$, 'err');
select t.run('content list has both kinds', :dave, 'authenticated', $q$select distinct kind from public.admin_content()$q$, '2');

-- FEES, PRO PRICE, SERVICE APPROVAL, PRICE CHANGES (017)
select t.run('anyone can read the public settings', null, 'anon', $q$select * from public.public_settings()$q$, '1');
select t.chk('settings start at 10% / 5% / $19', (select free_fee_percent=10 and pro_fee_percent=5 and pro_price_cents=1900 from public.platform_settings));
select t.run('anon cannot read the settings table', null, 'anon', $q$select * from public.platform_settings$q$, 'err');
select t.run('signed-in user cannot read the settings table', :alice, 'authenticated', $q$select * from public.platform_settings$q$, 'err');
select t.run('signed-in user cannot write the settings table', :carol, 'authenticated', $q$update public.platform_settings set free_fee_percent=0$q$, 'err');
select t.run('customer cannot change fees', :alice, 'authenticated', $q$select public.admin_update_fees(12,6,'I would like less please')$q$, 'err');
select t.run('provider cannot change fees', :carol, 'authenticated', $q$select public.admin_update_fees(0,0,'my own fees to zero')$q$, 'err');
select t.run('fee change needs a reason', :dave, 'authenticated', $q$select public.admin_update_fees(12,6,'')$q$, 'err');
select t.run('fee above 50% refused', :dave, 'authenticated', $q$select public.admin_update_fees(51,5,'too greedy')$q$, 'err');
select t.run('negative fee refused', :dave, 'authenticated', $q$select public.admin_update_fees(-1,5,'negative fee test')$q$, 'err');
select t.run('Pro fee above Free fee refused', :dave, 'authenticated', $q$select public.admin_update_fees(8,9,'pro higher than free')$q$, 'err');
select t.run('same fees refused', :dave, 'authenticated', $q$select public.admin_update_fees(10,5,'nothing changes here')$q$, 'err');
select coalesce(sum(platform_commission),0) as pc_before, count(*) as bk_before from public.bookings \gset
select t.run('admin changes fees to 12% / 6%', :dave, 'authenticated', $q$select public.admin_update_fees(12,6,'Costs went up this quarter')$q$, 'ok');
select t.chk('settings changed', (select free_fee_percent=12 and pro_fee_percent=6 from public.platform_settings));
select t.chk('plan_commission follows the settings', public.plan_commission(false)=12 and public.plan_commission(true)=6);
select t.chk('every provider got the new rate for their plan', (select bool_and(commission_rate = case when is_pro then 6 else 12 end) from public.provider_profiles));
select t.chk('existing bookings keep their fee', (select coalesce(sum(platform_commission),0)=:pc_before and count(*)=:bk_before from public.bookings));
select t.run('alice books after the change', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '9 day','Fee St 1' from public.services where name='Full Detail'$q$, 'ok');
select t.chk('the new booking uses the new fee', (select b.platform_commission = round(b.service_price * pp.commission_rate / 100, 2) and pp.commission_rate in (12,6) from public.bookings b join public.provider_profiles pp on pp.id=b.provider_id where b.customer_address='Fee St 1'));
select t.chk('fee change is logged', (select details->>'free_to'='12.00' and details->>'pro_to'='6.00' and (details->>'providers_updated')::int >= 1 and reason='Costs went up this quarter' from public.admin_audit where action='fees_changed'));

select t.chk('check_admin knows the admin', public.check_admin(:dave::uuid) and not public.check_admin(:alice::uuid));
select t.run('signed-in user cannot call check_admin', :alice, 'authenticated', format($q$select public.check_admin(%L)$q$, 'a0000000-0000-0000-0000-000000000001'), 'err');
select t.run('signed-in user cannot save a Pro price', :dave, 'authenticated', format($q$select public.admin_save_pro_price(%L,2500,'price_abc123','Raise the price a bit')$q$, 'a0000000-0000-0000-0000-000000000001'), 'err');
select t.run('non-admin cannot save a Pro price', null, 'service_role', format($q$select public.admin_save_pro_price(%L,2500,'price_abc123','Raise the price a bit')$q$, 'a0000000-0000-0000-0000-000000000001'), 'err');
select t.run('Pro price below $1 refused', null, 'service_role', format($q$select public.admin_save_pro_price(%L,50,'price_abc123','Raise the price a bit')$q$, :dave), 'err');
select t.run('Pro price above $1,000 refused', null, 'service_role', format($q$select public.admin_save_pro_price(%L,100001,'price_abc123','Raise the price a bit')$q$, :dave), 'err');
select t.run('bad Stripe price id refused', null, 'service_role', format($q$select public.admin_save_pro_price(%L,2500,'prod_nope','Raise the price a bit')$q$, :dave), 'err');
select t.run('Pro price needs a reason', null, 'service_role', format($q$select public.admin_save_pro_price(%L,2500,'price_abc123','')$q$, :dave), 'err');
select t.run('admin saves a new Pro price', null, 'service_role', format($q$select public.admin_save_pro_price(%L,2500,'price_abc123','Raise the price a bit')$q$, :dave), 'ok');
select t.chk('Pro price and Stripe price saved', (select pro_price_cents=2500 and pro_stripe_price_id='price_abc123' from public.platform_settings) and public.platform_pro_price()='price_abc123');
select t.chk('Pro price change is logged', (select (details->>'from_cents')::int=1900 and (details->>'to_cents')::int=2500 and admin_id=:dave::uuid from public.admin_audit where action='pro_price_changed'));
select t.run('public settings show the new price', null, 'anon', $q$select * from public.public_settings() where pro_price_cents=2500$q$, '1');

-- contact messages email the admins
select t.run('a visitor writes to us', null, 'anon', $q$select public.submit_contact('Nadia','nadia.visitor@example.org','general','Hello, I have a question about fees.')$q$, 'ok');
select t.chk('every active admin is emailed about it', (select count(*)=1 and bool_and(o.to_user=:dave::uuid) from public.email_outbox o join public.contact_messages m on m.id=o.contact_id where o.kind='contact_new' and m.email='nadia.visitor@example.org'));

-- the admin owns the service list (migration 024)
select t.run('carol picks Window Tint', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price,status) select id,(select id from public.service_catalog where name='Window Tint'),80,'active' from public.provider_profiles where user_id=auth.uid()$q$, 'ok');
select t.chk('it is live at once (the admin already vetted the list)', (select approval='approved' and name='Window Tint' from public.services where name='Window Tint'));
select t.run('anon sees it', null, 'anon', $q$select * from public.services where name='Window Tint'$q$, '1');
select id as wt_id from public.services where name='Window Tint' \gset
select t.run('price below $1 refused when picking', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price,status) select id,(select id from public.service_catalog where name='Draft'),0.5,'active' from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('admin sees the whole catalog', :dave, 'authenticated', $q$select * from public.admin_catalog_list()$q$, '3');
select t.chk('the list shows how many providers offer each item', (select offered_by=1 from public.admin_catalog_list() where name='Window Tint'));
select t.run('customer cannot open the admin catalog list', :alice, 'authenticated', $q$select * from public.admin_catalog_list()$q$, 'err');
select t.run('provider cannot open the admin catalog list', :carol, 'authenticated', $q$select * from public.admin_catalog_list()$q$, 'err');
select t.run('provider cannot add to the catalog (function)', :carol, 'authenticated', $q$select public.admin_create_catalog_item('Sneaky','x','handyman',10,60)$q$, 'err');
select t.run('provider cannot add to the catalog (table)', :carol, 'authenticated', $q$insert into public.service_catalog(name,category) values ('Sneaky','handyman')$q$, 'err');
select t.run('provider cannot edit the catalog (table)', :carol, 'authenticated', $q$update public.service_catalog set name='Hacked'$q$, 'err');
select t.run('provider cannot delete from the catalog (table)', :carol, 'authenticated', $q$delete from public.service_catalog$q$, 'err');
select t.run('anon cannot add to the catalog', null, 'anon', $q$select public.admin_create_catalog_item('Sneaky','x','handyman',10,60)$q$, 'err');
select t.run('admin adds a catalog item', :dave, 'authenticated', $q$select public.admin_create_catalog_item('Lawn Mowing','Front and back yard','handyman',60,45)$q$, 'ok');
select t.chk('the new item is active and logged', (select is_active and suggested_price=60 and default_duration_minutes=45 from public.service_catalog where name='Lawn Mowing') and exists (select 1 from public.admin_audit where action='catalog_added' and admin_id=:dave::uuid and details->>'name'='Lawn Mowing'));
select t.run('the same name in the same category is refused', :dave, 'authenticated', $q$select public.admin_create_catalog_item('  lawn mowing ','x','handyman',60,45)$q$, 'err');
select t.run('the same name in another category is fine', :dave, 'authenticated', $q$select public.admin_create_catalog_item('Lawn Mowing','x','home_cleaning',60,45)$q$, 'ok');
select t.run('unknown category refused', :dave, 'authenticated', $q$select public.admin_create_catalog_item('Odd','x','plumbing',60,45)$q$, 'err');
select t.run('a too short name is refused', :dave, 'authenticated', $q$select public.admin_create_catalog_item('A','x','handyman',60,45)$q$, 'err');
select t.run('suggested price below $1 refused', :dave, 'authenticated', $q$select public.admin_create_catalog_item('Cheap','x','handyman',0.5,45)$q$, 'err');
select t.run('duration below 15 minutes refused', :dave, 'authenticated', $q$select public.admin_create_catalog_item('Quick','x','handyman',20,5)$q$, 'err');
select t.run('a catalog item without a price is allowed', :dave, 'authenticated', $q$select public.admin_create_catalog_item('Quote Only','Price on request','handyman',null,60)$q$, 'ok');
select t.run('carol can now pick the new item', :carol, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price,status) select id,(select id from public.service_catalog where name='Lawn Mowing' and category='handyman'),55,'active' from public.provider_profiles where user_id=auth.uid()$q$, 'ok');
select t.run('editing needs a reason', :dave, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Window Tint'),'Window Tint Pro','Ceramic film',  'car_detailing',80,90,true,'')$q$, 'err');
select t.run('provider cannot edit through the function', :carol, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Window Tint'),'Window Tint Pro','Ceramic film','car_detailing',80,90,true,'trying it out')$q$, 'err');
select t.run('admin renames a catalog item', :dave, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Window Tint'),'Window Tint Pro','Ceramic film, all windows','car_detailing',80,90,true,'Clearer name for customers')$q$, 'ok');
select t.chk('the rename reaches the provider offering', (select name='Window Tint Pro' and description='Ceramic film, all windows' and approval='approved' and price=80 from public.services where id=:'wt_id'));
select t.chk('the rename is logged with the reason', exists (select 1 from public.admin_audit where action='catalog_updated' and reason='Clearer name for customers' and details->>'was'='Window Tint'));
select t.run('renaming into an existing name is refused', :dave, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Window Tint Pro'),'Full Detail','x','car_detailing',80,90,true,'duplicate try')$q$, 'err');
select t.run('moving an item to another category updates offerings', :dave, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Lawn Mowing' and category='handyman'),'Lawn Mowing','Front and back yard','handyman',60,45,true,'Keep the same category')$q$, 'ok');
select t.run('alice books Window Tint Pro at $80', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '5 day','Hide St 1' from public.services where name='Window Tint Pro'$q$, 'ok');
select t.run('hiding needs a reason', :dave, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Window Tint Pro'),'Window Tint Pro','Ceramic film, all windows','car_detailing',80,90,false,' ')$q$, 'err');
select t.run('admin hides the catalog item', :dave, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Window Tint Pro'),'Window Tint Pro','Ceramic film, all windows','car_detailing',80,90,false,'No longer offered by Wasel')$q$, 'ok');
select t.chk('hiding is logged as catalog_hidden', exists (select 1 from public.admin_audit where action='catalog_hidden' and reason like 'No longer%'));
select t.run('anon no longer sees the offering', null, 'anon', $q$select * from public.services where name='Window Tint Pro'$q$, '0');
select t.run('customers no longer see the offering', :eve, 'authenticated', $q$select * from public.services where name='Window Tint Pro'$q$, '0');
select t.run('but the customer who booked it still sees it', :alice, 'authenticated', $q$select * from public.services where name='Window Tint Pro'$q$, '1');
select t.run('nobody can book it any more', :eve, 'authenticated', format($q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) values (auth.uid(),%L,now()+interval '6 day','Hide St 2')$q$, :'wt_id'), 'err');
select t.chk('the earlier booking is untouched', (select count(*)=1 and bool_and(service_price=80 and status='pending') from public.bookings where customer_address='Hide St 1'));
select t.run('its photos are hidden too', null, 'anon', $q$select * from public.service_photos sp join public.services s on s.id=sp.service_id where s.name='Window Tint Pro'$q$, '0');
select t.run('anon cannot see a hidden catalog item', null, 'anon', $q$select * from public.service_catalog where name='Window Tint Pro'$q$, '0');
select t.run('customers cannot see a hidden catalog item', :alice, 'authenticated', $q$select * from public.service_catalog where name='Window Tint Pro'$q$, '0');
select t.run('provider cannot pick a hidden item', :bob, 'authenticated', $q$insert into public.services(provider_id,catalog_id,price) select id,(select id from public.service_catalog where name='Window Tint Pro'),10 from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('admin shows it again', :dave, 'authenticated', $q$select public.admin_update_catalog_item((select id from public.service_catalog where name='Window Tint Pro'),'Window Tint Pro','Ceramic film, all windows','car_detailing',80,90,true,'Back on the list')$q$, 'ok');
select t.run('anon sees the offering again', null, 'anon', $q$select * from public.services where name='Window Tint Pro'$q$, '1');
select t.chk('showing is logged as catalog_shown', exists (select 1 from public.admin_audit where action='catalog_shown'));
select t.run('an item that providers offer cannot be deleted', :dave, 'authenticated', $q$select public.admin_delete_catalog_item((select id from public.service_catalog where name='Window Tint Pro'),'Cleaning the list')$q$, 'err');
select t.run('an item nobody offers can be deleted', :dave, 'authenticated', $q$select public.admin_delete_catalog_item((select id from public.service_catalog where name='Quote Only'),'Not needed after all')$q$, 'ok');
select t.run('deleting needs a reason', :dave, 'authenticated', $q$select public.admin_delete_catalog_item((select id from public.service_catalog where name='Lawn Mowing' and category='home_cleaning'),'')$q$, 'err');
select t.chk('the audit log keeps the deletion', exists (select 1 from public.admin_audit where action='catalog_deleted' and details->>'name'='Quote Only'));
select t.chk('the old approval workflow is gone', not exists (select 1 from pg_proc where proname in ('admin_service_queue','admin_review_service','admin_request_service_info','resubmit_service','email_on_service_review')));
select t.chk('no service emails are queued any more', (select count(*)=0 from public.email_outbox where kind='service_pending'));
select t.chk('anon can read the active catalog only', (select count(*)>0 from public.service_catalog where is_active));
select t.run('admin content list still works', :dave, 'authenticated', $q$select approval from public.admin_content() where kind='service' and title='Window Tint Pro'$q$, '1');

-- the provider changes the price
select t.run('alice books Window Tint at $80', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '5 day','Tint St 5' from public.services where name='Window Tint Pro'$q$, 'ok');
select t.run('provider changes the price', :carol, 'authenticated', $q$update public.services set price=120 where name='Window Tint Pro'$q$, '1');
select t.chk('a price change needs no approval', (select approval='approved' and price=120 from public.services where name='Window Tint Pro'));
select t.chk('the booking made earlier keeps the old price', (select service_price=80 from public.bookings where customer_address='Tint St 5'));
select t.run('alice books again at the new price', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '6 day','Tint St 6' from public.services where name='Window Tint Pro'$q$, 'ok');
select t.chk('the new booking has the new price and fee', (select service_price=120 and platform_commission=round(120*(select commission_rate from public.provider_profiles where business_name='Carol Detail')/100,2) from public.bookings where customer_address='Tint St 6'));
select t.run('booking with a stale quoted price is refused', :alice, 'authenticated', format($q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address,quoted_price) values (auth.uid(),%L,now()+interval '8 day','Quote St',80)$q$, (select id from public.services where name='Window Tint Pro')), 'err');
select t.chk('no booking was created from it', (select count(*)=0 from public.bookings where customer_address='Quote St'));
select t.run('booking with the current quoted price works', :alice, 'authenticated', format($q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address,quoted_price) values (auth.uid(),%L,now()+interval '8 day','Quote St',120)$q$, (select id from public.services where name='Window Tint Pro')), 'ok');
select t.chk('the quoted price is stored and equals the price charged', (select quoted_price=service_price and service_price=120 from public.bookings where customer_address='Quote St'));
select t.run('price below $1 refused on an edit', :carol, 'authenticated', $q$update public.services set price=0.5 where name='Window Tint Pro'$q$, 'err');
select t.run('price above $100,000 refused on an edit', :carol, 'authenticated', $q$update public.services set price=100001 where name='Window Tint Pro'$q$, 'err');
select t.run('another provider cannot change the price', :bob, 'authenticated', $q$update public.services set price=1 where name='Window Tint Pro'$q$, '0');
select t.run('duration and visibility are free to change', :carol, 'authenticated', $q$update public.services set duration_minutes=45, status='inactive' where name='Window Tint Pro'$q$, '1');
select t.chk('still approved after that', (select approval='approved' from public.services where name='Window Tint Pro'));
select t.run('provider puts it back on', :carol, 'authenticated', $q$update public.services set status='active' where name='Window Tint Pro'$q$, '1');
select t.run('provider cannot touch the approval fields', :carol, 'authenticated', $q$update public.services set approval_note='all good' where name='Window Tint Pro'$q$, 'err');

-- EMAIL LANGUAGE (migration 019)
select t.chk('new accounts start in English', (select lang='en' from public.profiles where id=:alice));
select t.run('anon cannot set a language', null, 'anon', $q$select public.set_my_language('es')$q$, 'err');
select t.run('unsupported language refused', :alice, 'authenticated', $q$select public.set_my_language('fr')$q$, 'err');
select t.run('empty language refused', :alice, 'authenticated', $q$select public.set_my_language(null)$q$, 'err');
select t.run('alice picks Spanish', :alice, 'authenticated', $q$select public.set_my_language('es')$q$, 'ok');
select t.chk('only alice changed', (select (select lang from public.profiles where id=:alice)='es' and (select lang from public.profiles where id=:bob)='en'));
select t.run('profile update cannot touch the language directly', :bob, 'authenticated', $q$update public.profiles set lang='es' where id=auth.uid()$q$, 'err');
select t.run('owner can still update their own name', :bob, 'authenticated', $q$update public.profiles set full_name='Bob' where id=auth.uid()$q$, '1');
select t.chk('bob is still English', (select lang='en' from public.profiles where id=:bob));
select t.run('provider picks Spanish', :carol, 'authenticated', $q$select public.set_my_language('es')$q$, 'ok');
select t.chk('emails are claimed with the language of the person who gets them', (select count(*) filter (where to_lang='es')>0 and count(*) filter (where to_lang='en')>0 and bool_and(to_lang = (select p.lang from public.profiles p join auth.users u on u.id=p.id where u.email=c.to_email)) from public.claim_emails(50) c));
insert into auth.users(id,email,raw_user_meta_data) values ('f0000000-0000-0000-0000-0000000000f1','es-new@x.test','{"lang":"es","full_name":"Ana"}'),('f0000000-0000-0000-0000-0000000000f2','junk-new@x.test','{"lang":"xx"}'),('f0000000-0000-0000-0000-0000000000f3','none-new@x.test','{}');
select t.chk('sign-up in Spanish starts in Spanish', (select lang='es' from public.profiles where id='f0000000-0000-0000-0000-0000000000f1'));
select t.chk('unknown or missing language starts in English', (select count(*)=2 and bool_and(lang='en') from public.profiles where id in ('f0000000-0000-0000-0000-0000000000f2','f0000000-0000-0000-0000-0000000000f3')));

-- STORAGE
select t.run('provider uploads into own folder', :carol, 'authenticated', $q$insert into storage.objects(bucket_id,name) values ('service-photos', auth.uid()::text||'/s1/a.jpg')$q$, 'ok');
select t.run('provider cannot upload into another folder', :carol, 'authenticated', $q$insert into storage.objects(bucket_id,name) values ('service-photos','a0000000-0000-0000-0000-000000000001/s1/a.jpg')$q$, 'err');

-- DOCUMENTS AND "MORE INFORMATION" (migration 020)
select t.run('owner reads own documents', :carol, 'authenticated', $q$select * from public.provider_documents$q$, '2');
select t.run('a customer sees no documents', :alice, 'authenticated', $q$select * from public.provider_documents$q$, '0');
select t.run('another provider sees no documents', :bob, 'authenticated', $q$select * from public.provider_documents$q$, '0');
select t.run('anon cannot read documents', null, 'anon', $q$select * from public.provider_documents$q$, 'err');
select t.run('admin reads all documents', :dave, 'authenticated', $q$select * from public.provider_documents$q$, '2');
select t.run('provider cannot add a document in another user''s folder', :carol, 'authenticated', $q$insert into public.provider_documents(provider_id,kind,storage_path,file_name) select id,'other','a0000000-0000-0000-0000-000000000001/other/x.pdf','x.pdf' from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('provider cannot add a document to another provider', :bob, 'authenticated', $q$insert into public.provider_documents(provider_id,kind,storage_path,file_name) select id,'other',auth.uid()::text||'/other/y.pdf','y.pdf' from public.provider_profiles where business_name='Carol Detail'$q$, 'err');
select t.run('a service document must belong to the uploader''s own service', :bob, 'authenticated', $q$insert into public.provider_documents(provider_id,service_id,kind,storage_path,file_name) select (select id from public.provider_profiles where user_id=auth.uid()),s.id,'service',auth.uid()::text||'/service/z.pdf','z.pdf' from public.services s where s.name='Window Tint Pro'$q$, 'err');
select t.run('kind=service needs a service id', :carol, 'authenticated', $q$insert into public.provider_documents(provider_id,kind,storage_path,file_name) select id,'service',auth.uid()::text||'/service/q.pdf','q.pdf' from public.provider_profiles where user_id=auth.uid()$q$, 'err');
select t.run('provider adds an extra document', :carol, 'authenticated', $q$insert into public.provider_documents(provider_id,kind,storage_path,file_name) select id,'other',auth.uid()::text||'/other/e1.pdf','e1.pdf' from public.provider_profiles where user_id=auth.uid()$q$, 'ok');
select t.run('approved provider cannot remove the ID', :carol, 'authenticated', $q$delete from public.provider_documents where kind='id'$q$, '0');
select t.run('provider can remove an "other" document', :carol, 'authenticated', $q$delete from public.provider_documents where kind='other'$q$, '1');
select t.run('provider cannot rewrite a document row', :carol, 'authenticated', $q$update public.provider_documents set kind='other'$q$, 'err');

select t.run('owner reads own application state', :carol, 'authenticated', $q$select * from public.provider_applications$q$, '1');
select t.run('a customer cannot read applications', :alice, 'authenticated', $q$select * from public.provider_applications$q$, '0');
select t.run('provider cannot change own application state', :bob, 'authenticated', $q$update public.provider_applications set state='approved'$q$, 'err');
select t.run('non-admin cannot review an application', :bob, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where user_id=auth.uid()),'approve',null)$q$, 'err');
update public.provider_profiles set status='pending' where business_name='Bob Wash 2';
update public.provider_applications set state='submitted', note=null where provider_id=(select id from public.provider_profiles where business_name='Bob Wash 2');
select t.run('rejecting needs a reason', :dave, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where business_name='Bob Wash 2'),'reject','')$q$, 'err');
select t.run('asking for more info needs a message', :dave, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where business_name='Bob Wash 2'),'request_info',' ')$q$, 'err');
select t.run('admin asks Bob for more info', :dave, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where business_name='Bob Wash 2'),'request_info','Please upload your ID')$q$, 'ok');
select t.chk('Bob''s application is needs_info with the note, and he is still pending', (select a.state='needs_info' and a.note='Please upload your ID' and p.status='pending' from public.provider_applications a join public.provider_profiles p on p.id=a.provider_id where p.business_name='Bob Wash 2'));
select t.chk('the provider was queued an email for it', exists (select 1 from public.email_outbox o join public.provider_profiles p on p.id=o.provider_id where o.kind='provider_needs_info' and p.business_name='Bob Wash 2'));
select t.run('a provider with nothing to resend is refused', :carol, 'authenticated', $q$select public.resubmit_application()$q$, 'err');
select t.run('Bob sends the application again', :bob, 'authenticated', $q$select public.resubmit_application()$q$, 'ok');
select t.chk('state is back to submitted, note cleared, admins emailed', (select a.state='submitted' and a.note is null from public.provider_applications a join public.provider_profiles p on p.id=a.provider_id where p.business_name='Bob Wash 2') and exists (select 1 from public.email_outbox where kind='provider_new'));
select t.run('an approved provider cannot be reviewed again', :dave, 'authenticated', $q$select public.admin_review_provider((select id from public.provider_profiles where business_name='Carol Detail'),'reject','late')$q$, 'err');

select t.run('the old per-service info request no longer exists', :dave, 'authenticated', $q$select public.admin_request_service_info(gen_random_uuid(),'Add your certificate')$q$, 'err');
select t.run('document bucket: owner uploads into own folder', :carol, 'authenticated', $q$insert into storage.objects(bucket_id,name) values ('provider-docs', auth.uid()::text||'/id/a.pdf')$q$, 'ok');
select t.run('document bucket: nobody uploads into another folder', :carol, 'authenticated', $q$insert into storage.objects(bucket_id,name) values ('provider-docs','a0000000-0000-0000-0000-000000000001/id/a.pdf')$q$, 'err');
select t.run('document bucket: owner reads own file', :carol, 'authenticated', $q$select * from storage.objects where bucket_id='provider-docs'$q$, '1');
select t.run('document bucket: a customer reads nothing', :alice, 'authenticated', $q$select * from storage.objects where bucket_id='provider-docs'$q$, '0');
select t.run('document bucket: anon cannot read', null, 'anon', $q$select * from storage.objects where bucket_id='provider-docs'$q$, 'err');
select t.run('document bucket: admin reads the file', :dave, 'authenticated', $q$select * from storage.objects where bucket_id='provider-docs'$q$, '1');
select t.chk('document bucket is private with a 10 MB limit and PDF/images only', (select not public and file_size_limit=10485760 and 'application/pdf'=any(allowed_mime_types) from storage.buckets where id='provider-docs'));

-- DISTANCE (migration 021)
select t.chk('2.6k Texas ZIP centers are loaded', (select count(*) > 2500 from public.zip_centroids));
select t.run('nobody reads the ZIP table directly (anon)', null, 'anon', $q$select * from public.zip_centroids$q$, 'err');
select t.run('nobody reads the ZIP table directly (user)', :alice, 'authenticated', $q$select * from public.zip_centroids$q$, 'err');
select t.run('anon can ask for distances (and gets only ids + miles)', null, 'anon', $q$select provider_id, miles from public.provider_distances('75201')$q$, 'ok');
select t.chk('distance 75038 -> 75201 is between 5 and 15 miles', (select miles between 5 and 15 from (select private.miles_between(a.lat,a.lng,b.lat,b.lng) as miles from public.zip_centroids a, public.zip_centroids b where a.zip='75038' and b.zip='75201') x));
select t.chk('a city name resolves to a point', (select count(*)=1 from private.place_point('Dallas, TX')));
select t.chk('an unknown place gives no distances', (select count(*)=0 from public.provider_distances('Atlantis')));
select t.chk('only approved providers are listed', not exists (select 1 from public.provider_distances('75201') d join public.provider_profiles p on p.id = d.provider_id where p.status <> 'approved'));
select t.run('anon cannot ask for booking distances', null, 'anon', $q$select * from public.my_booking_distances()$q$, 'err');
select t.run('a customer gets no booking distances (not a provider)', :alice, 'authenticated', $q$select * from public.my_booking_distances()$q$, '0');

-- MUTUAL RATINGS + ALERTS (migration 022)
update public.bookings set confirmed_at = null where id = :'d1';
select t.run('provider cannot rate before the customer confirms', :carol, 'authenticated', format($q$insert into public.customer_reviews(booking_id,rating) values (%L,5)$q$, :'d1'), 'err');
update public.bookings set confirmed_at = now() where id = :'d1';
select t.run('a customer cannot rate (only the provider can)', :alice, 'authenticated', format($q$insert into public.customer_reviews(booking_id,rating) values (%L,5)$q$, :'d1'), 'err');
select t.run('another provider cannot rate someone else''s customer', :bob, 'authenticated', format($q$insert into public.customer_reviews(booking_id,rating) values (%L,5)$q$, :'d1'), 'err');
select t.run('rating 6 is refused', :carol, 'authenticated', format($q$insert into public.customer_reviews(booking_id,rating) values (%L,6)$q$, :'d1'), 'err');
select t.run('provider cannot set provider_id / customer_id themselves', :carol, 'authenticated', format($q$insert into public.customer_reviews(booking_id,provider_id,rating) select %L,id,5 from public.provider_profiles where user_id=auth.uid()$q$, :'d1'), 'err');
select t.run('provider rates the customer once the job is confirmed', :carol, 'authenticated', format($q$insert into public.customer_reviews(booking_id,rating,comment) values (%L,4,'On time, friendly')$q$, :'d1'), 'ok');
select t.run('only one rating per booking', :carol, 'authenticated', format($q$insert into public.customer_reviews(booking_id,rating) values (%L,5)$q$, :'d1'), 'err');
select t.run('nobody edits a customer rating', :carol, 'authenticated', $q$update public.customer_reviews set rating = 1$q$, 'err');
select t.run('nobody deletes a customer rating', :carol, 'authenticated', $q$delete from public.customer_reviews$q$, 'err');
select t.run('the rated customer cannot read the rows (comments are private)', :alice, 'authenticated', $q$select * from public.customer_reviews$q$, '0');
select t.run('another provider cannot read them', :bob, 'authenticated', $q$select * from public.customer_reviews$q$, '0');
select t.run('the author reads own rating', :carol, 'authenticated', $q$select * from public.customer_reviews$q$, '1');
select t.run('admin reads customer ratings', :dave, 'authenticated', $q$select * from public.customer_reviews$q$, '1');
select t.run('anon cannot read customer ratings', null, 'anon', $q$select * from public.customer_reviews$q$, 'err');
select t.run('provider sees the customer''s average (no comments) on the booking', :carol, 'authenticated', format($q$select * from public.customer_ratings_for_my_bookings() where booking_id = %L and avg_rating = 4.0 and review_count = 1$q$, :'d1'), '1');
select t.run('a provider sees nothing for other providers'' bookings', :bob, 'authenticated', $q$select * from public.customer_ratings_for_my_bookings()$q$, '0');
select t.run('the customer sees only their own average', :alice, 'authenticated', $q$select * from public.my_customer_rating() where avg_rating = 4.0 and review_count = 1$q$, '1');
select t.run('a customer nobody rated has a count of 0', :eve, 'authenticated', $q$select * from public.my_customer_rating() where review_count = 0$q$, '1');

-- alerts: default policy does not fire on a couple of reviews
select t.chk('no alert yet with the default policy (5 reviews, below 3.0)', (select count(*)=0 from public.admin_alerts));
select t.chk('default policy is 5 reviews / 3.0', (select alert_min_reviews=5 and alert_max_avg=3.00 from public.platform_settings));
select t.run('a provider cannot read the policy', :carol, 'authenticated', $q$select * from public.admin_rating_policy()$q$, 'err');
select t.run('a provider cannot change the policy', :carol, 'authenticated', $q$select public.admin_update_rating_policy(1,5,'because I want to')$q$, 'err');
select t.run('policy change needs a reason', :dave, 'authenticated', $q$select public.admin_update_rating_policy(1,5,'')$q$, 'err');
select t.run('policy: minimum below 1 is refused', :dave, 'authenticated', $q$select public.admin_update_rating_policy(0,3,'testing the limits')$q$, 'err');
select t.run('policy: average above 5 is refused', :dave, 'authenticated', $q$select public.admin_update_rating_policy(2,6,'testing the limits')$q$, 'err');
select t.run('admin sets the policy to 1 review / below 5.0', :dave, 'authenticated', $q$select public.admin_update_rating_policy(1,5,'test the alert flow')$q$, 'ok');
select t.chk('the policy change is in the activity log', exists (select 1 from public.admin_audit where action='rating_policy_changed'));
insert into public.reviews(booking_id,rating,comment)
select b.id, 2, 'Late and rushed' from public.bookings b where b.status='completed' and not exists (select 1 from public.reviews r where r.booking_id=b.id) order by b.created_at limit 1;
select t.chk('a low average now opens exactly one alert for the provider', (select count(*)=1 and bool_and(status='open') from public.admin_alerts));
select t.chk('the admins were queued an email about it', exists (select 1 from public.email_outbox where kind='rating_alert' and alert_id is not null));
select t.run('a provider cannot read alerts', :carol, 'authenticated', $q$select * from public.admin_alerts_list()$q$, 'err');
select t.run('nobody reads the alerts table directly', :dave, 'authenticated', $q$select * from public.admin_alerts$q$, 'err');
select t.run('admin lists the alert', :dave, 'authenticated', $q$select * from public.admin_alerts_list() where status = 'open'$q$, '1');
select id as al1 from public.admin_alerts where status='open' limit 1 \gset
select t.run('a provider cannot handle an alert', :carol, 'authenticated', format($q$select public.admin_handle_alert(%L,'dismiss','not an admin')$q$, :'al1'), 'err');
select t.run('handling an alert needs a reason', :dave, 'authenticated', format($q$select public.admin_handle_alert(%L,'dismiss',' ')$q$, :'al1'), 'err');
select t.run('admin dismisses the alert with a reason', :dave, 'authenticated', format($q$select public.admin_handle_alert(%L,'dismiss','Two bad reviews, both about a late arrival; talked to the provider')$q$, :'al1'), 'ok');
select t.chk('the alert is handled (dismissed) and the provider is still approved', (select a.status='handled' and a.action='dismissed' and p.status='approved' from public.admin_alerts a join public.provider_profiles p on p.id=a.provider_id));
select t.run('a handled alert cannot be handled again', :dave, 'authenticated', format($q$select public.admin_handle_alert(%L,'suspend','again')$q$, :'al1'), 'err');
select t.chk('the handling is in the activity log with the reason', exists (select 1 from public.admin_audit where action='alert_dismissed' and reason like 'Two bad reviews%'));
insert into public.reviews(booking_id,rating,comment)
select b.id, 1, 'Never showed up' from public.bookings b where b.status='completed' and not exists (select 1 from public.reviews r where r.booking_id=b.id) order by b.created_at limit 1;
select t.chk('another low review opens a NEW alert (the old one was handled)', (select count(*) filter (where status='open')=1 and count(*)=2 from public.admin_alerts));
select id as al2 from public.admin_alerts where status='open' limit 1 \gset
select t.run('admin suspends the provider from the alert', :dave, 'authenticated', format($q$select public.admin_handle_alert(%L,'suspend','Repeated no-shows; suspended until we hear from them')$q$, :'al2'), 'ok');
select t.chk('the provider is suspended and the alert is closed as suspended', (select a.status='handled' and a.action='suspended' and p.status='suspended' from public.admin_alerts a join public.provider_profiles p on p.id=a.provider_id where a.action='suspended'));
select t.chk('suspending is logged', exists (select 1 from public.admin_audit where action='alert_provider_suspended'));

-- SERVICE DAY (migration 023)
update public.provider_profiles set status='approved' where business_name='Carol Detail';
select t.run('alice books SD1', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '3 day','SD1' from public.services where name='Full Detail'$q$, 'ok');
select t.run('alice books SD2', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '3 day','SD2' from public.services where name='Full Detail'$q$, 'ok');
select t.run('alice books SD3', :alice, 'authenticated', $q$insert into public.bookings(customer_id,service_id,scheduled_at,customer_address) select auth.uid(),id,now()+interval '3 day','SD3' from public.services where name='Full Detail'$q$, 'ok');
select id as sd1 from public.bookings where customer_address='SD1' \gset
select id as sd2 from public.bookings where customer_address='SD2' \gset
select id as sd3 from public.bookings where customer_address='SD3' \gset
select t.run('carol confirms SD1', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'sd1'), 'ok');
select t.run('carol confirms SD2', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'sd2'), 'ok');
select t.run('carol confirms SD3', :carol, 'authenticated', format($q$select public.transition_booking(%L,'confirmed')$q$, :'sd3'), 'ok');
-- messages are closed until 1 hour before the start
select t.run('messages are closed more than 1 h before the start (customer)', :alice, 'authenticated', format($q$select public.send_booking_message(%L,'hello')$q$, :'sd1'), 'err');
select t.run('messages are closed more than 1 h before the start (provider)', :carol, 'authenticated', format($q$select public.send_booking_message(%L,'hello')$q$, :'sd1'), 'err');
update public.bookings set scheduled_at = now() + interval '40 minutes' where id = :'sd1';
select t.run('customer writes within the last hour', :alice, 'authenticated', format($q$select public.send_booking_message(%L,'Gate code is 1234')$q$, :'sd1'), 'ok');
select t.run('provider answers', :carol, 'authenticated', format($q$select public.send_booking_message(%L,'On my way soon')$q$, :'sd1'), 'ok');
select t.run('a stranger cannot write', :eve, 'authenticated', format($q$select public.send_booking_message(%L,'hi')$q$, :'sd1'), 'err');
select t.run('another provider cannot write', :bob, 'authenticated', format($q$select public.send_booking_message(%L,'hi')$q$, :'sd1'), 'err');
select t.run('an empty message is refused', :alice, 'authenticated', format($q$select public.send_booking_message(%L,'   ')$q$, :'sd1'), 'err');
select t.run('a message over 1000 characters is refused', :alice, 'authenticated', format($q$select public.send_booking_message(%L,repeat('x',1001))$q$, :'sd1'), 'err');
select t.run('anon cannot write', null, 'anon', format($q$select public.send_booking_message(%L,'hi')$q$, :'sd1'), 'err');
select t.run('nobody inserts a message directly', :alice, 'authenticated', format($q$insert into public.booking_messages(booking_id,sender_id,body) values (%L,auth.uid(),'x')$q$, :'sd1'), 'err');
select t.run('customer reads the 2 messages', :alice, 'authenticated', format($q$select * from public.booking_messages where booking_id=%L$q$, :'sd1'), '2');
select t.run('provider reads the 2 messages', :carol, 'authenticated', format($q$select * from public.booking_messages where booking_id=%L$q$, :'sd1'), '2');
select t.run('admin reads the messages', :dave, 'authenticated', format($q$select * from public.booking_messages where booking_id=%L$q$, :'sd1'), '2');
select t.run('a stranger reads none', :eve, 'authenticated', format($q$select * from public.booking_messages where booking_id=%L$q$, :'sd1'), '0');
select t.run('nobody edits a message', :alice, 'authenticated', $q$update public.booking_messages set body='changed'$q$, 'err');
select t.run('nobody deletes a message', :alice, 'authenticated', $q$delete from public.booking_messages$q$, 'err');
-- no cancelling in the last hour
update public.bookings set scheduled_at = now() + interval '30 minutes' where id = :'sd2';
select t.run('customer cannot cancel in the last hour', :alice, 'authenticated', format($q$select public.transition_booking(%L,'cancelled')$q$, :'sd2'), 'err');
select t.run('provider cannot cancel in the last hour', :carol, 'authenticated', format($q$select public.transition_booking(%L,'cancelled')$q$, :'sd2'), 'err');
select t.run('only an admin cancels in the last hour', :dave, 'authenticated', format($q$select public.admin_cancel_booking(%L,'Customer called support')$q$, :'sd2'), 'ok');
select t.chk('the booking is cancelled', (select status='cancelled' from public.bookings where id=:'sd2'));
select t.chk('cancelling is still allowed with more than 1 hour left', (select count(*)=1 from public.bookings where customer_address='SD3' and status='confirmed'));
-- start flow
select t.run('provider starts the work', :carol, 'authenticated', format($q$select public.transition_booking(%L,'in_progress')$q$, :'sd1'), 'ok');
select t.chk('started_at is stamped by the database', (select started_at is not null and arrived_at is null from public.bookings where id=:'sd1'));
select t.run('cannot finish before arriving', :carol, 'authenticated', format($q$select public.transition_booking(%L,'completed')$q$, :'sd1'), 'err');
select t.run('the customer cannot mark arrival', :alice, 'authenticated', format($q$select public.mark_arrived(%L)$q$, :'sd1'), 'err');
select t.run('another provider cannot mark arrival', :bob, 'authenticated', format($q$select public.mark_arrived(%L)$q$, :'sd1'), 'err');
select t.run('no work photo before arriving', :carol, 'authenticated', format($q$insert into public.booking_work_photos(booking_id,storage_path) values (%L, 'c0000000-0000-0000-0000-000000000003/'||%L||'/a.jpg')$q$, :'sd1', :'sd1'), 'err');
select t.run('provider marks arrival', :carol, 'authenticated', format($q$select public.mark_arrived(%L)$q$, :'sd1'), 'ok');
select t.chk('arrived_at is stamped', (select arrived_at is not null from public.bookings where id=:'sd1'));
select t.run('arrival cannot be marked for a booking that is not started', :carol, 'authenticated', format($q$select public.mark_arrived(%L)$q$, :'sd3'), 'err');
select t.run('cannot finish without a photo of the work', :carol, 'authenticated', format($q$select public.transition_booking(%L,'completed')$q$, :'sd1'), 'err');
select t.run('the customer cannot add work photos', :alice, 'authenticated', format($q$insert into public.booking_work_photos(booking_id,storage_path) values (%L, 'a0000000-0000-0000-0000-000000000001/'||%L||'/a.jpg')$q$, :'sd1', :'sd1'), 'err');
select t.run('photo path must be in the provider folder and the booking folder', :carol, 'authenticated', format($q$insert into public.booking_work_photos(booking_id,storage_path) values (%L, 'c0000000-0000-0000-0000-000000000003/other/a.jpg')$q$, :'sd1'), 'err');
select t.run('provider adds a work photo', :carol, 'authenticated', format($q$insert into public.booking_work_photos(booking_id,storage_path) values (%L, 'c0000000-0000-0000-0000-000000000003/'||%L||'/a.jpg')$q$, :'sd1', :'sd1'), 'ok');
select t.run('work photo files: provider uploads into own folder', :carol, 'authenticated', format($q$insert into storage.objects(bucket_id,name) values ('work-photos','c0000000-0000-0000-0000-000000000003/'||%L||'/a.jpg')$q$, :'sd1'), 'ok');
select t.run('work photo files: nobody uploads into another folder', :alice, 'authenticated', format($q$insert into storage.objects(bucket_id,name) values ('work-photos','c0000000-0000-0000-0000-000000000003/'||%L||'/b.jpg')$q$, :'sd1'), 'err');
select t.run('work photo files: the customer of the booking can read', :alice, 'authenticated', $q$select * from storage.objects where bucket_id='work-photos'$q$, '1');
select t.run('work photo files: a stranger reads none', :eve, 'authenticated', $q$select * from storage.objects where bucket_id='work-photos'$q$, '0');
select t.run('work photo files: anon cannot read', null, 'anon', $q$select * from storage.objects where bucket_id='work-photos'$q$, 'err');
select t.run('work photo files: admin can read', :dave, 'authenticated', $q$select * from storage.objects where bucket_id='work-photos'$q$, '1');
select t.chk('work photo bucket is private, images only, 10 MB', (select not public and file_size_limit=10485760 and not ('application/pdf'=any(allowed_mime_types)) from storage.buckets where id='work-photos'));
select t.run('the customer reads the work photo rows', :alice, 'authenticated', format($q$select * from public.booking_work_photos where booking_id=%L$q$, :'sd1'), '1');
select t.run('a stranger reads no work photo rows', :eve, 'authenticated', $q$select * from public.booking_work_photos$q$, '0');
select t.run('provider finishes with arrival + photo', :carol, 'authenticated', format($q$select public.transition_booking(%L,'completed')$q$, :'sd1'), 'ok');
select t.run('no more photos after finishing', :carol, 'authenticated', format($q$insert into public.booking_work_photos(booking_id,storage_path) values (%L, 'c0000000-0000-0000-0000-000000000003/'||%L||'/z.jpg')$q$, :'sd1', :'sd1'), 'err');
select t.run('messages close once the job is finished', :alice, 'authenticated', format($q$select public.send_booking_message(%L,'thanks')$q$, :'sd1'), 'err');
-- the 1 hour email
update public.bookings set scheduled_at = now() + interval '30 minutes' where id = :'sd3';
select public.queue_start_reminders();
select t.chk('customer gets one starting-soon email', (select count(*)=1 from public.email_outbox where booking_id=:'sd3' and kind='booking_starting_soon' and to_user='a0000000-0000-0000-0000-000000000001'));
select public.queue_start_reminders();
select t.chk('only one email per booking', (select count(*)=1 from public.email_outbox where booking_id=:'sd3' and kind='booking_starting_soon'));
select t.chk('no email for a cancelled booking', (select count(*)=0 from public.email_outbox where booking_id=:'sd2' and kind='booking_starting_soon'));
select t.chk('no email when the start is more than 1 hour away', (select count(*)=0 from public.email_outbox where booking_id=:'d2' and kind='booking_starting_soon'));
select t.chk('claim_emails returns the starting-soon email', (select count(*)>=1 from public.claim_emails(50) where kind='booking_starting_soon'));

select label, case when ok then 'PASS' else 'FAIL' end as result, case when ok then '' else detail end as detail
from t.results order by n;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;

do $$ begin
  if exists (select 1 from t.results where not ok) then
    raise exception 'SECURITY TESTS FAILED (see FAIL rows above)';
  end if;
end $$;

rollback;
