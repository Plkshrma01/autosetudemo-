-- Privileged operations. Each function checks auth.uid() and role inside PostgreSQL.
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
 if p_pickup_latitude not between -90 and 90 or p_pickup_longitude not between -180 and 180 then raise exception 'Valid GPS pickup is required'; end if;
 insert into public.rides(passenger_id,pickup_location,destination,pickup_latitude,pickup_longitude,destination_latitude,destination_longitude,vehicle_type)
 values(auth.uid(),trim(p_pickup_location),trim(p_destination),p_pickup_latitude,p_pickup_longitude,p_destination_latitude,p_destination_longitude,p_vehicle_type)
 returning id into v_id;
 return v_id;
end $$;

create or replace function public.set_driver_availability(p_online boolean,p_latitude double precision default null,p_longitude double precision default null)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from public.profiles p join public.drivers d on d.user_id=p.id where p.id=auth.uid() and p.role='driver' and not p.is_suspended) then raise exception 'Driver account required'; end if;
 if p_online and not exists(select 1 from public.drivers where user_id=auth.uid() and verification_status='approved') then raise exception 'Driver approval required before going online'; end if;
 if p_online and (p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180) then raise exception 'Valid GPS location required'; end if;
 update public.drivers set is_online=p_online,latitude=case when p_online then p_latitude else latitude end,longitude=case when p_online then p_longitude else longitude end,updated_at=now() where user_id=auth.uid();
 if not found then raise exception 'Driver profile not found'; end if;
end $$;

create or replace function public.accept_ride(p_ride_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_vehicle text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from public.drivers d join public.profiles p on p.id=d.user_id where d.user_id=auth.uid() and d.is_online and d.verification_status='approved' and p.role='driver' and not p.is_suspended) then raise exception 'Approved online driver required'; end if;
 select vehicle_type into v_vehicle from public.drivers where user_id=auth.uid();
 update public.rides set driver_id=auth.uid(),status='accepted',accepted_at=now()
 where id=p_ride_id and status='requested' and driver_id is null and vehicle_type=v_vehicle;
 if not found then raise exception 'This ride is no longer available or does not match your vehicle'; end if;
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
   select * into v_driver from public.drivers where user_id=auth.uid();
   if v_driver.latitude is null or v_driver.longitude is null then raise exception 'Driver GPS is unavailable'; end if;
   v_distance:=6371000*2*asin(sqrt(
     power(sin(radians(v_ride.pickup_latitude-v_driver.latitude)/2),2)+
     cos(radians(v_driver.latitude))*cos(radians(v_ride.pickup_latitude))*
     power(sin(radians(v_ride.pickup_longitude-v_driver.longitude)/2),2)));
   if v_distance>200 then raise exception 'You must be within 200 metres of pickup (current GPS is about % metres away)',round(v_distance); end if;
   update public.rides set status='arrived',arrived_at=now() where id=p_ride_id;
 elsif p_status='started' then
   raise exception 'Use verify_ride_otp after passenger-authorized start OTP';
 elsif p_status='completed' then
   raise exception 'Use verify_ride_otp after passenger-authorized completion OTP';
 else raise exception 'Unsupported status change'; end if;
end $$;

-- OTP generation/verification: hashes are not readable through table SELECT policy.
-- A production SMS provider must be integrated before exposing send_ride_otp to users.
create or replace function public.request_ride_otp(p_ride_id uuid,p_purpose text)
returns text language plpgsql security definer set search_path=public as $$
declare v_ride public.rides%rowtype; v_code text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_purpose not in ('start','finish') then raise exception 'Invalid OTP purpose'; end if;
 select * into v_ride from public.rides where id=p_ride_id for update;
 if not found or v_ride.passenger_id<>auth.uid() then raise exception 'Only the passenger can request this OTP'; end if;
 if p_purpose='start' and v_ride.status<>'arrived' then raise exception 'Driver must confirm arrival first'; end if;
 if p_purpose='finish' and v_ride.status<>'started' then raise exception 'Ride must be started first'; end if;
 if v_ride.otp_requested_at is not null and v_ride.otp_requested_at>now()-interval '60 seconds' then raise exception 'Please wait before requesting another OTP'; end if;
 v_code:=lpad(floor(random()*1000000)::int::text,6,'0');
 update public.rides set
   start_otp_hash=case when p_purpose='start' then crypt(v_code,gen_salt('bf')) else null end,
   finish_otp_hash=case when p_purpose='finish' then crypt(v_code,gen_salt('bf')) else null end,
   otp_purpose=p_purpose,otp_expiry=now()+interval '5 minutes',failed_attempts=0,otp_requested_at=now()
 where id=p_ride_id;
 -- IMPORTANT: This return value is for passenger-only authenticated UI. Connect a real SMS provider before production.
 return v_code;
end $$;

