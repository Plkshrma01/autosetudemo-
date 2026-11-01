-- AutoSetu email/password authentication migration
-- Run once in Supabase SQL Editor after the original schema.sql.
-- Safe for existing data: it replaces the signup trigger function and one policy only.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_role public.app_role;
  new_name text;
begin
  -- Public signup can create passenger or driver accounts only. Never allow admin metadata.
  if coalesce(new.raw_user_meta_data ->> 'requested_role', 'passenger') = 'driver' then
    requested_role := 'driver';
  else
    requested_role := 'passenger';
  end if;
  new_name := left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 100);

  insert into public.profiles(id, phone, email, full_name, role)
  values(new.id, new.phone, new.email, new_name, requested_role)
  on conflict (id) do update
    set email = excluded.email,
        full_name = case when public.profiles.full_name = '' then excluded.full_name else public.profiles.full_name end;

  if requested_role = 'driver' then
    insert into public.drivers(user_id, vehicle_type, verification_status, is_online)
    values(new.id, 'auto', 'pending', false)
    on conflict (user_id) do nothing;
  end if;
  return new;
end;
$$;

-- Replace the original passenger-only profile insert policy. User may create only their own
-- passenger/driver profile; admin can never be assigned by public signup.
drop policy if exists "profiles_insert_self_passenger" on public.profiles;
drop policy if exists "profiles_insert_self_basic_roles" on public.profiles;
create policy "profiles_insert_self_basic_roles"
on public.profiles for insert to authenticated
with check (id = auth.uid() and role in ('passenger', 'driver') and is_suspended = false);

-- Keep the existing signup trigger connected to the updated function.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();
