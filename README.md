# Wasel

Find trusted local services in Texas: car detailing, home cleaning, handyman and computer repair.
A static website (HTML, CSS, JavaScript modules) on top of Supabase (database, login, storage, Edge Functions).

## Run it on your computer

You need [Node.js](https://nodejs.org). In this folder:

```bash
npx serve .
```

Open the address it prints (usually http://localhost:3000). Do not open the HTML files by double-clicking:
JavaScript modules only work through a web server.

The Supabase project and its publishable key are in `js/config.js`.

## Demo data (test project only)

`supabase/seed/demo.sql` adds 3 approved providers (Austin, Houston, Dallas) and 8 services, so search and
booking can be tried right away. `supabase/seed/demo-remove.sql` removes them. Run them in the Supabase SQL editor.

To make yourself an admin, sign up on the site, then run in the SQL editor:

```sql
update public.profiles set role = 'admin'
where id = (select id from auth.users where email = 'you@example.com');
```

## Edge Functions

Code in `supabase/functions/`. Payments (`create-checkout`) and emails (`send-emails`) are called by the site but
their code is not in this repository yet.

- `ai-chat`: the "Ask Wasel" help chat, answered through an [OmniRoute](https://github.com/diegosouzapw/OmniRoute)
  gateway. Set the secrets `OMNIROUTE_URL`, `OMNIROUTE_API_KEY` and optionally `OMNIROUTE_MODEL`, then
  `supabase functions deploy ai-chat --no-verify-jwt`.

## Third-party code

`js/vendor/supabase.js` is the browser build of `@supabase/supabase-js` 2.117.3 (MIT License).
