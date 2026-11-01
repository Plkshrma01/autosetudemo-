-- AutoSetu additive workflow upgrade (non-destructive).
-- Run AFTER schema.sql and functions.sql. Does not drop tables or delete records.

create or replace function public.update_driver_location(p_latitude double precision,p_longitude double precision)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'Valid GPS coordinates are required';
  end if;
  update public.drivers d set latitude=p_latitude,longitude=p_longitude,updated_at=now()
  where d.user_id=auth.uid() and d.is_online and d.verification_status='approved'
    and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='driver' and not p.is_suspended);
  if not found then raise exception 'Approved online driver profile required'; end if;
end $$;

create or replace function public.cancel_ride(p_ride_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.rides%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into r from public.rides where id=p_ride_id for update;
  if not found or r.passenger_id<>auth.uid() then raise exception 'Only the passenger can cancel this ride'; end if;
  if r.status not in ('requested','accepted') then raise exception 'This ride can no longer be cancelled from the passenger panel'; end if;
  update public.rides set status='cancelled',cancelled_at=now() where id=p_ride_id;
end $$;

create or replace function public.request_carpool_seat(p_carpool_id uuid,p_seats integer default 1)
returns uuid language plpgsql security definer set search_path=public as $$
declare c public.carpools%rowtype; b uuid;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if p_seats<1 or p_seats>12 then raise exception 'Choose between 1 and 12 seats'; end if;
  if not exists(select 1 from public.profiles where id=auth.uid() and role='passenger' and not is_suspended) then raise exception 'Passenger account required'; end if;
  select * into c from public.carpools where id=p_carpool_id for update;
  if not found or c.status<>'open' or c.departure_time<=now() then raise exception 'Carpool is unavailable'; end if;
  if c.driver_id=auth.uid() then raise exception 'You cannot request your own carpool'; end if;
  if c.seats_remaining<p_seats then raise exception 'Not enough seats remain'; end if;
  insert into public.carpool_bookings(carpool_id,passenger_id,seats_booked,status)
  values(p_carpool_id,auth.uid(),p_seats,'requested') returning id into b;
  return b;
end $$;

create or replace function public.respond_carpool_booking(p_booking_id uuid,p_decision text)
returns void language plpgsql security definer set search_path=public as $$
declare b public.carpool_bookings%rowtype; c public.carpools%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if p_decision not in ('confirmed','cancelled') then raise exception 'Decision must be confirmed or cancelled'; end if;
  select * into b from public.carpool_bookings where id=p_booking_id for update;
  if not found then raise exception 'Seat request not found'; end if;
  select * into c from public.carpools where id=b.carpool_id for update;
  if p_decision='confirmed' then
    if c.driver_id<>auth.uid() then raise exception 'Only this carpool driver can accept the request'; end if;
    if b.status<>'requested' or c.status<>'open' or c.seats_remaining<b.seats_booked then raise exception 'Request is no longer available'; end if;
    update public.carpool_bookings set status='confirmed' where id=b.id;
    update public.carpools set seats_remaining=seats_remaining-b.seats_booked,
      status=case when seats_remaining-b.seats_booked=0 then 'full' else 'open' end where id=c.id;
  else
    if b.passenger_id<>auth.uid() and c.driver_id<>auth.uid() then raise exception 'Not allowed to reject/cancel this request'; end if;
    if b.status='confirmed' then
      update public.carpools set seats_remaining=least(available_seats,seats_remaining+b.seats_booked),status='open' where id=c.id and c.departure_time>now();
    end if;
    update public.carpool_bookings set status='cancelled' where id=b.id;
  end if;
end $$;

create or replace function public.submit_ride_review(p_ride_id uuid,p_rating integer,p_review text default null)
returns void language plpgsql security definer set search_path=public as $$
declare r public.rides%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if p_rating not between 1 and 5 then raise exception 'Rating must be between 1 and 5'; end if;
  select * into r from public.rides where id=p_ride_id for update;
  if not found or r.passenger_id<>auth.uid() or r.status<>'completed' or r.driver_id is null then raise exception 'Only a passenger on a completed ride can rate the driver'; end if;
  insert into public.reviews(ride_id,passenger_id,driver_id,rating,review)
  values(r.id,auth.uid(),r.driver_id,p_rating,nullif(left(trim(coalesce(p_review,'')),1000),''));
  update public.drivers d set rating=(select round(avg(rating)::numeric,2) from public.reviews where driver_id=r.driver_id)
  where d.user_id=r.driver_id;
end $$;

create or replace function public.admin_set_user_suspension(p_user_id uuid,p_suspended boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_user_id=auth.uid() then raise exception 'You cannot suspend your own administrator account'; end if;
  update public.profiles set is_suspended=p_suspended where id=p_user_id and role<>'admin';
  if not found then raise exception 'User not found or cannot be modified'; end if;
  if p_suspended then update public.drivers set is_online=false where user_id=p_user_id; end if;
end $$;

create or replace function public.admin_update_report(p_report_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_status not in ('open','reviewing','resolved','dismissed') then raise exception 'Invalid report status'; end if;
  update public.ride_reports set status=p_status where id=p_report_id;
  if not found then raise exception 'Report not found'; end if;
end $$;

revoke all on function public.update_driver_location(double precision,double precision) from public;
revoke all on function public.cancel_ride(uuid) from public;
revoke all on function public.request_carpool_seat(uuid,integer) from public;
revoke all on function public.respond_carpool_booking(uuid,text) from public;
revoke all on function public.submit_ride_review(uuid,integer,text) from public;
revoke all on function public.admin_set_user_suspension(uuid,boolean) from public;
revoke all on function public.admin_update_report(uuid,text) from public;
grant execute on function public.update_driver_location(double precision,double precision) to authenticated;
grant execute on function public.cancel_ride(uuid) to authenticated;
grant execute on function public.request_carpool_seat(uuid,integer) to authenticated;
grant execute on function public.respond_carpool_booking(uuid,text) to authenticated;
grant execute on function public.submit_ride_review(uuid,integer,text) to authenticated;
grant execute on function public.admin_set_user_suspension(uuid,boolean) to authenticated;
grant execute on function public.admin_update_report(uuid,text) to authenticated;

-- Enable realtime for the tables used by the dashboards. Duplicate publication
-- membership is harmlessly ignored. If your project uses a custom publication,
-- add these tables through Database > Publications instead.
do $$ begin
  alter publication supabase_realtime add table public.carpools;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.carpool_bookings;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.ride_reports;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- Let a passenger read the carpool record attached to their own seat request,
-- including a listing that became full after the request was accepted.
drop policy if exists "carpools_select_open_or_owner" on public.carpools;
create policy "carpools_select_open_owner_or_booked_passenger" on public.carpools for select to authenticated
using (status='open' or driver_id=auth.uid() or exists(
  select 1 from public.carpool_bookings b where b.carpool_id=carpools.id and b.passenger_id=auth.uid()
));

do $$ begin
  alter publication supabase_realtime add table public.drivers;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- Safe display of a ride counterpart's name, and a driver name on a public
-- open carpool. Sensitive contact columns are not granted to authenticated clients.
drop policy if exists "profiles_select_self_or_admin" on public.profiles;
create policy "profiles_select_self_admin_or_trip_counterpart" on public.profiles for select to authenticated
using (
  id=auth.uid() or public.is_admin()
  or exists(select 1 from public.rides r where
    (r.passenger_id=auth.uid() and r.driver_id=profiles.id)
    or (r.driver_id=auth.uid() and r.passenger_id=profiles.id))
  or exists(select 1 from public.carpools c where c.driver_id=profiles.id and c.status='open')
);

create or replace function public.has_carpool_booking(p_carpool_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.carpool_bookings b where b.carpool_id=p_carpool_id and b.passenger_id=auth.uid())
$$;
revoke all on function public.has_carpool_booking(uuid) from public;
grant execute on function public.has_carpool_booking(uuid) to authenticated;
drop policy if exists "carpools_select_open_owner_or_booked_passenger" on public.carpools;
create policy "carpools_select_open_owner_or_booked_passenger" on public.carpools for select to authenticated
using (status='open' or driver_id=auth.uid() or public.has_carpool_booking(id));

-- Reject empty/placeholder coordinates. This prevents the old 0,0 pickup
-- bug from producing an impossible distance in the 200m arrival check.
create or replace function public.request_ride(
 p_pickup_location text, p_destination text, p_pickup_latitude double precision,
 p_pickup_longitude double precision, p_destination_latitude double precision default null,
 p_destination_longitude double precision default null, p_vehicle_type text default 'auto'
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='passenger' and not p.is_suspended) then raise exception 'Passenger account required'; end if;
 if length(trim(p_pickup_location))<2 or length(trim(p_destination))<2 then raise exception 'Pickup and destination are required'; end if;
 if p_vehicle_type not in ('auto','taxi') then raise exception 'Invalid vehicle type'; end if;
 if p_pickup_latitude is null or p_pickup_longitude is null or p_pickup_latitude not between -90 and 90 or p_pickup_longitude not between -180 and 180 or (p_pickup_latitude=0 and p_pickup_longitude=0) then raise exception 'Valid GPS pickup is required; placeholder coordinates are not accepted'; end if;
 insert into public.rides(passenger_id,pickup_location,destination,pickup_latitude,pickup_longitude,destination_latitude,destination_longitude,vehicle_type)
 values(auth.uid(),trim(p_pickup_location),trim(p_destination),p_pickup_latitude,p_pickup_longitude,p_destination_latitude,p_destination_longitude,p_vehicle_type)
 returning id into v_id;
 return v_id;
end $$;

create or replace function public.driver_update_ride_status(p_ride_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare v_ride public.rides%rowtype; v_driver public.drivers%rowtype; v_distance double precision;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into v_ride from public.rides where id=p_ride_id for update;
 if not found or v_ride.driver_id<>auth.uid() then raise exception 'Ride not assigned to this driver'; end if;
 if p_status='arrived' then
   if v_ride.status<>'accepted' then raise exception 'Ride must be accepted first'; end if;
   if v_ride.pickup_latitude is null or v_ride.pickup_longitude is null or (v_ride.pickup_latitude=0 and v_ride.pickup_longitude=0) then raise exception 'This ride has invalid pickup GPS. Ask the passenger to cancel and create a new request using GPS.'; end if;
   select * into v_driver from public.drivers where user_id=auth.uid();
   if v_driver.latitude is null or v_driver.longitude is null then raise exception 'Driver GPS is unavailable. Turn on location and try again.'; end if;
   v_distance:=6371000*2*asin(sqrt(
     power(sin(radians(v_ride.pickup_latitude-v_driver.latitude)/2),2)+
     cos(radians(v_driver.latitude))*cos(radians(v_ride.pickup_latitude))*
     power(sin(radians(v_ride.pickup_longitude-v_driver.longitude)/2),2)));
   if v_distance>200 then raise exception 'You must be within 200 metres of pickup (current GPS is about % metres away)',round(v_distance); end if;
   update public.rides set status='arrived',arrived_at=now() where id=p_ride_id;
 elsif p_status='started' then raise exception 'Use verify_ride_otp after passenger-authorized start OTP';
 elsif p_status='completed' then raise exception 'Use verify_ride_otp after passenger-authorized completion OTP';
 else raise exception 'Unsupported status change'; end if;
end $$;
revoke all on function public.request_ride(text,text,double precision,double precision,double precision,double precision,text) from public;
revoke all on function public.driver_update_ride_status(uuid,text) from public;
grant execute on function public.request_ride(text,text,double precision,double precision,double precision,double precision,text) to authenticated;
grant execute on function public.driver_update_ride_status(uuid,text) to authenticated;

-- Route mutations through checked RPCs; do not let browser clients directly
-- alter role-sensitive workflow columns.
drop policy if exists "drivers_update_self_safe" on public.drivers;
drop policy if exists "rides_update_participant_limited" on public.rides;
drop policy if exists "carpools_insert_approved_driver" on public.carpools;
drop policy if exists "carpools_update_owner" on public.carpools;
drop policy if exists "carpool_bookings_insert_self" on public.carpool_bookings;
drop policy if exists "carpool_bookings_update_self" on public.carpool_bookings;

create or replace function public.create_carpool(
 p_pickup_location text,p_destination text,p_departure_time timestamptz,
 p_available_seats integer,p_price_per_seat numeric default 0
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from public.profiles p join public.drivers d on d.user_id=p.id where p.id=auth.uid() and p.role='driver' and not p.is_suspended and d.verification_status='approved') then raise exception 'Approved active driver required'; end if;
 if length(trim(p_pickup_location))<2 or length(trim(p_destination))<2 then raise exception 'Starting location and destination are required'; end if;
 if p_departure_time<=now() then raise exception 'Departure must be in the future'; end if;
 if p_available_seats<1 or p_available_seats>12 then raise exception 'Available seats must be between 1 and 12'; end if;
 if p_price_per_seat<0 or p_price_per_seat>100000 then raise exception 'Invalid cost contribution'; end if;
 insert into public.carpools(driver_id,pickup_location,destination,departure_time,available_seats,seats_remaining,price_per_seat,status)
 values(auth.uid(),trim(p_pickup_location),trim(p_destination),p_departure_time,p_available_seats,p_available_seats,p_price_per_seat,'open') returning id into v_id;
 return v_id;
end $$;

create or replace function public.driver_cancel_carpool(p_carpool_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 update public.carpools set status='cancelled' where id=p_carpool_id and driver_id=auth.uid() and status in ('open','full') and departure_time>now();
 if not found then raise exception 'Carpool cannot be cancelled'; end if;
end $$;

revoke all on function public.create_carpool(text,text,timestamptz,integer,numeric) from public;
revoke all on function public.driver_cancel_carpool(uuid) from public;
grant execute on function public.create_carpool(text,text,timestamptz,integer,numeric) to authenticated;
grant execute on function public.driver_cancel_carpool(uuid) to authenticated;

-- Prevent overlapping active rides for either side.
create or replace function public.request_ride(
 p_pickup_location text, p_destination text, p_pickup_latitude double precision,
 p_pickup_longitude double precision, p_destination_latitude double precision default null,
 p_destination_longitude double precision default null, p_vehicle_type text default 'auto'
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 perform pg_advisory_xact_lock(hashtext(auth.uid()::text));
 if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='passenger' and not p.is_suspended) then raise exception 'Passenger account required'; end if;
 if exists(select 1 from public.rides where passenger_id=auth.uid() and status in ('requested','accepted','arrived','started')) then raise exception 'You already have an active ride'; end if;
 if length(trim(p_pickup_location))<2 or length(trim(p_destination))<2 then raise exception 'Pickup and destination are required'; end if;
 if p_vehicle_type not in ('auto','taxi') then raise exception 'Invalid vehicle type'; end if;
 if p_pickup_latitude is null or p_pickup_longitude is null or p_pickup_latitude not between -90 and 90 or p_pickup_longitude not between -180 and 180 or (p_pickup_latitude=0 and p_pickup_longitude=0) then raise exception 'Valid GPS pickup is required; placeholder coordinates are not accepted'; end if;
 insert into public.rides(passenger_id,pickup_location,destination,pickup_latitude,pickup_longitude,destination_latitude,destination_longitude,vehicle_type)
 values(auth.uid(),trim(p_pickup_location),trim(p_destination),p_pickup_latitude,p_pickup_longitude,p_destination_latitude,p_destination_longitude,p_vehicle_type)
 returning id into v_id;
 return v_id;
end $$;

create or replace function public.accept_ride(p_ride_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_vehicle text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 perform pg_advisory_xact_lock(hashtext(auth.uid()::text));
 if not exists(select 1 from public.drivers d join public.profiles p on p.id=d.user_id where d.user_id=auth.uid() and d.is_online and d.verification_status='approved' and p.role='driver' and not p.is_suspended) then raise exception 'Approved online driver required'; end if;
 if exists(select 1 from public.rides where driver_id=auth.uid() and status in ('accepted','arrived','started')) then raise exception 'Complete your current ride before accepting another'; end if;
 select vehicle_type into v_vehicle from public.drivers where user_id=auth.uid();
 update public.rides set driver_id=auth.uid(),status='accepted',accepted_at=now()
 where id=p_ride_id and status='requested' and driver_id is null and vehicle_type=v_vehicle;
 if not found then raise exception 'This ride is no longer available or does not match your vehicle'; end if;
end $$;
revoke all on function public.accept_ride(uuid) from public;
grant execute on function public.accept_ride(uuid) to authenticated;
revoke execute on function public.book_carpool(uuid,integer) from authenticated;

-- Restrict profile reads to non-sensitive columns. A ride counterpart can
-- see a display name but cannot fetch the phone column through the public API.
revoke select on table public.profiles from authenticated;
grant select (id,full_name,email,avatar_url,role,is_suspended,created_at,updated_at)
on table public.profiles to authenticated;
-- Keep email and phone hidden from trip counterparts; the frontend uses the
-- authenticated Supabase user email for sign-in and does not need profile email reads.
revoke select on table public.profiles from authenticated;
grant select (id,full_name,avatar_url,role,is_suspended,created_at,updated_at)
on table public.profiles to authenticated;
