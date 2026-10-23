-- 015: "Contact us" messages. Anyone may send one (through a function that checks and rate-limits it);
-- only admins can read them. Nothing here is readable or writable by table access.

create table if not exists public.contact_messages (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete set null,
  name        text not null check (char_length(name) between 1 and 80),
  email       text not null check (char_length(email) between 5 and 200),
  topic       text not null check (topic in ('general','booking','payment','provider','account','privacy','other')),
  message     text not null check (char_length(message) between 10 and 2000),
  status      text not null default 'new' check (status in ('new','handled')),
  created_at  timestamptz not null default now(),
  handled_at  timestamptz
);
create index if not exists contact_messages_status_idx on public.contact_messages (status, created_at desc);
create index if not exists contact_messages_email_idx on public.contact_messages (lower(email), created_at desc);
alter table public.contact_messages enable row level security;           -- no policies: no direct access
revoke all on public.contact_messages from public, anon, authenticated;

create or replace function public.submit_contact(p_name text, p_email text, p_topic text, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_msg text := btrim(coalesce(p_message, ''));
  v_uid uuid := (select auth.uid());
begin
  if char_length(v_name) < 1 or char_length(v_name) > 80 then raise exception 'Please enter your name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 200 then raise exception 'Please enter a valid email address.'; end if;
  if coalesce(p_topic, '') not in ('general','booking','payment','provider','account','privacy','other') then raise exception 'Please choose a topic.'; end if;
  if char_length(v_msg) < 10 then raise exception 'Please write at least 10 characters.'; end if;
  if char_length(v_msg) > 2000 then raise exception 'Please keep your message under 2000 characters.'; end if;
  -- simple brakes against spam: per sender and overall
  if (select count(*) from public.contact_messages where lower(email) = v_email and created_at > now() - interval '1 hour') >= 5
     or (v_uid is not null and (select count(*) from public.contact_messages where user_id = v_uid and created_at > now() - interval '1 hour') >= 5) then
    raise exception 'You have sent several messages already. Please wait a while before sending another.';
  end if;
  if (select count(*) from public.contact_messages where created_at > now() - interval '1 hour') >= 200 then
    raise exception 'We are receiving a lot of messages right now. Please try again later.';
  end if;
  insert into public.contact_messages(user_id, name, email, topic, message) values (v_uid, v_name, v_email, p_topic, v_msg);
end $$;

create or replace function public.admin_contact_messages(p_status text default 'new')
returns table (id uuid, name text, email text, topic text, message text, status text, created_at timestamptz, is_member boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query
    select m.id, m.name, m.email, m.topic, m.message, m.status, m.created_at, (m.user_id is not null)
    from public.contact_messages m
    where p_status = 'all' or m.status = p_status
    order by m.created_at desc
    limit 200;
end $$;

create or replace function public.admin_contact_handled(p_id uuid, p_handled boolean default true)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  update public.contact_messages set status = case when p_handled then 'handled' else 'new' end,
         handled_at = case when p_handled then now() else null end
  where id = p_id;
  if not found then raise exception 'Message not found'; end if;
end $$;

revoke all on function public.submit_contact(text, text, text, text)        from public;
revoke all on function public.admin_contact_messages(text)                  from public, anon;
revoke all on function public.admin_contact_handled(uuid, boolean)          from public, anon;
grant execute on function public.submit_contact(text, text, text, text)     to anon, authenticated;
grant execute on function public.admin_contact_messages(text)               to authenticated;
grant execute on function public.admin_contact_handled(uuid, boolean)       to authenticated;
