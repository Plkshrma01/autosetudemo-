# AutoSetu — Your Local Ride, Connected

A vanilla HTML/CSS/JavaScript ride and carpool web application for local auto-rickshaw and taxi connections. It uses Supabase Auth, PostgreSQL, RLS and database RPCs. It is designed for GitHub Pages and does not require Node.js.

## Important status and production limitations

This package contains a working frontend and a database implementation for the core authenticated flows, but **it is not yet a fully audited commercial ride-hailing system**. External configuration and end-to-end testing are required before real customers use it.

- Account creation uses Supabase email/password authentication and email confirmation. No phone number is required. Supabase default email sending may be rate-limited; for a public launch, configure custom SMTP in Supabase.
- GPS requires user permission and HTTPS (GitHub Pages provides HTTPS).
- The current booking UI requires pickup GPS coordinates. Destination coordinates and route drawing are not implemented in this MVP.
- The driver dashboard requires admin approval. Driver acceptance is atomic via a database update.
- Arrival checks a fresh driver GPS position when the driver presses ARRIVED. While the driver dashboard remains open and online, foreground browser GPS updates are sent periodically. This is not native/background tracking or production-grade proof of presence.
- OTP RPCs demonstrate secure hashed storage and role checks, but the current `request_ride_otp` returns the code to the passenger's authenticated browser. It does **not send SMS**. Before production, replace the return flow with a trusted Edge Function or database-to-provider integration that sends OTP only to the passenger, and never returns it to the driver. Do not advertise OTP/SMS delivery as live until configured and tested.
- Carpool has a driver listing form, passenger seat-request flow, driver accept/reject actions, and atomic seat accounting after the additive workflow migration.
- Document upload, emergency dispatch integration, account deletion workflow, payments, SMS delivery, native/background tracking, and independent security review remain production work.
- The UI intentionally does not invent nearby drivers, ratings, distances, or GPS locations.

## 1. Configure Supabase

1. Create a project at https://supabase.com/.
2. In **Project Settings → API** (or API Keys in the current dashboard), copy the Project URL and the **publishable/anon public key**.
3. Open `config.js` and replace:
   - `YOUR_SUPABASE_PROJECT_URL`
   - `YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY`
4. Never use the `service_role` / secret key in browser code, GitHub, screenshots, or chat.

## 2. Run SQL files in order

In Supabase, open **SQL Editor → New query**. Run the complete contents of:
1. `database/schema.sql`
2. `database/functions.sql`
3. `database/email_auth_migration.sql` (email verification and role-aware profile creation)
4. `database/policies.sql` (storage notes only)

The scripts are designed to be re-run without dropping tables or deleting records. If you already have an older AutoSetu schema, back it up and inspect existing columns/policies before applying changes. SQL may need a migration if your existing enums/tables differ.

After running SQL, go to **Database → Tables** and confirm the tables exist. If Supabase reports a policy/function error, stop and fix it rather than assuming setup succeeded.

## 3. Enable email verification (no phone required)

1. In Supabase, open **Authentication → Sign In / Providers** and ensure **Email** is enabled.
2. Keep **Confirm email** enabled so new users must verify their inbox before logging in.
3. Open **Authentication → URL Configuration**. Set the Site URL to your exact GitHub Pages address, for example `https://YOUR-USERNAME.github.io/autosetu-/`.
4. Add that same URL to the allowed Redirect URLs. Include the exact repository path and trailing slash if GitHub Pages uses one.
5. In Supabase **Authentication → Email Templates**, check that the confirmation email contains the Supabase confirmation link/action URL.
6. Create an account from AutoSetu. Open the email and click **Confirm your email**, then return to the website and log in.
7. If the email does not arrive, check Spam/Junk and Supabase Auth logs. The default email sender has delivery/rate limits; configure custom SMTP in Supabase for reliable public use.

No phone number or SMS provider is needed for account verification. The site does not use a fake email address: a real inbox you can access is required to confirm the account and receive account messages.

