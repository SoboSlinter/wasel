-- Tests for 027_permissions_contacts_data.sql (permissions by role, contact details, backup / import).
-- Run on a FRESH database that already has schema.sql: psql -v ON_ERROR_STOP=0 -f scripts/db-admin-test.sql
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

-- users: S = main admin, M = manager (legacy, permissions not configured), U = support (only messages/users), C = customer
insert into auth.users(id,email,raw_user_meta_data) values
 ('a1000000-0000-0000-0000-000000000001','super@x.com','{"full_name":"Sam Super"}'),
 ('a2000000-0000-0000-0000-000000000002','mgr@x.com','{"full_name":"Mia Manager"}'),
 ('a3000000-0000-0000-0000-000000000003','cust@x.com','{"full_name":"Cy Customer"}'),
 ('a4000000-0000-0000-0000-000000000004','sup@x.com','{"full_name":"Sue Support"}');
update public.profiles set role='admin', is_super_admin=true where id='a1000000-0000-0000-0000-000000000001';
update public.profiles set role='admin' where id in ('a2000000-0000-0000-0000-000000000002','a4000000-0000-0000-0000-000000000004');
insert into public.provider_profiles(user_id,business_name,status) values ('a3000000-0000-0000-0000-000000000003','Cy Co','approved');

select 'legacy admin keeps manager set' as name, (select private.perm_preset('manager') = (select permissions from (select (public.my_admin_access()).permissions) x)) as ok
  from (select set_config('request.jwt.claims', json_build_object('sub','a2000000-0000-0000-0000-000000000002')::text, true)) z;
