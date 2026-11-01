-- AutoSetu database schema. Safe to re-run: no DROP statements and no data deletion.
create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('passenger','driver','admin');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.driver_verification_status as enum ('pending','approved','rejected','suspended');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.ride_status as enum ('requested','accepted','arrived','started','completed','cancelled');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text unique,
  email text,
  avatar_url text,
  role public.app_role not null default 'passenger',
  is_suspended boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_name_length check (char_length(full_name) <= 100)
);

create table if not exists public.drivers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  vehicle_type text not null default 'auto' check (vehicle_type in ('auto','taxi')),
  vehicle_number text,
  licence_number text,
  insurance_number text,
  verification_status public.driver_verification_status not null default 'pending',
  is_online boolean not null default false,
  latitude double precision,
  longitude double precision,
  rating numeric(3,2) not null default 0 check (rating between 0 and 5),
  total_rides integer not null default 0 check (total_rides >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (latitude is null or latitude between -90 and 90),
  check (longitude is null or longitude between -180 and 180)
);

create table if not exists public.rides (
  id uuid primary key default gen_random_uuid(),
  passenger_id uuid not null references public.profiles(id),
  driver_id uuid references public.profiles(id),
  pickup_location text not null,
  destination text not null,
  pickup_latitude double precision not null,
  pickup_longitude double precision not null,
  destination_latitude double precision,
  destination_longitude double precision,
  vehicle_type text not null check (vehicle_type in ('auto','taxi')),
  status public.ride_status not null default 'requested',
  start_otp_hash text,
  finish_otp_hash text,
  otp_expiry timestamptz,
  failed_attempts integer not null default 0 check (failed_attempts >= 0),
  otp_purpose text check (otp_purpose in ('start','finish') or otp_purpose is null),
  otp_requested_at timestamptz,
  requested_at timestamptz not null default now(),
  accepted_at timestamptz,
  arrived_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  check (pickup_latitude between -90 and 90),
  check (pickup_longitude between -180 and 180),
  check (destination_latitude is null or destination_latitude between -90 and 90),
  check (destination_longitude is null or destination_longitude between -180 and 180)
);

create table if not exists public.ride_reports (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides(id) on delete cascade,
  reported_by uuid not null references public.profiles(id),
  reported_user uuid references public.profiles(id),
  category text not null check (category in ('safety','conduct','payment','other')),
  description text not null check (char_length(description) between 3 and 2000),
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now()
);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null unique references public.rides(id) on delete cascade,
  passenger_id uuid not null references public.profiles(id),
  driver_id uuid not null references public.profiles(id),
  rating integer not null check (rating between 1 and 5),
  review text check (review is null or char_length(review) <= 1000),
  created_at timestamptz not null default now()
);

create table if not exists public.carpools (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.profiles(id),
  pickup_location text not null,
  destination text not null,
  departure_time timestamptz not null,
  available_seats integer not null check (available_seats between 1 and 12),
  seats_remaining integer not null check (seats_remaining between 0 and 12),
  price_per_seat numeric(10,2) not null default 0 check (price_per_seat >= 0),
  status text not null default 'open' check (status in ('open','full','cancelled','completed')),
  created_at timestamptz not null default now()
);

create table if not exists public.carpool_bookings (
  id uuid primary key default gen_random_uuid(),
  carpool_id uuid not null references public.carpools(id) on delete cascade,
  passenger_id uuid not null references public.profiles(id),
  seats_booked integer not null check (seats_booked between 1 and 12),
  status text not null default 'requested' check (status in ('requested','confirmed','cancelled')),
  created_at timestamptz not null default now(),
  unique(carpool_id,passenger_id)
);

create index if not exists rides_passenger_requested_idx on public.rides(passenger_id, requested_at desc);
create index if not exists rides_driver_requested_idx on public.rides(driver_id, requested_at desc);
create index if not exists rides_status_vehicle_idx on public.rides(status, vehicle_type, requested_at desc);
create index if not exists drivers_online_vehicle_idx on public.drivers(is_online, verification_status, vehicle_type);
create index if not exists drivers_location_idx on public.drivers(latitude, longitude);
create index if not exists reports_status_created_idx on public.ride_reports(status, created_at desc);
create index if not exists carpools_departure_status_idx on public.carpools(status, departure_time);
create index if not exists carpool_bookings_passenger_idx on public.carpool_bookings(passenger_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path=public as $$
begin new.updated_at=now(); return new; end $$;
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists drivers_updated_at on public.drivers;
create trigger drivers_updated_at before update on public.drivers for each row execute function public.set_updated_at();

-- Create a basic profile after Auth signup. Role is always passenger by default; no admin escalation.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id, phone, email, full_name, role)
  values(new.id, new.phone, new.email, '', 'passenger')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.drivers enable row level security;
alter table public.rides enable row level security;
alter table public.ride_reports enable row level security;
alter table public.reviews enable row level security;
alter table public.carpools enable row level security;
alter table public.carpool_bookings enable row level security;

