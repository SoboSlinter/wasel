-- 026: small security hardening (advisor notes)
alter function private.audit_no_change() set search_path = '';
alter function private.need_reason(text) set search_path = '';
alter function private.check_catalog_fields(text, text, text, numeric, integer) set search_path = '';
-- trigger-only function: nobody needs to call it through the API
revoke execute on function public.limit_service_photos() from public, anon, authenticated;
