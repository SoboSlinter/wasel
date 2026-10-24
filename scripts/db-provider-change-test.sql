-- Tests for 028_provider_change_requests.sql (profile changes need admin approval).
-- Run on a FRESH database that already has schema.sql: psql -v ON_ERROR_STOP=0 -f scripts/db-provider-change-test.sql
-- The last result must show: failed = 0
\set ON_ERROR_STOP off
create schema if not exists t;
grant usage on schema t to anon, authenticated;
create table if not exists t.res(name text, ok boolean, detail text);
create table if not exists t.code(c jsonb);
grant all on t.code, t.res to public;
truncate t.code;
truncate t.res;
-- run sql as role/user; expect error (pattern) or success
create or replace function t.run(p_name text, p_sub uuid, p_role text, p_sql text, p_expect_err text default null) returns void language plpgsql as $$
declare msg text; ok boolean;
begin
  perform set_config('request.jwt.claims', case when p_sub is null then '' else json_build_object('sub', p_sub)::text end, true);
  execute 'set local role ' || p_role;
  begin
    execute p_sql;
    msg := 'no error'; ok := p_expect_err is null;
  exception when others then
    msg := SQLERRM; ok := p_expect_err is not null and msg ilike '%'||p_expect_err||'%';
  end;
  execute 'reset role';
  insert into t.res values (p_name, ok, msg);
end $$;
grant execute on function t.run(text,uuid,text,text,text) to public;


-- S = main admin, R = reviewer (providers), U = support (no providers), P = approved provider, Q = pending provider, O = other approved provider
insert into auth.users(id,email,raw_user_meta_data) values
 ('b1000000-0000-0000-0000-000000000001','super@x.com','{}'),('b2000000-0000-0000-0000-000000000002','rev@x.com','{}'),
 ('b3000000-0000-0000-0000-000000000003','sup@x.com','{}'),('b4000000-0000-0000-0000-000000000004','p@x.com','{}'),
 ('b5000000-0000-0000-0000-000000000005','q@x.com','{}'),('b6000000-0000-0000-0000-000000000006','o@x.com','{}');
update public.profiles set role='admin', is_super_admin=true where id='b1000000-0000-0000-0000-000000000001';
update public.profiles set role='admin', admin_permissions=array['providers'] where id='b2000000-0000-0000-0000-000000000002';
update public.profiles set role='admin', admin_permissions=array['messages','users'] where id='b3000000-0000-0000-0000-000000000003';
update public.profiles set role='provider' where id in ('b4000000-0000-0000-0000-000000000004','b5000000-0000-0000-0000-000000000005','b6000000-0000-0000-0000-000000000006');
insert into public.provider_profiles(user_id,business_name,status,phone,city) values
 ('b4000000-0000-0000-0000-000000000004','P Cleaning','approved','(972) 555-0001','Irving'),
 ('b5000000-0000-0000-0000-000000000005','Q Repairs','pending','(972) 555-0002','Dallas'),
 ('b6000000-0000-0000-0000-000000000006','O Handy','approved','(972) 555-0003','Plano');

insert into public.provider_private(provider_id) select id from public.provider_profiles on conflict do nothing;

