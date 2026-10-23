# Wasel — launch checklist

Front end and back end (`supabase/`).

## 0. Before anything
- [ ] Have a lawyer review `terms.html` and `privacy.html`. Fill in the business name, address, contact email, refund and dispute wording.
- [ ] Decide the final site name and domain.

## 1. Back end
- [ ] Database: `supabase/schema.sql` (or migrations 001 to 025) applied to the project. Run `scripts/db-security-test.sql` and `scripts/db-admin-test.sql` on a fresh copy first.
- [ ] Make yourself the main admin (SQL at the end of `025_super_admin_invites.sql`), then invite other admins from the Admins tab.
- [ ] Server functions deployed and their keys set (Stripe, Resend): follow `supabase/SETUP_PAYMENTS_EMAIL.md`. Payments and emails do not work without them.
- [ ] Auth: email confirmation on, leaked-password protection on, Site URL and redirect URLs set.

## 2. Connect
- [ ] `js/config.js`: project URL and **publishable** key of the right back-end project (test first, live later).
  **Verify:** `grep -rn service_role .` returns nothing, and the services page loads without console errors.

## 3. Host
- [ ] Upload the folder to a static host (Netlify, Cloudflare Pages, Vercel...) over HTTPS.
- [ ] Do not upload `.env` files or `node_modules/`.
  **Verify:** every page loads; `<site>/js/config.js` contains no secret key.

## 4. Back end must allow the site
- [ ] Add the site address as Site URL and as a redirect URL (`<site>/**`) in the back end's auth settings.
  **Verify:** sign up with a real address, click the email link, and land back on the site signed in.

## 5. Click-through test (two browser profiles)
| # | Do | Verify |
|---|----|--------|
| 1 | Provider applies on `provider-signup.html` (5 steps; documents step may come after first login) | Shows "waiting for approval" |
| 2 | Admin approves the provider | Provider sees the dashboard |
| 3 | Provider picks services from the admin's list and sets price | Service appears on `services.html`; search by ZIP works |
| 4 | Customer books | Provider sees the request |
| 5 | Switch the language button to Español | Pages and forms are translated |
| 6 | Dark mode toggle | Text stays readable on every page |
| 7 | Phone width (about 400 px) | No sideways scrolling |
| 8 | Main admin creates an invite code; a second person joins from Admin log in | New admin can log in; the code cannot be used twice |

## Known gaps
- The site was tested against a local test database; the staging database has the schema but no real users, payments or emails yet.
- Terms and Privacy are drafts, not legal advice.