select t.run('main admin sets Support permissions','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_permissions('a4000000-0000-0000-0000-000000000004','Support',array['messages','users'],'Support desk only')$q$);
select t.run('manager cannot set permissions','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_permissions('a4000000-0000-0000-0000-000000000004','X',array['data'],'try to widen')$q$, 'main admin');
select t.run('cannot give an unknown permission','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_permissions('a4000000-0000-0000-0000-000000000004','X',array['root'],'bad permission')$q$, 'Unknown');
select t.run('cannot change the main admin','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_permissions('a1000000-0000-0000-0000-000000000001','X',array['users'],'try on main admin')$q$, 'main admin always');
select t.run('reason required','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_permissions('a4000000-0000-0000-0000-000000000004','X',array['users'],'')$q$, 'reason');
select t.run('support lists users','a4000000-0000-0000-0000-000000000004','authenticated', $q$select * from public.admin_users_overview()$q$);
select t.run('support reads messages','a4000000-0000-0000-0000-000000000004','authenticated', $q$select * from public.admin_contact_messages('new')$q$);
select t.run('support cannot see providers extras','a4000000-0000-0000-0000-000000000004','authenticated', $q$select * from public.admin_provider_extras()$q$, 'Not allowed');
select t.run('support cannot read the audit log','a4000000-0000-0000-0000-000000000004','authenticated', $q$select * from public.admin_audit_log(10)$q$, 'Not allowed');
select t.run('support cannot change fees','a4000000-0000-0000-0000-000000000004','authenticated', $q$select public.admin_update_fees(10,5,'no right to do this')$q$, 'Not allowed');
select t.run('support has no disputes permission','a4000000-0000-0000-0000-000000000004','authenticated', $q$select 1 / (case when private.has_perm('disputes') then 0 else 1 end)$q$);
select t.run('support cannot export data','a4000000-0000-0000-0000-000000000004','authenticated', $q$select public.admin_export_data('catalog')$q$, 'data permission');
select t.run('manager cannot export data (not granted)','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_export_data('catalog')$q$, 'data permission');
select t.run('manager still reviews alerts','a2000000-0000-0000-0000-000000000002','authenticated', $q$select * from public.admin_alerts_list()$q$);
select t.run('main admin grants data to manager','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_permissions('a2000000-0000-0000-0000-000000000002','Manager',array['catalog','data','settings'],'Needs backups')$q$);
select t.run('manager with data exports catalog','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_export_data('catalog','backup')$q$);
select t.run('manager lost users access','a2000000-0000-0000-0000-000000000002','authenticated', $q$select * from public.admin_users_overview()$q$, 'Admins only');
select t.run('unknown dataset refused','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_export_data('secrets')$q$, 'Unknown dataset');

-- contact details
select t.run('main admin adds an email','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_save_site_contact(null,'email','Support','help@wasel.test',1,true,'First contact detail')$q$);
select t.run('main admin adds a phone','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_save_site_contact(null,'phone','Phone','(972) 555-0100',2,true,'Phone line')$q$);
select t.run('bad email refused','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_save_site_contact(null,'email','X','nope',3,true,'bad email test')$q$, 'valid email');
select t.run('bad link refused','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_save_site_contact(null,'website','X','javascript:alert(1)',3,true,'bad link test')$q$, 'https');
select t.run('manager cannot add contact','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_save_site_contact(null,'email','X','x@y.com',3,true,'not allowed')$q$, 'main admin');
select t.run('main admin edits it','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_save_site_contact((select id from public.site_contacts where kind='email'),'email','Support team','help@wasel.test',1,true,'Rename label')$q$);
select t.run('main admin adds a hidden one','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_save_site_contact(null,'other','Internal','call before 5pm',9,false,'Private note')$q$);
set local role anon;
select 'anon reads 2 public contact rows' as name, (select count(*) = 2 from public.site_contacts) as ok;
select t.run('anon cannot write contacts',null,'anon', $q$insert into public.site_contacts(kind,label,value) values ('email','x','x@y.com')$q$, 'permission denied');
reset role;
select t.run('customer cannot write contacts','a3000000-0000-0000-0000-000000000003','authenticated', $q$insert into public.site_contacts(kind,label,value) values ('email','x','x@y.com')$q$, 'permission denied');
select t.run('main admin deletes one','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_delete_site_contact((select id from public.site_contacts where kind='other'),'No longer needed')$q$);
select 'two contacts left' as name, (select count(*) = 2 from public.site_contacts) as ok;

-- import
select t.run('import catalog adds + updates','a2000000-0000-0000-0000-000000000002','authenticated',
  $q$select public.admin_import_data('catalog', '[{"name":"Gutter cleaning","category":"home_cleaning","suggested_price":80,"default_duration_minutes":60},{"name":"Window tint","category":"car_detailing","suggested_price":120,"default_duration_minutes":90}]'::jsonb,'Restore after mistake')$q$);
select 'catalog has 2 rows' as name, (select count(*) = 2 from public.service_catalog) as ok;
select t.run('import again updates, not duplicates','a2000000-0000-0000-0000-000000000002','authenticated',
  $q$select public.admin_import_data('catalog', '[{"name":"gutter cleaning","category":"home_cleaning","suggested_price":90}]'::jsonb,'Price correction')$q$);
select 'still 2 rows, price updated' as name, (select count(*) = 2 and bool_or(suggested_price = 90) from public.service_catalog) as ok;
select t.run('bad row rolls everything back','a2000000-0000-0000-0000-000000000002','authenticated',
  $q$select public.admin_import_data('catalog', '[{"name":"Fine one","category":"handyman"},{"name":"X","category":"bogus"}]'::jsonb,'Broken file test')$q$, 'violates');
select 'nothing from the broken file was saved' as name, (select count(*) = 2 from public.service_catalog) as ok;
select t.run('cannot import users','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_import_data('users','[{"a":1}]'::jsonb,'not importable')$q$, 'cannot be imported');
select t.run('import needs a reason','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_import_data('catalog','[{"name":"Zed","category":"handyman"}]'::jsonb,'')$q$, 'reason');
select t.run('support cannot import','a4000000-0000-0000-0000-000000000004','authenticated', $q$select public.admin_import_data('catalog','[{"name":"Zed","category":"handyman"}]'::jsonb,'not allowed here')$q$, 'data permission');
select t.run('manager cannot import contacts','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_import_data('contacts','[{"kind":"email","label":"Z","value":"z@y.com"}]'::jsonb,'not allowed here')$q$, 'main admin');
select t.run('main admin imports settings','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_import_data('settings','[{"free_fee_percent":12,"pro_fee_percent":6}]'::jsonb,'Restore fees')$q$);
select 'fees restored' as name, (select free_fee_percent = 12 and pro_fee_percent = 6 from public.platform_settings) as ok;

-- invites with a title and permissions
select t.run('main admin creates a Reviewer invite','a1000000-0000-0000-0000-000000000001','authenticated', $q$insert into t.code select public.admin_create_invite('Reviewer test', 7, 'Reviewer', null)$q$);
select 'invite stores the reviewer set' as name, (select permissions = private.perm_preset('reviewer') and title = 'Reviewer' from public.admin_invites order by created_at desc limit 1) as ok;
insert into auth.users(id,email,raw_user_meta_data)
  select 'b2000000-0000-0000-0000-000000000002','rev@x.com', jsonb_build_object('full_name','Rae Reviewer','admin_invite', c->>'code') from t.code;
select 'invited admin gets the reviewer set' as name,
  (select role='admin' and admin_title='Reviewer' and admin_permissions = private.perm_preset('reviewer') from public.profiles where id='b2000000-0000-0000-0000-000000000002') as ok;
select t.run('reviewer opens provider extras','b2000000-0000-0000-0000-000000000002','authenticated', $q$select * from public.admin_provider_extras()$q$);
select t.run('reviewer cannot read messages','b2000000-0000-0000-0000-000000000002','authenticated', $q$select * from public.admin_contact_messages('new')$q$, 'Not allowed');
-- promote through the role function => starts with Support
select t.run('main admin promotes a customer','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_user_role('a3000000-0000-0000-0000-000000000003','admin')$q$);
select 'promoted user starts with Support' as name, (select admin_permissions = private.perm_preset('support') from public.profiles where id='a3000000-0000-0000-0000-000000000003') as ok;
select t.run('main admin demotes again','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_user_role('a3000000-0000-0000-0000-000000000003','customer')$q$);
select 'demoted user loses permissions' as name, (select admin_permissions is null and admin_title is null from public.profiles where id='a3000000-0000-0000-0000-000000000003') as ok;
select t.run('client cannot write permissions','a4000000-0000-0000-0000-000000000004','authenticated', $q$update public.profiles set admin_permissions = array['data'] where id='a4000000-0000-0000-0000-000000000004'$q$, 'permission denied');
select 'edge function check follows settings permission' as name,
  public.check_admin('a1000000-0000-0000-0000-000000000001') and public.check_admin('a2000000-0000-0000-0000-000000000002') and not public.check_admin('a4000000-0000-0000-0000-000000000004') as ok;
select 'audit trail written' as name, (select count(*) >= 9 from public.admin_audit where action in ('admin_permissions','contact_added','contact_updated','contact_deleted','data_backup','data_import')) as ok;

-- final report
select name, ok, left(detail,60) detail from t.res where not ok;
select count(*) filter (where ok) passed, count(*) filter (where not ok) failed from t.res;