-- direct edits: blocked for approved, still fine for pending
select t.run('approved provider cannot edit directly','b4000000-0000-0000-0000-000000000004','authenticated',$q$update public.provider_profiles set phone='(972) 555-9999' where user_id='b4000000-0000-0000-0000-000000000004'$q$);
select 'approved provider direct edit changed nothing' as name, (select phone='(972) 555-0001' from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004') as ok;
select t.run('pending provider still edits directly','b5000000-0000-0000-0000-000000000005','authenticated',$q$update public.provider_profiles set phone='(972) 555-7777' where user_id='b5000000-0000-0000-0000-000000000005'$q$);
select 'pending provider direct edit saved' as name, (select phone='(972) 555-7777' from public.provider_profiles where user_id='b5000000-0000-0000-0000-000000000005') as ok;
select t.run('approved provider cannot edit private license info directly','b4000000-0000-0000-0000-000000000004','authenticated',$q$update public.provider_private set license_info='x' where provider_id=(select id from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004')$q$);
select 'license info unchanged' as name, (select coalesce(license_info,'') <> 'x' from public.provider_private where provider_id=(select id from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004')) as ok;

-- submitting
select t.run('pending provider uses direct edit, not a request','b5000000-0000-0000-0000-000000000005','authenticated',$q$select public.submit_provider_change('{"phone":"(972) 555-1111"}')$q$,'still being reviewed');
select t.run('customer/no provider cannot submit','b3000000-0000-0000-0000-000000000003','authenticated',$q$select public.submit_provider_change('{"phone":"(972) 555-1111"}')$q$,'no provider account');
select t.run('empty change refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{}')$q$,'Nothing to change');
select t.run('unknown field refused (status)','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"status":"approved"}')$q$,'cannot change');
select t.run('unknown field refused (commission)','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"commission_rate":0}')$q$,'cannot change');
select t.run('bad phone refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"phone":"abc"}')$q$,'valid phone');
select t.run('bad email refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"email":"nope"}')$q$,'valid email');
select t.run('bad website refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"website":"javascript:alert(1)"}')$q$,'https://');
select t.run('empty business name refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"business_name":"  "}')$q$,'cannot be empty');
select t.run('too many categories refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"categories":["a","b","c","d","e","f","g","h","i"]}')$q$,'Too many');
select t.run('years out of range refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"years_experience":99}')$q$,'between 0 and 60');
select t.run('someone elses document cannot be attached','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"phone":"(972) 555-1111"}','x','{c0000000-0000-0000-0000-00000000000f}')$q$,'could not be attached');
select 'failed submit left no request' as name, (select count(*) = 0 from public.provider_change_requests) as ok;

