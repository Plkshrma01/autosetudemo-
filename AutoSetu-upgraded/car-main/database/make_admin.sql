-- AutoSetu: promote ONE existing verified account to administrator.
-- Run only in the Supabase SQL Editor as the project owner.
-- Replace the email below with the exact email of your own verified account.
-- Public signup cannot assign the admin role.

update public.profiles as p
set role = 'admin'
from auth.users as u
where p.id = u.id
  and lower(u.email) = lower('YOUR_VERIFIED_EMAIL_HERE')
returning p.id, p.email, p.role;

-- If this returns zero rows, verify that you have signed up, confirmed your email,
-- logged in once, and replaced the placeholder with the correct email.