The `email_auth_migration.sql` trigger saves the user's chosen passenger/driver role at signup. Public signup can never create an administrator. New driver accounts start pending and cannot accept rides until an administrator approves them.

## 4. Create the first administrator securely

Public signup can create only `passenger` or `driver` accounts. Never add an admin dropdown to public registration.

1. Create an account using an email inbox you control and verify that email, then sign in once using the site.
2. In Supabase **Authentication → Users**, copy that user's UUID.
3. In SQL Editor, run this one-time statement after replacing the UUID:
   ```sql
   update public.profiles set role = 'admin' where id = 'PASTE-USER-UUID-HERE';
   ```
4. Restrict SQL Editor access to trusted project owners. Do not expose the Supabase service role key.
5. Sign out and sign in again. The account should show the admin dashboard.

## 5. Storage buckets

In **Storage**, create:
- `profile-photos` — choose public only if you intentionally want profile images public.
- `driver-documents` — **private**. Never use a public bucket for licence/insurance documents.

This MVP does not yet include document upload controls or storage policies for these buckets. Do not upload real identity documents until narrow folder-level policies and admin review access are implemented.

## 6. Enable Realtime

Open **Database → Publications** (or Realtime settings) and add `public.rides` to the Realtime publication. RLS must remain enabled. The app subscribes to ride row changes while a dashboard is open; a browser refresh also reloads current data.

## 7. Deploy to your existing GitHub repository `autosetu-`

1. Download and unzip this project.
2. Open your existing GitHub repository `autosetu-`.
3. Upload/replace the project files and folders in the repository root. Keep `index.html` at the root.
4. Commit to the branch you publish from (often `main`).
5. Open **Settings → Pages**. Choose **Deploy from a branch**, select `main` and `/ (root)`, then Save.
6. Wait for the Pages deployment to finish. Open the Pages URL over HTTPS.
7. If the repo URL includes a trailing dash, use that exact URL in Supabase Authentication URL configuration.
8. Test in a private/incognito window and review browser DevTools Console and Supabase Auth/Logs if a step fails.

No local server or Node.js is required for normal GitHub Pages hosting.

## 8. Test checklist

### Setup and authentication
- [ ] `config.js` has the project URL and public key (never service role).
- [ ] SQL files run without errors.
- [ ] Email provider is enabled and Confirm email is on.
- [ ] Signup sends a confirmation email, unverified login is blocked, verified login works, and logout works.
- [ ] First login leads to profile setup.
- [ ] Existing profile leads to the correct role dashboard.

### Passenger
- [ ] GPS permission prompt appears.
- [ ] Denied GPS gives a clear error.
- [ ] A ride request with real GPS coordinates is created.
- [ ] Passenger sees their ride and updated status.
- [ ] Report form accepts only a ride involving the reporter.

### Driver
- [ ] Driver profile exists and remains pending initially.
- [ ] Pending driver cannot go online or accept rides.
- [ ] Admin approves driver after separately verifying documents.
- [ ] Approved driver can go online with GPS.
- [ ] Two drivers cannot accept the same ride.
- [ ] Arrival check fails if stored GPS is more than 200m away.
- [ ] Email confirmation redirects back to the exact GitHub Pages URL.

### Admin and security
- [ ] Admin role is assigned only through trusted SQL.
- [ ] Non-admin cannot call admin RPCs.
- [ ] RLS is enabled on all user data tables.
- [ ] Public frontend has no service-role/secret key.
- [ ] Driver documents are private and protected by tested Storage policies.
- [ ] Review, suspension, account deletion, and incident response processes are tested before launch.

## Known implementation scope

This release is an expanded functional college/early-MVP workflow, not a fully audited commercial transport platform. It includes connected passenger, driver and admin panels; ride status and passenger-authorized OTP flows; foreground GPS refresh and a passenger map; carpool listing and seat request/acceptance; basic reviews; admin user suspension and report handling. Production gaps include SMS delivery, full document verification, background/native tracking, payments, account deletion, and independent security review.

## 9. Upgrade an existing connected AutoSetu database (non-destructive)

