# Payments (Stripe) and email (Resend) — setup

Do this on the TEST project first (wasel-staging), with Stripe **test mode** keys. Nothing here goes in the front-end files.

## 1. Accounts
- Stripe: https://dashboard.stripe.com (switch on **Test mode**).
- Resend: https://resend.com. For real emails, add and verify your domain (DNS records). Without a domain you can only send to your own address.

## 2. Stripe
1. Developers → API keys → copy the **Secret key** (`sk_test_...`) → `STRIPE_SECRET_KEY`.
2. Settings → Connect → turn on Connect with **Express** accounts (providers get paid through it).
3. Products → add "Wasel Pro" with a monthly recurring price → copy the price id (`price_...`) → `STRIPE_PRO_PRICE_ID`.
   (Optional: the admin can also set the Pro price in the Admin → Settings tab.)
4. After the functions are deployed (step 4), Developers → Webhooks → add **two** endpoints, both to
   `https://sprzndrttiefncgbpvte.supabase.co/functions/v1/stripe-webhook`:
   - Endpoint A (Your account): events `charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`,
     `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`
     → signing secret `whsec_...` → `STRIPE_WEBHOOK_SECRET`.
   - Endpoint B (**Connected accounts**): event `account.updated` → signing secret → `STRIPE_CONNECT_WEBHOOK_SECRET`.

## 3. Resend
API Keys → create a key (`re_...`) → `RESEND_API_KEY`. Pick the sender → `EMAIL_FROM` (for example `Wasel <bookings@your-domain.com>`).

## 4. Secrets and functions (Supabase CLI, run in this project folder)
```
npx supabase login
npx supabase link --project-ref sprzndrttiefncgbpvte
npx supabase secrets set STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_... STRIPE_CONNECT_WEBHOOK_SECRET=whsec_... STRIPE_PRO_PRICE_ID=price_... RESEND_API_KEY=re_... EMAIL_FROM="Wasel <bookings@your-domain.com>" EMAIL_CRON_SECRET=<a long random string> SITE_URL=https://<your-site>
npx supabase functions deploy
```
`stripe-webhook` must not require a login (already set in `config.toml`: `verify_jwt = false`). The webhook endpoints in step 2.4 need the functions to exist first, so deploy, then add the webhooks, then set the two `whsec_` secrets and run the `secrets set` line again.

## 5. Scheduled jobs (emails and payouts)
Call these every few minutes / hourly with the header `x-cron-secret: <EMAIL_CRON_SECRET>` (Supabase Dashboard → Integrations → Cron, or any scheduler):
- `POST https://sprzndrttiefncgbpvte.supabase.co/functions/v1/send-emails`
- `POST https://sprzndrttiefncgbpvte.supabase.co/functions/v1/release-due-payouts`

## 6. Test it
1. Provider: Dashboard → connect payouts (Stripe test onboarding).
2. Customer: book a service → pay with card `4242 4242 4242 4242`, any future date, any CVC.
3. Check: booking becomes paid; an email arrives (or appears in the Resend log); refund from Admin → Bookings refunds in Stripe.
4. Before going live: repeat with live keys, a verified domain and the real site address in `SITE_URL`.
