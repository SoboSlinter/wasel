-- =========================================================
-- WASEL MVP — Let customers keep seeing what they booked
-- Run AFTER 001 and 002.
--
-- Problem: a customer can only see ACTIVE services of APPROVED providers.
-- If a provider later deactivates a service (or is suspended), the customer's
-- booking history would lose the service name and provider.
-- Fix: customers may also see the service/provider of their own bookings.
--
-- The checks live in small SECURITY DEFINER functions so the policies do not
-- loop back through each other (Postgres would report "infinite recursion").
-- =========================================================

create or replace function private.is_my_booked_service(p_service_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bookings b
    where b.service_id = p_service_id
      and b.customer_id = (select auth.uid())
  );
$$;

create or replace function private.is_my_booked_provider(p_provider_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bookings b
    where b.provider_id = p_provider_id
      and b.customer_id = (select auth.uid())
  );
$$;

revoke execute on function private.is_my_booked_service(uuid)  from public;
revoke execute on function private.is_my_booked_provider(uuid) from public;
grant  execute on function private.is_my_booked_service(uuid)  to authenticated;
grant  execute on function private.is_my_booked_provider(uuid) to authenticated;

create policy "Customers can view services they booked"
on public.services for select to authenticated
using ((select private.is_my_booked_service(id)));

create policy "Customers can view providers they booked"
on public.provider_profiles for select to authenticated
using ((select private.is_my_booked_provider(id)));