create or replace function public.verify_ride_otp(p_ride_id uuid,p_purpose text,p_code text)
returns void language plpgsql security definer set search_path=public as $$
declare v_ride public.rides%rowtype; v_hash text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_purpose not in ('start','finish') or p_code !~ '^[0-9]{6}$' then raise exception 'Invalid OTP'; end if;
 select * into v_ride from public.rides where id=p_ride_id for update;
 if not found or v_ride.driver_id<>auth.uid() then raise exception 'Only the assigned driver can verify this OTP'; end if;
 if v_ride.failed_attempts>=5 then raise exception 'Too many failed attempts'; end if;
 if v_ride.otp_purpose<>p_purpose or v_ride.otp_expiry<now() then raise exception 'OTP expired or not requested'; end if;
 v_hash:=case when p_purpose='start' then v_ride.start_otp_hash else v_ride.finish_otp_hash end;
 if v_hash is null or crypt(p_code,v_hash)<>v_hash then
   update public.rides set failed_attempts=failed_attempts+1 where id=p_ride_id;
   raise exception 'Incorrect OTP';
 end if;
 if p_purpose='start' and v_ride.status='arrived' then
   update public.rides set status='started',started_at=now(),start_otp_hash=null,otp_purpose=null,otp_expiry=null,failed_attempts=0 where id=p_ride_id;
 elsif p_purpose='finish' and v_ride.status='started' then
   update public.rides set status='completed',completed_at=now(),finish_otp_hash=null,otp_purpose=null,otp_expiry=null,failed_attempts=0 where id=p_ride_id;
   update public.drivers set total_rides=total_rides+1,is_online=true where user_id=v_ride.driver_id;
 else raise exception 'Ride status does not match this OTP'; end if;
end $$;

create or replace function public.admin_set_driver_verification(p_user_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then raise exception 'Administrator access required'; end if;
 if p_status not in ('approved','rejected','suspended') then raise exception 'Invalid verification status'; end if;
 update public.drivers set verification_status=p_status::public.driver_verification_status,is_online=false,updated_at=now() where user_id=p_user_id;
 if not found then raise exception 'Driver not found'; end if;
end $$;

create or replace function public.admin_dashboard_stats()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then raise exception 'Administrator access required'; end if;
 return jsonb_build_object(
 'passengers',(select count(*) from public.profiles where role='passenger'),
 'drivers',(select count(*) from public.drivers),
 'rides',(select count(*) from public.rides),
 'completed',(select count(*) from public.rides where status='completed'),
 'cancelled',(select count(*) from public.rides where status='cancelled'),
 'pending_drivers',(select count(*) from public.drivers where verification_status='pending'));
end $$;

-- Atomic carpool booking: locks the carpool row to prevent overbooking.
create or replace function public.book_carpool(p_carpool_id uuid,p_seats integer default 1)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_c public.carpools%rowtype; v_booking uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_seats<1 or p_seats>12 then raise exception 'Invalid seat count'; end if;
 select * into v_c from public.carpools where id=p_carpool_id for update;
 if not found or v_c.status<>'open' or v_c.departure_time<=now() then raise exception 'Carpool unavailable'; end if;
 if v_c.driver_id=auth.uid() then raise exception 'Cannot book your own carpool'; end if;
 if v_c.seats_remaining<p_seats then raise exception 'Not enough seats available'; end if;
 insert into public.carpool_bookings(carpool_id,passenger_id,seats_booked,status) values(p_carpool_id,auth.uid(),p_seats,'confirmed') returning id into v_booking;
 update public.carpools set seats_remaining=seats_remaining-p_seats,status=case when seats_remaining-p_seats=0 then 'full' else 'open' end where id=p_carpool_id;
 return v_booking;
end $$;

revoke all on function public.request_ride(text,text,double precision,double precision,double precision,double precision,text) from public;
revoke all on function public.set_driver_availability(boolean,double precision,double precision) from public;
revoke all on function public.accept_ride(uuid) from public;
revoke all on function public.driver_update_ride_status(uuid,text) from public;
revoke all on function public.request_ride_otp(uuid,text) from public;
revoke all on function public.verify_ride_otp(uuid,text,text) from public;
revoke all on function public.admin_set_driver_verification(uuid,text) from public;
revoke all on function public.admin_dashboard_stats() from public;
revoke all on function public.book_carpool(uuid,integer) from public;
grant execute on function public.request_ride(text,text,double precision,double precision,double precision,double precision,text) to authenticated;
grant execute on function public.set_driver_availability(boolean,double precision,double precision) to authenticated;
grant execute on function public.accept_ride(uuid) to authenticated;
grant execute on function public.driver_update_ride_status(uuid,text) to authenticated;
grant execute on function public.request_ride_otp(uuid,text) to authenticated;
grant execute on function public.verify_ride_otp(uuid,text,text) to authenticated;
grant execute on function public.admin_set_driver_verification(uuid,text) to authenticated;
grant execute on function public.admin_dashboard_stats() to authenticated;
grant execute on function public.book_carpool(uuid,integer) to authenticated;
