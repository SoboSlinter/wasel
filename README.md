# Wasel

Plain HTML, CSS and JavaScript (ES modules). No build step. This project holds the **front end and the back end** (database rules and server functions on Supabase).

## Run it

```
npm install        # only needed for the tiny "serve" helper
npm start          # serves this folder at http://localhost:3000
```

Or serve the folder with any static host. Open `index.html`.

## Connect the front end to the back end

`js/config.js` holds two values:

- `SUPABASE_URL`: your project URL
- `SUPABASE_KEY`: the **publishable** (anon) key. Never put a `service_role` or secret key in this folder.

The key is public by design. Data protection is the job of the database rules (RLS), not of this folder.

## What is here

| Path | What it is |
|---|---|
| `index.html`, `services.html`, `service.html`, `bookings.html` | Customer pages: home, search, service details and booking, my bookings |
| `login.html`, `signup.html`, `forgot.html`, `reset.html` | Customer sign-in and password recovery |
| `provider-signup.html`, `provider-login.html`, `provider.html` | Providers: one sign-up and application form (5 steps), log in, dashboard |
| `admin-login.html`, `admin.html` | Admin sign-in and dashboard |
| `about.html`, `contact.html`, `terms.html`, `privacy.html` | Information pages |
| `css/style.css`, `css/fonts/` | Styles (light and dark) and the Inter font, served locally |
| `img/` | Logo and hero image |
| `js/` | One module per page, plus shared helpers |
| `supabase/migrations/` | The database, in order (001 to 025). `supabase/schema.sql` is the same thing in one file |
| `supabase/functions/` | Server functions: payments, payouts, refunds, emails (need Stripe and Resend keys) |
| `supabase/seed.sql`, `supabase/sample-data-hosted.sql` | Sample data for local and hosted tests |
| `scripts/` | `db-security-test.sql` (755 checks), `db-admin-test.sql` (main admin and invites), `db-permissions-test.sql` (42 checks: admin roles, contact details, backup/import), `db-provider-change-test.sql` (36 checks: provider profile change requests), helpers for the local database |

Shared helpers in `js/`: `app.js` (Supabase client, header and footer, `esc()`, messages, categories), `areas.js` (service-area editor),
`docs.js` (document upload queue), `provider-form.js` (the merged provider sign-up form), `i18n.js` and `i18n-es.js` (English and Spanish).

## Provider form

`js/provider-form.js` is the single provider form. Signed-out visitors see 5 steps (account, business, contact and areas, documents, trust and finish).
A signed-in person sees 4 steps (no account step). If the back end requires email confirmation, the form keeps the typed answers in the browser
(`wasel-provider-draft`, 7 days, never the password or files) and asks for the documents after the first login.

## Rules for editing

- Put any text that came from the database into the page only through `esc()` in `js/app.js`. This prevents XSS.
- Keep secrets out of this folder.
- Spanish: add new visible text to `js/i18n-es.js` (exact text in the dictionary, or a pattern for text with numbers).
- Dark mode and the layout use the CSS variables at the top of `css/style.css`.

## Publish

Upload the folder to any static host over HTTPS. Do not upload a `.env` file or `node_modules/`. After the first deploy, add the site address
to the back end's allowed redirect addresses, or email confirmation links will not return to the site.

## Look (Pastel Glass)
`css/glass.css` is the pastel-glass skin. It applies only in light mode (`<html class="glass-light">`, set by the small script in each page head and by the theme button); dark mode keeps the look from `css/style.css`. To go back to the old look, delete the `glass.css` link from the pages.

## Admins (main admin, invite codes)
- The **main admin** (one person) can: create one-time invite codes (Admins tab), see and edit every user's name/phone, edit provider details, change roles (including admins) and deactivate anyone. Regular admins keep the day-to-day tools but cannot touch admins or edit user data.
- A new admin opens **Admin log in → "I have an invite code"**, fills the form with the code and confirms their email. No valid code, no account.
- The database rules for this are in `supabase/migrations/025_super_admin_invites.sql` (already applied to `wasel-staging`). Make yourself the main admin once with the SQL at the bottom of that file.

## Back end (Supabase)
- New database: run `supabase/schema.sql` once in the SQL Editor (or the migrations in order). Existing database: run only the newest migration(s).
- Local test: `npm run db:start`, `npm run env:local`, then `npm run db:test`. Server functions and their secrets: see `supabase/functions/.env.example`. Never put secrets in the front-end files.
- Rule: every change to the database is a new numbered file in `supabase/migrations/`, and is also added to the end of `supabase/schema.sql`.