If your existing Supabase project already has the tables and the original `schema.sql` / `functions.sql` objects, **do not delete the project, drop tables, or reset the database**. First make a Supabase database backup (Dashboard → Database → Backups, where available), then:

1. Open Supabase → SQL Editor → New query.
2. Open `database/upgrade_workflows.sql` from this project.
3. Copy the complete file into SQL Editor and run it once.
4. Confirm the query finishes without errors. If it stops on an error, do not run the remaining statements piecemeal; copy the exact error and resolve it first.
5. In Database → Publications, confirm `rides`, `drivers`, `carpools`, `carpool_bookings`, and `ride_reports` are included in `supabase_realtime`. The migration attempts to add the missing tables automatically.

This migration is additive/replace-function based. It does not drop application tables or delete existing rows. It adds protected RPCs for driver GPS refresh, passenger ride cancellation, carpool seat requests/acceptance, reviews, admin account suspension and report handling. It also fixes the old `0,0` pickup-coordinate issue and extends profile visibility only to a trip counterpart, open carpool driver, or administrator. It replaces a few named RLS policies, so keep RLS enabled.

### New working flows in this package

- Passenger can request/cancel a ride, see driver assignment/status, get passenger-only start/completion codes, submit a review after completion, report a concern, browse open carpools and request/withdraw a seat.
- Driver can go online, keep the dashboard open for periodic GPS updates, accept a ride, mark arrival after a fresh GPS update, verify passenger-provided start/completion codes, publish/cancel a carpool and accept/reject carpool seat requests.
- Admin can view users, rides, carpools, pending driver verification and reports; approve/reject drivers; suspend/restore non-admin accounts; and update report status.
- Passenger live map shows the pickup and the assigned driver's most recently shared GPS location while the driver's dashboard is open and online.

### Important limits to understand

- GPS tracking requires the driver to grant location permission and keep the driver page open. Browser background throttling, device power settings and network loss can delay updates. This is not a native always-on tracking service.
- The live map displays the latest reported driver point, not turn-by-turn route navigation or a guaranteed real-time vehicle location.
- The ride OTP is generated by the database and displayed only in the passenger's authenticated browser, then verified by the driver. It is **not sent by SMS**. Integrate a trusted SMS/Edge Function provider before treating this as production OTP delivery.
- The carpool contribution is an informational cost-sharing amount; the website does not collect payments. Check applicable transport, insurance and state rules before public operation.
- Driver documents are not uploaded or independently verified by this release. Admin approval is a manual review state, not proof that a licence or insurance document is genuine.
- AI matching, demand prediction, SOS dispatch, masked calling, payment processing, and production fraud detection are not implemented as live services in this release. Do not present simulated values as actual AI or emergency services.

### Updated end-to-end test

Use two separate browser profiles (for example, normal and incognito) for passenger and driver, plus a third administrator login:

1. Passenger signs in, allows GPS, requests an auto ride.
2. Approved driver signs in on the second browser, goes online and accepts the request.
3. Confirm passenger dashboard updates without a manual refresh.
4. Driver approaches pickup with GPS enabled and presses **I HAVE ARRIVED**. If farther than 200 metres, the database correctly blocks arrival.
5. Passenger generates the start code; driver enters it to start the ride.
6. Passenger generates the completion code; driver enters it to complete the ride.
7. Passenger submits a rating. Confirm ride history and driver rating update.
8. Driver publishes a carpool. Passenger requests a seat. Driver accepts; confirm seats decrease and the passenger sees confirmed status.
9. Admin reviews users, rides, carpools and reports; test approve/reject, suspend/restore and report status changes.
10. Test with an unapproved driver and a passenger attempting admin RPCs. Both must be denied by the database.

### Deploy the upgraded frontend

Keep your existing `config.js` values. Replace the repository's project files with the contents of this upgraded folder (do not delete the Supabase project). Commit and wait for GitHub Pages to deploy. The service-worker cache version and `app.js` query string were updated to force browsers to load the new frontend. If an old screen remains, hard-refresh once or reopen in a private window.
