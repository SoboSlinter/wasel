-- Tests for 025_super_admin_invites.sql (main admin, invite codes, user edits).
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

-- users (the trigger creates the profiles as customers)
insert into auth.users(id,email,raw_user_meta_data) values
 ('a1000000-0000-0000-0000-000000000001','super@x.com','{"full_name":"Sam Super"}'),
 ('a2000000-0000-0000-0000-000000000002','admin@x.com','{"full_name":"Ada Admin"}'),
 ('a3000000-0000-0000-0000-000000000003','cust@x.com','{"full_name":"Cy Customer"}'),
 ('a4000000-0000-0000-0000-000000000004','prov@x.com','{"full_name":"Pat Provider"}');
update public.profiles set role='admin', is_super_admin=true where id='a1000000-0000-0000-0000-000000000001';
update public.profiles set role='admin' where id='a2000000-0000-0000-0000-000000000002';
update public.profiles set role='provider' where id='a4000000-0000-0000-0000-000000000004';
insert into public.provider_profiles(user_id,business_name,status) values ('a4000000-0000-0000-0000-000000000004','Pat Cleaning','approved');

-- second super admin must be refused (unique)
select t.run('only one main admin', null, 'postgres', $q$update public.profiles set role='admin', is_super_admin=true where id='a2000000-0000-0000-0000-000000000002'$q$, 'profiles_one_super_admin');
-- direct writes from clients
select t.run('client cannot set is_super_admin', 'a3000000-0000-0000-0000-000000000003','authenticated', $q$update public.profiles set is_super_admin=true where id='a3000000-0000-0000-0000-000000000003'$q$, 'permission denied');
select t.run('client cannot set own role', 'a3000000-0000-0000-0000-000000000003','authenticated', $q$update public.profiles set role='admin' where id='a3000000-0000-0000-0000-000000000003'$q$, 'permission denied');
select t.run('client cannot read invites table', 'a2000000-0000-0000-0000-000000000002','authenticated', $q$select * from public.admin_invites$q$, 'permission denied');
-- invites
select t.run('customer cannot create invite','a3000000-0000-0000-0000-000000000003','authenticated', $q$select public.admin_create_invite('x',7)$q$, 'main admin');
select t.run('regular admin cannot create invite','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_create_invite('x',7)$q$, 'main admin');
select t.run('anon cannot create invite',null,'anon', $q$select public.admin_create_invite('x',7)$q$, 'permission denied');
select t.run('days out of range','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_create_invite('x',99)$q$, 'between 1 and 30');
select t.run('super creates invite','a1000000-0000-0000-0000-000000000001','authenticated', $q$insert into t.code select public.admin_create_invite('for Noor',7)$q$);
select name, ok from t.res where not ok;
-- code works once
create or replace function t.code_txt() returns text language sql as $$ select c->>'code' from t.code limit 1 $$;
select 'anon sees code valid' as name, public.check_admin_invite(t.code_txt()) as ok;
select 'wrong code invalid', not public.check_admin_invite('WASEL-AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD');
select t.run('anon check works', null, 'anon', 'select public.check_admin_invite(''x'')');
-- sign-up with wrong code: account must NOT be created
select t.run('bad code blocks signup', null, 'postgres',
  $q$insert into auth.users(id,email,raw_user_meta_data) values ('b1000000-0000-0000-0000-000000000001','evil@x.com','{"full_name":"Evil","admin_invite":"WASEL-00000000-00000000-00000000-00000000"}')$q$, 'invalid_admin_invite');
select 'no evil user row' as name, not exists(select 1 from auth.users where email='evil@x.com') or false as ok;
-- sign-up with the real code (lower case / spaces tolerated)
insert into auth.users(id,email,raw_user_meta_data)
 select 'b2000000-0000-0000-0000-000000000002','noor@x.com', jsonb_build_object('full_name','Noor New','admin_invite', ' '||lower(t.code_txt())||' ');
select 'invited user is admin' as name, (select role='admin' and not is_super_admin from public.profiles where id='b2000000-0000-0000-0000-000000000002') as ok;
select 'invite marked used' as name, (select status='used' and used_by_name='Noor New' from (select * from (select i.id, case when used_at is not null then 'used' end status, (select full_name from public.profiles where id=i.used_by) used_by_name from public.admin_invites i) q) z limit 1) as ok;
select t.run('code is single use', null, 'postgres',
  format($q$insert into auth.users(id,email,raw_user_meta_data) values ('b3000000-0000-0000-0000-000000000003','again@x.com', jsonb_build_object('admin_invite', %L))$q$, t.code_txt()), 'invalid_admin_invite');
select 'check says used code invalid' as name, not public.check_admin_invite(t.code_txt()) as ok;
-- expiry + revoke
truncate t.code;
select t.run('make 2nd invite','a1000000-0000-0000-0000-000000000001','authenticated', $q$insert into t.code select public.admin_create_invite('exp',1)$q$);
update public.admin_invites set expires_at = now() - interval '1 minute' where note='exp';
select 'expired code invalid' as name, not public.check_admin_invite(t.code_txt()) as ok;
truncate t.code;
select t.run('make 3rd invite','a1000000-0000-0000-0000-000000000001','authenticated', $q$insert into t.code select public.admin_create_invite('rev',3)$q$);
create table if not exists t.ids(k text, id uuid); grant all on t.ids to public; delete from t.ids; insert into t.ids select 'rev', id from public.admin_invites where note='rev';
select t.run('regular admin cannot list invites','a2000000-0000-0000-0000-000000000002','authenticated', 'select * from public.admin_list_invites()', 'main admin');
select t.run('super lists invites','a1000000-0000-0000-0000-000000000001','authenticated', 'select * from public.admin_list_invites()');
select t.run('super revokes','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_revoke_invite((select id from t.ids where k='rev'))$q$);
select 'revoked code invalid' as name, not public.check_admin_invite(t.code_txt()) as ok;
select t.run('revoke twice fails','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_revoke_invite((select id from t.ids where k='rev'))$q$, 'already used');
-- roles
select t.run('admin cannot promote to admin','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_user_role('a3000000-0000-0000-0000-000000000003','admin')$q$, 'main admin');
select t.run('admin cannot demote admin','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_user_role('b2000000-0000-0000-0000-000000000002','customer')$q$, 'main admin');
select t.run('admin can make customer a provider','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_user_role('a3000000-0000-0000-0000-000000000003','provider')$q$);
select t.run('nobody changes the main admin','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_user_role('a1000000-0000-0000-0000-000000000001','customer')$q$, 'main admin cannot');
select t.run('super cannot change self','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_user_role('a1000000-0000-0000-0000-000000000001','customer')$q$, 'own role');
select t.run('super demotes an admin','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_user_role('b2000000-0000-0000-0000-000000000002','customer')$q$);
select t.run('super promotes user to admin','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_user_role('b2000000-0000-0000-0000-000000000002','admin')$q$);
-- deactivate
select t.run('admin cannot deactivate admin','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_user_active('b2000000-0000-0000-0000-000000000002', false, 'testing reason')$q$, 'main admin');
select t.run('nobody deactivates main admin','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_user_active('a1000000-0000-0000-0000-000000000001', false, 'testing reason')$q$, 'main admin cannot');
select t.run('super deactivates admin','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_set_user_active('b2000000-0000-0000-0000-000000000002', false, 'testing reason')$q$);
select 'deactivated admin loses admin powers' as name, not exists(select 1 from public.profiles where id='b2000000-0000-0000-0000-000000000002' and is_active) as ok;
select t.run('deactivated admin blocked','b2000000-0000-0000-0000-000000000002','authenticated', 'select * from public.admin_users_overview(5)', 'Admins only');
select t.run('admin deactivates provider','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_set_user_active('a4000000-0000-0000-0000-000000000004', false, 'testing reason')$q$);
select 'provider suspended with account' as name, (select status::text='suspended' from public.provider_profiles where user_id='a4000000-0000-0000-0000-000000000004') as ok;
-- overview
select t.run('customer cannot list users','a3000000-0000-0000-0000-000000000003','authenticated', 'select * from public.admin_users_overview()', 'Admins only');
select t.run('admin lists users','a2000000-0000-0000-0000-000000000002','authenticated', 'select * from public.admin_users_overview()');
select 'overview has email + provider' as name, exists(select 1 from public.admin_users_overview() o where o.email='prov@x.com' and o.business_name='Pat Cleaning') as ok;
-- edits
select t.run('admin cannot edit user','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_update_user('a3000000-0000-0000-0000-000000000003','Cy Changed','555','fix typo please')$q$, 'main admin');
select t.run('super edits user','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_update_user('a3000000-0000-0000-0000-000000000003','Cy Changed','555-1234','fix typo please')$q$);
select 'user edited' as name, (select full_name='Cy Changed' and phone='555-1234' from public.profiles where id='a3000000-0000-0000-0000-000000000003') as ok;
select t.run('edit needs reason','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_update_user('a3000000-0000-0000-0000-000000000003','X','1','')$q$, 'reason');
select t.run('edit needs name','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_update_user('a3000000-0000-0000-0000-000000000003','  ','1','valid reason')$q$, 'Name is required');
select t.run('admin cannot edit provider','a2000000-0000-0000-0000-000000000002','authenticated', $q$select public.admin_update_provider((select id from public.provider_profiles limit 1),'Z','d','1','e@x.com','w','valid reason')$q$, 'main admin');
select t.run('super edits provider','a1000000-0000-0000-0000-000000000001','authenticated', $q$select public.admin_update_provider((select id from public.provider_profiles limit 1),'Pat Cleaning Co','About us','555-9','pat@x.com','https://pat.example','valid reason')$q$);
select 'provider edited' as name, (select business_name='Pat Cleaning Co' and phone='555-9' from public.provider_profiles limit 1) as ok;
-- audit
select 'audit trail written' as name, (select count(*) >= 8 from public.admin_audit where action in ('admin_invite_created','admin_invite_used','admin_invite_revoked','user_role','user_deactivated','user_edited','provider_edited')) as ok;
-- final report
select name, ok, left(detail,60) detail from t.res where not ok;
select count(*) filter (where ok) passed, count(*) filter (where not ok) failed from t.res;