-- SECURITY DEFINER helper avoids recursive RLS checks on profiles.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and role='admin' and not is_suspended)
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- Profiles: self or admin. Public users may select only their own row.
drop policy if exists "profiles_select_self_or_admin" on public.profiles;
create policy "profiles_select_self_or_admin" on public.profiles for select to authenticated
using (id=auth.uid() or public.is_admin());
drop policy if exists "profiles_insert_self_passenger" on public.profiles;
create policy "profiles_insert_self_passenger" on public.profiles for insert to authenticated
with check (id=auth.uid() and role='passenger');
drop policy if exists "profiles_update_self_nonprivileged" on public.profiles;
create policy "profiles_update_self_nonprivileged" on public.profiles for update to authenticated
using (id=auth.uid() or public.is_admin())
with check (
  public.is_admin()
  or (id=auth.uid() and role in ('passenger','driver') and is_suspended=false)
);

drop policy if exists "drivers_select_self_admin_or_eligible" on public.drivers;
create policy "drivers_select_self_admin_or_eligible" on public.drivers for select to authenticated
using (user_id=auth.uid() or public.is_admin()
  or (verification_status='approved' and is_online=true));
drop policy if exists "drivers_insert_self_pending" on public.drivers;
create policy "drivers_insert_self_pending" on public.drivers for insert to authenticated
with check (user_id=auth.uid() and verification_status='pending' and is_online=false);
drop policy if exists "drivers_update_self_safe" on public.drivers;
create policy "drivers_update_self_safe" on public.drivers for update to authenticated
using (user_id=auth.uid()) with check (user_id=auth.uid() and verification_status=(select d.verification_status from public.drivers d where d.user_id=auth.uid()));

drop policy if exists "rides_select_participants_or_admin" on public.rides;
create policy "rides_select_participants_or_admin" on public.rides for select to authenticated
using (passenger_id=auth.uid() or driver_id=auth.uid() or
  (status='requested' and driver_id is null and exists(select 1 from public.drivers d where d.user_id=auth.uid() and d.is_online and d.verification_status='approved' and d.vehicle_type=rides.vehicle_type)) or
  public.is_admin());
drop policy if exists "rides_insert_passenger_only" on public.rides;
create policy "rides_insert_passenger_only" on public.rides for insert to authenticated
with check (passenger_id=auth.uid() and driver_id is null and status='requested');
drop policy if exists "rides_update_participant_limited" on public.rides;
create policy "rides_update_participant_limited" on public.rides for update to authenticated
using (passenger_id=auth.uid() or driver_id=auth.uid() or public.is_admin())
with check (passenger_id=auth.uid() or driver_id=auth.uid() or public.is_admin());

drop policy if exists "reports_insert_own" on public.ride_reports;
create policy "reports_insert_own" on public.ride_reports for insert to authenticated
with check (reported_by=auth.uid() and exists(select 1 from public.rides r where r.id=ride_id and (r.passenger_id=auth.uid() or r.driver_id=auth.uid())));
drop policy if exists "reports_select_reporter_admin" on public.ride_reports;
create policy "reports_select_reporter_admin" on public.ride_reports for select to authenticated
using (reported_by=auth.uid() or public.is_admin());

drop policy if exists "reviews_select_participants" on public.reviews;
create policy "reviews_select_participants" on public.reviews for select to authenticated
using (passenger_id=auth.uid() or driver_id=auth.uid() or public.is_admin());
drop policy if exists "reviews_insert_passenger_completed" on public.reviews;
create policy "reviews_insert_passenger_completed" on public.reviews for insert to authenticated
with check (passenger_id=auth.uid() and exists(select 1 from public.rides r where r.id=ride_id and r.passenger_id=auth.uid() and r.driver_id=reviews.driver_id and r.status='completed'));

drop policy if exists "carpools_select_open_or_owner" on public.carpools;
create policy "carpools_select_open_or_owner" on public.carpools for select to authenticated using (status='open' or driver_id=auth.uid());
drop policy if exists "carpools_insert_approved_driver" on public.carpools;
create policy "carpools_insert_approved_driver" on public.carpools for insert to authenticated with check (driver_id=auth.uid() and exists(select 1 from public.drivers d where d.user_id=auth.uid() and d.verification_status='approved'));
drop policy if exists "carpools_update_owner" on public.carpools;
create policy "carpools_update_owner" on public.carpools for update to authenticated using (driver_id=auth.uid()) with check (driver_id=auth.uid());

drop policy if exists "carpool_bookings_select_parties" on public.carpool_bookings;
create policy "carpool_bookings_select_parties" on public.carpool_bookings for select to authenticated
using (passenger_id=auth.uid() or exists(select 1 from public.carpools c where c.id=carpool_id and c.driver_id=auth.uid()));
drop policy if exists "carpool_bookings_insert_self" on public.carpool_bookings;
create policy "carpool_bookings_insert_self" on public.carpool_bookings for insert to authenticated
with check (passenger_id=auth.uid());
drop policy if exists "carpool_bookings_update_self" on public.carpool_bookings;
create policy "carpool_bookings_update_self" on public.carpool_bookings for update to authenticated using (passenger_id=auth.uid()) with check (passenger_id=auth.uid());

-- Realtime publication is managed by Supabase. Add rides in Dashboard > Database > Publications if not already included.
