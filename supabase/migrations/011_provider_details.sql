-- =========================================================
-- WASEL MVP — Richer provider sign-up
-- New PUBLIC fields on the provider page: business type, categories, years of experience, languages, website.
-- New PRIVATE fields (owner + admins only): license / insurance info, how they found us, when they accepted the terms.
-- register_provider now REQUIRES: business type, at least one category, a phone number and accepting the terms.
-- Run AFTER 010.
-- =========================================================

alter table public.provider_profiles
  add column if not exists business_type    text check (business_type in ('individual', 'company')),
  add column if not exists categories       text[] check (cardinality(categories) between 1 and 10),
  add column if not exists years_experience smallint check (years_experience between 0 and 60),
  add column if not exists languages        text[] check (cardinality(languages) <= 8),
  add column if not exists website          text check (website ~ '^https?://[^[:space:]]{3,190}$' and length(website) <= 200);

-- private details: NOT readable by the public (provider_profiles is public, so these live in their own table)
create table if not exists public.provider_private (
  provider_id       uuid primary key references public.provider_profiles(id) on delete cascade,
  license_info      text check (length(license_info) <= 300),
  referral_source   text check (referral_source in ('friend', 'social', 'search', 'flyer', 'other')),
  terms_accepted_at timestamptz,
  terms_version     text
);
alter table public.provider_private enable row level security;
revoke all on public.provider_private from public, anon, authenticated;
grant select on public.provider_private to authenticated;
grant update (license_info) on public.provider_private to authenticated;

create policy "Owner reads own private details" on public.provider_private for select to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));
create policy "Admins read private details" on public.provider_private for select to authenticated
using ((select private.is_admin()));
create policy "Owner edits own license info" on public.provider_private for update to authenticated
using (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())))
with check (exists (select 1 from public.provider_profiles p where p.id = provider_id and p.user_id = (select auth.uid())));

-- providers may edit the new public fields later (never the private audit fields)
grant update (business_type, categories, years_experience, languages, website) on public.provider_profiles to authenticated;

-- replace the old register_provider (it allowed missing phone / terms)
drop function if exists public.register_provider(text, text, text, text, text, text, text, text);

create or replace function public.register_provider(
  p_business_name    text,
  p_business_type    text,
  p_categories       text[],
  p_phone            text,
  p_accept_terms     boolean,
  p_description      text default null,
  p_email            text default null,
  p_address          text default null,
  p_city             text default null,
  p_state            text default 'TX',
  p_zip_code         text default null,
  p_years_experience int  default null,
  p_license_info     text default null,
  p_languages        text[] default null,
  p_website          text default null,
  p_referral_source  text default null
)
returns public.provider_profiles
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  row public.provider_profiles;
  cats text[];
  langs text[];
  digits text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_business_name is null or btrim(p_business_name) = '' then raise exception 'Business name is required'; end if;
  if length(btrim(p_business_name)) > 120 then raise exception 'Business name is too long'; end if;
  if p_accept_terms is distinct from true then raise exception 'You must accept the Terms and Privacy Policy'; end if;
  if p_business_type is null or p_business_type not in ('individual', 'company') then
    raise exception 'Choose whether you are an individual or a company';
  end if;

  select coalesce(array_agg(distinct c order by c), '{}') into cats from unnest(coalesce(p_categories, '{}')) c;
  if cardinality(cats) = 0 then raise exception 'Choose at least one category'; end if;
  if exists (select 1 from unnest(cats) c where c not in ('car_detailing', 'home_cleaning', 'handyman', 'computer_repair')) then
    raise exception 'Unknown category';
  end if;

  digits := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  if length(digits) < 10 or length(digits) > 11 or (length(digits) = 11 and left(digits, 1) <> '1') then
    raise exception 'Enter a valid US phone number';
  end if;

  if p_years_experience is not null and (p_years_experience < 0 or p_years_experience > 60) then
    raise exception 'Years of experience must be between 0 and 60';
  end if;
  if p_description is not null and length(p_description) > 1000 then raise exception 'The description is too long (1000 characters max)'; end if;
  if p_website is not null and btrim(p_website) <> '' and btrim(p_website) !~ '^https?://[^[:space:]]{3,190}$' then
    raise exception 'The website must start with http:// or https://';
  end if;
  if p_license_info is not null and length(p_license_info) > 300 then raise exception 'License / insurance info is too long (300 characters max)'; end if;
  if p_referral_source is not null and p_referral_source not in ('friend', 'social', 'search', 'flyer', 'other') then
    raise exception 'Unknown option for how you heard about us';
  end if;

  select array_agg(l order by l) into langs from (
    select distinct left(btrim(x), 30) as l from unnest(coalesce(p_languages, '{}')) x where btrim(x) <> '' limit 8) s;

  insert into public.provider_profiles
    (user_id, business_name, description, phone, email, address, city, state, zip_code,
     business_type, categories, years_experience, languages, website)
  values
    (uid, btrim(p_business_name), nullif(btrim(p_description), ''), btrim(p_phone), nullif(btrim(p_email), ''),
     nullif(btrim(p_address), ''), nullif(btrim(p_city), ''), nullif(upper(btrim(p_state)), ''), nullif(btrim(p_zip_code), ''),
     p_business_type, cats, p_years_experience::smallint, langs, nullif(btrim(p_website), ''))
  returning * into row;

  insert into public.provider_private (provider_id, license_info, referral_source, terms_accepted_at, terms_version)
  values (row.id, nullif(btrim(p_license_info), ''), p_referral_source, now(), '2026-10');

  update public.profiles set role = 'provider' where id = uid and role = 'customer'; -- never downgrade an admin
  return row;
end $$;

revoke all on function public.register_provider(text, text, text[], text, boolean, text, text, text, text, text, text, int, text, text[], text, text) from public, anon, authenticated;
grant execute on function public.register_provider(text, text, text[], text, boolean, text, text, text, text, text, text, int, text, text[], text, text) to authenticated;