-- a supporting document, then the real request
insert into public.provider_documents(provider_id,kind,storage_path,file_name,size_bytes) values
 ((select id from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004'),'other','b4/other/aaaa-doc.pdf','doc.pdf',1000);
insert into public.provider_documents(provider_id,kind,storage_path,file_name,size_bytes) values
 ((select id from public.provider_profiles where user_id='b6000000-0000-0000-0000-000000000006'),'other','b6/other/bbbb-doc.pdf','other.pdf',1000);
select t.run('provider submits a change with a document','b4000000-0000-0000-0000-000000000004','authenticated',
  $q$select public.submit_provider_change('{"phone":"(972) 555-2222","city":"Irving","business_name":"P Cleaning LLC","categories":["home_cleaning","handyman"],"years_experience":7,"license_info":"TX-123"}','New LLC registered', array[(select id from public.provider_documents where storage_path='b4/other/aaaa-doc.pdf')])$q$);
select 'request is pending and linked to the document' as name,
  (select count(*) = 1 from public.provider_change_requests where status='pending') and (select count(*) = 1 from public.provider_documents where request_id is not null) as ok;
select 'profile is NOT changed yet' as name, (select phone='(972) 555-0001' and business_name='P Cleaning' from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004') as ok;
select t.run('second pending request refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"phone":"(972) 555-3333"}')$q$,'already have a change');
select t.run('other provider cannot attach this request document','b6000000-0000-0000-0000-000000000006','authenticated',
  $q$select public.submit_provider_change('{"phone":"(972) 555-4444"}',null,array[(select id from public.provider_documents where storage_path='b4/other/aaaa-doc.pdf')])$q$,'could not be attached');
select t.run('provider reads own request','b4000000-0000-0000-0000-000000000004','authenticated',$q$select 1/ (select count(*) from public.provider_change_requests)::int$q$);
select t.run('other provider sees no requests','b6000000-0000-0000-0000-000000000006','authenticated',$q$select 1/ (select count(*) from public.provider_change_requests)::int$q$,'division by zero');
select t.run('provider cannot write requests directly','b4000000-0000-0000-0000-000000000004','authenticated',$q$update public.provider_change_requests set status='approved'$q$,'permission denied');
select t.run('provider cannot approve','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.admin_review_change((select id from public.provider_change_requests limit 1),'approve')$q$,'Not allowed');
select t.run('support admin (no providers permission) cannot list','b3000000-0000-0000-0000-000000000003','authenticated',$q$select * from public.admin_change_requests('pending')$q$,'Not allowed');
select t.run('support admin cannot approve','b3000000-0000-0000-0000-000000000003','authenticated',$q$select public.admin_review_change((select id from public.provider_change_requests limit 1),'approve')$q$,'Not allowed');
select t.run('reviewer lists requests','b2000000-0000-0000-0000-000000000002','authenticated',$q$select 1/ (select count(*) from public.admin_change_requests('pending'))::int$q$);
select 'list shows current values and the document' as name,
  (select c.current ->> 'phone' = '(972) 555-0001' and jsonb_array_length(c.docs) = 1 and c.changes ->> 'phone' = '(972) 555-2222'
     from (select * from public.admin_change_requests('pending')) c limit 1) as ok
  from (select set_config('request.jwt.claims', json_build_object('sub','b2000000-0000-0000-0000-000000000002')::text, true)) z;
select t.run('reject needs a reason','b2000000-0000-0000-0000-000000000002','authenticated',$q$select public.admin_review_change((select id from public.provider_change_requests where status='pending' limit 1),'reject')$q$,'reason');

-- provider takes it back, sends another, admin rejects, then approves a third
select t.run('provider cancels','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.cancel_provider_change((select id from public.provider_change_requests where status='pending' limit 1))$q$);
select t.run('cancel twice refused','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.cancel_provider_change((select id from public.provider_change_requests where status='cancelled' limit 1))$q$,'no longer waiting');
select t.run('other provider cannot cancel mine','b6000000-0000-0000-0000-000000000006','authenticated',$q$select public.cancel_provider_change((select id from public.provider_change_requests limit 1))$q$,'no longer waiting');
select t.run('new request after cancel','b4000000-0000-0000-0000-000000000004','authenticated',$q$select public.submit_provider_change('{"phone":"(972) 555-5555"}')$q$);
select t.run('reviewer rejects with reason','b2000000-0000-0000-0000-000000000002','authenticated',$q$select public.admin_review_change((select id from public.provider_change_requests where status='pending' limit 1),'reject','Phone number looks wrong')$q$);
select 'rejected: stored note, profile unchanged' as name, (select count(*)=1 from public.provider_change_requests where status='rejected' and admin_note='Phone number looks wrong') and (select phone='(972) 555-0001' from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004') as ok;
select t.run('review twice refused','b2000000-0000-0000-0000-000000000002','authenticated',$q$select public.admin_review_change((select id from public.provider_change_requests where status='rejected' limit 1),'approve')$q$,'no longer waiting');
select t.run('provider sends the full change again','b4000000-0000-0000-0000-000000000004','authenticated',
  $q$select public.submit_provider_change('{"phone":"(972) 555-2222","business_name":"P Cleaning LLC","categories":["home_cleaning","handyman"],"years_experience":7,"license_info":"TX-123","description":"We clean homes."}')$q$);
select t.run('reviewer approves','b2000000-0000-0000-0000-000000000002','authenticated',$q$select public.admin_review_change((select id from public.provider_change_requests where status='pending' limit 1),'approve','Documents checked')$q$);
select 'approved: public profile changed' as name,
  (select phone='(972) 555-2222' and business_name='P Cleaning LLC' and categories=array['home_cleaning','handyman'] and years_experience=7 and description='We clean homes.' and city='Irving' and status='approved' from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004') as ok;
select 'approved: private license info changed' as name, (select license_info='TX-123' from public.provider_private where provider_id=(select id from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004')) as ok;
select 'approved: status/commission untouched' as name, (select status='approved' and commission_rate is not null from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004') as ok;
select 'audit trail written' as name, (select count(*) = 2 from public.admin_audit where action in ('provider_change_approved','provider_change_rejected')) as ok;
select t.run('an admin has no provider account to change','b1000000-0000-0000-0000-000000000001','authenticated',$q$select public.submit_provider_change('{"phone":"x"}')$q$,'no provider account');
select t.run('admin can still edit provider directly via the admin function','b1000000-0000-0000-0000-000000000001','authenticated',$q$select public.admin_update_provider((select id from public.provider_profiles where user_id='b4000000-0000-0000-0000-000000000004'),'P Cleaning LLC','d','(972) 555-2222','p@x.com','https://x.com','Fixing a typo')$q$);

select name, ok, left(detail,60) detail from t.res where not ok;
select count(*) filter (where ok) passed, count(*) filter (where not ok) failed from t.res;
