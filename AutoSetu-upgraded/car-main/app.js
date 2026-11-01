(() => {
  "use strict";
  const cfg = window.AUTOSETU_CONFIG || {};
  const $ = (id) => document.getElementById(id);
  const state = { client: null, user: null, profile: null, resendTimer: null, realtime: [], location: null, watchId: null, lastLocationSent: 0, dashboardRun: 0 };
  const views = ["landing-view","auth-view","profile-view","dashboard-view"];
  const showView = (id) => { views.forEach(v => $(v).classList.toggle("hidden", v !== id)); window.scrollTo({top:0,behavior:"smooth"}); };
  const escapeHtml = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  function toast(message, type="info") { const el=$("toast"); el.textContent=message; el.className=`toast ${type}`; setTimeout(()=>el.classList.add("hidden"),4200); }
  function authMessage(message, type="info") { const el=$("auth-message"); el.textContent=message; el.className=`notice ${type}`; }
  function friendlyError(error) {
    const m = String(error?.message || error || "");
    console.error("[AutoSetu]", error);
    if (/rate limit/i.test(m)) return "Too many attempts. Please wait a little before trying again.";
    if (/invalid.*otp|otp.*invalid/i.test(m)) return "That code isn't correct. Check it and try again.";
    if (/expired/i.test(m)) return "That code has expired. Request a new OTP.";
    if (/row-level security|permission denied/i.test(m)) return "This action isn't allowed for this account. Check the database setup and account role.";
    if (/schema cache|profiles/i.test(m)) return "The profile database is not ready yet. Run the database SQL files in the README order.";
    if (/fetch|network/i.test(m)) return "Connection problem. Check your internet and Supabase configuration.";
    return "Something went wrong. Please try again. If it continues, check the browser console and Supabase logs.";
  }
  function requireClient() {
    if (!window.supabase || !cfg.SUPABASE_URL || cfg.SUPABASE_URL.includes("YOUR_") || !cfg.SUPABASE_ANON_KEY || cfg.SUPABASE_ANON_KEY.includes("YOUR_")) {
      toast("Add your Supabase URL and public anon/publishable key in config.js first.", "error"); return false;
    }
    if (!state.client) state.client = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
    return true;
  }
  let authMode = "login";
  function setAuthMode(mode) {
    authMode = mode;
    const signup = mode === "signup";
    $("auth-tab-login").className = `btn ${signup ? "btn-outline" : "btn-primary"}`;
    $("auth-tab-signup").className = `btn ${signup ? "btn-primary" : "btn-outline"}`;
    $("auth-title").textContent = signup ? "Create your AutoSetu account" : "Log in to AutoSetu";
    $("auth-subtitle").textContent = signup ? "Verify your email to activate your account." : "Use your email and password.";
    $("signup-fields").classList.toggle("hidden", !signup);
    $("signup-role-wrap").classList.toggle("hidden", !signup);
    $("auth-name").required = signup;
    $("auth-password").autocomplete = signup ? "new-password" : "current-password";
    $("auth-submit").textContent = signup ? "Create account" : "Log in";
    $("auth-message").classList.add("hidden");
  }
  async function submitEmailAuth(e) {
    e.preventDefault(); if (!requireClient()) return;
    const email = $("auth-email").value.trim().toLowerCase();
    const password = $("auth-password").value;
    const btn = $("auth-submit"); btn.disabled = true; btn.textContent = authMode === "signup" ? "Creating…" : "Signing in…";
    try {
      if (authMode === "signup") {
        const fullName = $("auth-name").value.trim();
        const role = $("auth-role").value;
        if (fullName.length < 2) throw new Error("Please enter your full name.");
        if (password.length < 8) throw new Error("Use a password with at least 8 characters.");
        const redirectTo = window.location.href.split("#")[0];
        const { data, error } = await state.client.auth.signUp({
          email, password,
          options: { emailRedirectTo: redirectTo, data: { full_name: fullName, requested_role: role } }
        });
        if (error) throw error;
        if (data.session) {
          await onSession(data.session);
          toast("Account created successfully.", "success");
        } else {
          authMessage("Account created. Open the verification email sent to " + email + ", then return here and log in. Check Spam/Junk if you don't see it.", "success");
        }
      } else {
        const { data, error } = await state.client.auth.signInWithPassword({ email, password });
        if (error) throw error;
        if (!data.session) throw new Error("Login did not create a session. Please try again.");
        await onSession(data.session);
        toast("Welcome back to AutoSetu.", "success");
      }
    } catch (err) {
      let message = err.message || friendlyError(err);
      if (/email not confirmed/i.test(message)) message = "Please verify your email first. Open the latest AutoSetu verification email, then try logging in.";
      else if (/already registered|already been registered/i.test(message)) message = "This email already has an account. Choose Log in instead.";
      authMessage(message, "error");
    } finally { btn.disabled = false; btn.textContent = authMode === "signup" ? "Create account" : "Log in"; }
  }
  let sessionRun = 0;
  async function onSession(session) {
    // Called after login, signup, email confirmation, and Supabase auth-state changes.
    // Ignore stale async profile loads when newer auth events arrive.
    const runId = ++sessionRun;
    clearRealtime();
    if (!session?.user) {
      state.user = null;
      state.profile = null;
      $("nav-login").classList.remove("hidden");
      $("nav-logout").classList.add("hidden");
      showView("landing-view");
      return;
    }

    state.user = session.user;
    $("nav-login").classList.add("hidden");
    $("nav-logout").classList.remove("hidden");

    try {
      const { data, error } = await state.client
        .from("profiles")
        .select("id,full_name,role,is_suspended")
        .eq("id", session.user.id)
        .maybeSingle();
      if (runId !== sessionRun) return;
      if (error) throw error;

      if (!data) {
        // The profile trigger may not have run (or the email was confirmed after a schema
        // change). Do not silently assign admin privileges; ask the user to complete profile.
        state.profile = null;
        $("profile-name").value = session.user.user_metadata?.full_name || "";
        const requestedRole = session.user.user_metadata?.requested_role;
        $("profile-role").value = requestedRole === "driver" ? "driver" : "passenger";
        showView("profile-view");
        return;
      }

      if (data.is_suspended) {
        await state.client.auth.signOut();
        state.user = null;
        state.profile = null;
        toast("This account is suspended. Please contact AutoSetu support.", "error");
        showView("landing-view");
        return;
      }

      state.profile = data;
      if (runId !== sessionRun) return;
      await renderDashboard();
    } catch (error) {
      if (runId !== sessionRun) return;
      console.error("[AutoSetu] Session/profile load failed:", error);
      state.profile = null;
      showView("profile-view");
      toast(friendlyError(error), "error");
    }
  }

  function clearRealtime() { state.realtime.forEach(ch => state.client?.removeChannel(ch)); state.realtime=[]; }
  function stopLocationWatch() { if(state.watchId!==null && navigator.geolocation){navigator.geolocation.clearWatch(state.watchId);state.watchId=null;} }
  function startLocationWatch() {
    if(!navigator.geolocation || state.watchId!==null) return;
    state.watchId=navigator.geolocation.watchPosition(async pos=>{
      const now=Date.now(); if(now-state.lastLocationSent<15000) return;
      state.lastLocationSent=now;
      const {error}=await state.client.rpc("update_driver_location",{p_latitude:pos.coords.latitude,p_longitude:pos.coords.longitude});
      if(error) console.warn("[AutoSetu] Driver location update:",error.message);
    },err=>console.warn("[AutoSetu] GPS update:",err.message),{enableHighAccuracy:true,maximumAge:10000,timeout:15000});
  }
  async function requestOtp(rideId,purpose) {
    try {
      const {data,error}=await state.client.rpc("request_ride_otp",{p_ride_id:rideId,p_purpose:purpose});
      if(error) throw error;
      window.alert(`Your ${purpose==='start'?'ride start':'ride completion'} code is: ${data}. It expires in 5 minutes. Share it only with your assigned driver.`);
      await renderDashboard();
    } catch(e){toast(friendlyError(e),"error");}
  }
  async function verifyOtp(rideId,purpose) {
    const code=window.prompt(`Enter the passenger's 6-digit ${purpose==='start'?'start':'completion'} code:`);
    if(code===null) return;
    try { const {error}=await state.client.rpc("verify_ride_otp",{p_ride_id:rideId,p_purpose:purpose,p_code:code.trim()}); if(error)throw error; toast(purpose==='start'?"Ride started.":"Ride completed.","success"); await renderDashboard(); }
    catch(e){toast(friendlyError(e),"error");}
  }
  async function cancelRide(rideId) { if(!confirm("Cancel this ride request?"))return; try{const {error}=await state.client.rpc("cancel_ride",{p_ride_id:rideId});if(error)throw error;toast("Ride cancelled.","success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function rateRide(rideId) { const raw=prompt("Rate your driver from 1 to 5 stars:","5"); if(raw===null)return; const rating=Number(raw); if(!Number.isInteger(rating)||rating<1||rating>5){toast("Enter a rating from 1 to 5.","error");return;} const review=prompt("Optional review:","")||""; try{const {error}=await state.client.rpc("submit_ride_review",{p_ride_id:rideId,p_rating:rating,p_review:review});if(error)throw error;toast("Thank you for your rating.","success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function createCarpool(e) { e.preventDefault(); const f=e.currentTarget; try{const {error}=await state.client.rpc("create_carpool",{p_pickup_location:f.elements.pickup.value.trim(),p_destination:f.elements.destination.value.trim(),p_departure_time:new Date(f.elements.departure.value).toISOString(),p_available_seats:Number(f.elements.seats.value),p_price_per_seat:Number(f.elements.cost.value||0)});if(error)throw error;toast("Carpool published.","success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function requestCarpool(carpoolId,seats=1) { try{const {error}=await state.client.rpc("request_carpool_seat",{p_carpool_id:carpoolId,p_seats:seats});if(error)throw error;toast("Seat request sent to the driver.","success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function respondCarpool(bookingId,decision) { try{const {error}=await state.client.rpc("respond_carpool_booking",{p_booking_id:bookingId,p_decision:decision});if(error)throw error;toast(decision==="confirmed"?"Seat request accepted.":"Request updated.","success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function closeCarpool(id) { if(!confirm("Cancel this carpool listing?"))return;try{const {error}=await state.client.rpc("driver_cancel_carpool",{p_carpool_id:id});if(error)throw error;toast("Carpool cancelled.","success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function adminSuspend(userId,suspended) { if(!confirm(`${suspended?"Suspend":"Restore"} this account?`))return; try{const {error}=await state.client.rpc("admin_set_user_suspension",{p_user_id:userId,p_suspended:suspended});if(error)throw error;toast(`Account ${suspended?"suspended":"restored"}.`,"success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function adminReport(reportId,status) { try{const {error}=await state.client.rpc("admin_update_report",{p_report_id:reportId,p_status:status});if(error)throw error;toast("Report status updated.","success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");} }
  async function saveProfile(e) {
    e.preventDefault(); if(!state.user)return;
    const name=$("profile-name").value.trim(), role=state.profile?.role || $("profile-role").value;
    if(name.length<2){toast("Please enter your name.","error");return;}
    const btn=e.submitter; if(btn){btn.disabled=true;btn.textContent="Saving…";}
    try {
      const {error}=await state.client.from("profiles").upsert({id:state.user.id,full_name:name,role},{onConflict:"id"});
      if(error)throw error;
      if(role==="driver") {
        const {error:driverError}=await state.client.from("drivers").upsert({user_id:state.user.id,vehicle_type:"auto",verification_status:"pending",is_online:false},{onConflict:"user_id"});
        if(driverError)throw driverError;
      }
      await loadProfile(); await renderDashboard(); toast("Profile saved.","success");
    } catch(err){toast(friendlyError(err),"error");}
    finally {if(btn){btn.disabled=false;btn.textContent="Save and continue";}}
  }
  function navToAuth(role) {
    showView("auth-view");
    setAuthMode("login");
    if (role === "driver") { authMessage("Driver? Log in or create an account, then select Driver during registration. New drivers need admin approval.", "info"); }
  }
  async function logout() { if(!state.client)return; stopLocationWatch(); clearRealtime(); const {error}=await state.client.auth.signOut(); if(error)toast(friendlyError(error),"error"); else {state.user=null;state.profile=null;showView("landing-view");toast("You are signed out.","success");} }
  function getLocation() {
    return new Promise((resolve,reject)=>{
      if(!navigator.geolocation)return reject(new Error("This browser does not support location."));
      navigator.geolocation.getCurrentPosition(pos=>resolve({lat:pos.coords.latitude,lng:pos.coords.longitude,accuracy:pos.coords.accuracy}),err=>reject(new Error(err.code===1?"Location permission was denied. Enter pickup manually.":"Could not get your location. Enter pickup manually.")),{enableHighAccuracy:true,timeout:12000,maximumAge:30000});
    });
  }
  async function useCurrentLocation() {
    const btn=$("use-location"); if(btn){btn.disabled=true;btn.textContent="Finding location…";}
    try {
      const loc=await getLocation();state.location=loc;
      $("pickup-lat").value=loc.lat;$("pickup-lng").value=loc.lng;
      $("pickup").value=`GPS location (±${Math.round(loc.accuracy)} m)`;
      toast("Pickup location detected.","success");
    } catch(e){toast(e.message,"error");}
    finally {if(btn){btn.disabled=false;btn.textContent="Use my current location";}}
  }
  function mapsUrl(lat,lng,dest) {
    const base="https://www.google.com/maps/dir/?api=1";
    return `${base}&origin=${encodeURIComponent(`${lat},${lng}`)}&destination=${encodeURIComponent(dest||`${lat},${lng}`)}`;
  }
  async function initPassengerMap(ride) {
    const node=$("passenger-live-map"); if(!node || !window.L || !ride) return;
    let driverPoint=null;
    if(ride.driver_id){const {data}=await state.client.from("drivers").select("latitude,longitude").eq("user_id",ride.driver_id).maybeSingle();if(data&&data.latitude!==null&&data.longitude!==null)driverPoint=[data.latitude,data.longitude];}
    const pickup=[Number(ride.pickup_latitude),Number(ride.pickup_longitude)];
    const center=driverPoint||pickup;
    if(!Number.isFinite(center[0])||!Number.isFinite(center[1])||(center[0]===0&&center[1]===0)){node.innerHTML='<p class="muted">Waiting for valid GPS coordinates from the driver.</p>';return;}
    const map=window.L.map(node).setView(center,14);
    window.L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",{maxZoom:19,attribution:"© OpenStreetMap contributors"}).addTo(map);
    if(Number.isFinite(pickup[0])&&Number.isFinite(pickup[1])&&(pickup[0]!==0||pickup[1]!==0))window.L.marker(pickup).addTo(map).bindPopup("Pickup location");
    if(driverPoint)window.L.marker(driverPoint).addTo(map).bindPopup("Driver's latest shared location");
    setTimeout(()=>map.invalidateSize(),150);
  }
  async function bookRide(e) {
    e.preventDefault();
    const pickup=$("pickup").value.trim(), destination=$("destination").value.trim(), vehicle=$("vehicle-type").value;
    const latRaw=$("pickup-lat").value,lngRaw=$("pickup-lng").value;
    const lat=Number(latRaw),lng=Number(lngRaw);
    if(!pickup||!destination){toast("Enter both pickup and destination.","error");return;}
    if(!latRaw||!lngRaw||!Number.isFinite(lat)||!Number.isFinite(lng)||lat < -90||lat > 90||lng < -180||lng > 180||(lat===0&&lng===0)){toast("Use the GPS button to attach a valid pickup location before requesting a ride.","error");return;}
    const btn=e.submitter;if(btn){btn.disabled=true;btn.textContent="Requesting…";}
    try {
      const {data,error}=await state.client.rpc("request_ride",{p_pickup_location:pickup,p_destination:destination,p_pickup_latitude:lat,p_pickup_longitude:lng,p_destination_latitude:null,p_destination_longitude:null,p_vehicle_type:vehicle});
      if(error)throw error;
      toast("Ride request created. Waiting for an eligible driver.","success");
      await renderDashboard();
    }catch(err){toast(friendlyError(err),"error");}
    finally{if(btn){btn.disabled=false;btn.textContent="Request ride";}}
  }
  async function toggleOnline(isOnline) {
    try {
      if(!isOnline){const {data:active,error:activeError}=await state.client.from("rides").select("id").eq("driver_id",state.user.id).in("status",["accepted","arrived","started"]).limit(1);if(activeError)throw activeError;if(active?.length){toast("Finish or resolve your active ride before going offline.","error");return;}}
      let loc=null;if(isOnline)loc=await getLocation();
      const {error}=await state.client.rpc("set_driver_availability",{p_online:isOnline,p_latitude:loc?.lat??null,p_longitude:loc?.lng??null});
      if(error)throw error;
      if(isOnline)startLocationWatch();else stopLocationWatch(); toast(isOnline?"You are online. Keep this page open for GPS updates.":"You are offline.","success");await renderDashboard();
    }catch(e){toast(e.message?.includes("Location")?e.message:friendlyError(e),"error");}
  }
  async function acceptRide(rideId) {
    try{const {error}=await state.client.rpc("accept_ride",{p_ride_id:rideId});if(error)throw error;toast("Ride accepted.","success");await renderDashboard();}
    catch(e){toast(friendlyError(e),"error");}
  }
  async function updateRideStatus(rideId,status) {
    try{const {error}=await state.client.rpc("driver_update_ride_status",{p_ride_id:rideId,p_status:status});if(error)throw error;toast("Ride status updated.","success");await renderDashboard();}
    catch(e){toast(friendlyError(e),"error");}
  }
  async function getMyRides() {
    const {data,error}=await state.client.from("rides").select("id,passenger_id,driver_id,pickup_location,destination,pickup_latitude,pickup_longitude,vehicle_type,status,requested_at,accepted_at,arrived_at,started_at,completed_at,passenger:profiles!rides_passenger_id_fkey(full_name),driver:profiles!rides_driver_id_fkey(full_name)").or(`passenger_id.eq.${state.user.id},driver_id.eq.${state.user.id}`).order("requested_at",{ascending:false}).limit(20);
    if(error)throw error;return data||[];
  }
  async function renderDashboard() {
    if(!state.profile){showView("profile-view");return;}
    const role=state.profile.role;
    $("welcome-title").textContent=`Hello, ${state.profile.full_name.split(" ")[0]}`;
    $("welcome-subtitle").textContent=role==="driver"?"Keep it simple. Your next ride is here.":role==="admin"?"Platform overview and safety operations.":"Where would you like to go today?";
    $("role-kicker").textContent=role==="driver"?"DRIVER MODE":role==="admin"?"ADMINISTRATION":"PASSENGER DASHBOARD";
    $("role-pill").textContent=role.charAt(0).toUpperCase()+role.slice(1);
    showView("dashboard-view");
    const root=$("dashboard-content");root.innerHTML=`<div class="loading-card">Loading your dashboard…</div>`;
    try{
      if(role==="passenger") await renderPassenger(root);
      else if(role==="driver") await renderDriver(root);
      else if(role==="admin") await renderAdmin(root);
      else root.innerHTML='<div class="card"><h3>Account role not recognized</h3><p>Contact support.</p></div>';
      clearRealtime();
      const channel=state.client.channel(`autosetu-${state.user.id}`)
        .on("postgres_changes",{event:"*",schema:"public",table:"rides"},()=>renderDashboard())
        .on("postgres_changes",{event:"*",schema:"public",table:"carpools"},()=>renderDashboard())
        .on("postgres_changes",{event:"*",schema:"public",table:"carpool_bookings"},()=>renderDashboard())
        .on("postgres_changes",{event:"*",schema:"public",table:"drivers"},()=>{if(state.profile?.role==="passenger")renderDashboard();})
        .on("postgres_changes",{event:"*",schema:"public",table:"ride_reports"},()=>{if(state.profile?.role==="admin")renderDashboard();})
        .subscribe();
      state.realtime.push(channel);
    }catch(e){root.innerHTML=`<div class="notice error">${escapeHtml(friendlyError(e))}</div>`;}
  }
  function rideCard(r, mineRole) {
    const status=String(r.status||"requested").replaceAll("_"," ");
    const person=mineRole==="passenger"?(r.driver?.full_name||"Waiting for driver"):(r.passenger?.full_name||"Passenger");
    const actions=[];
    if(mineRole==="driver"&&r.status==="requested")actions.push(`<button class="btn btn-primary" data-action="accept" data-id="${r.id}">✓ ACCEPT RIDE</button>`);
    if(mineRole==="driver"&&r.status==="accepted")actions.push(`<button class="btn btn-primary" data-action="arrived" data-id="${r.id}">I HAVE ARRIVED</button>`);
    if(mineRole==="driver"&&r.status==="arrived")actions.push(`<button class="btn btn-primary" data-action="start-otp" data-id="${r.id}">VERIFY START CODE</button>`);
    if(mineRole==="driver"&&r.status==="started")actions.push(`<button class="btn btn-primary" data-action="finish-otp" data-id="${r.id}">VERIFY COMPLETION CODE</button>`);
    if(mineRole==="passenger"&&["requested","accepted"].includes(r.status))actions.push(`<button class="btn btn-outline" data-action="cancel-ride" data-id="${r.id}">Cancel ride</button>`);
    if(mineRole==="passenger"&&r.status==="arrived")actions.push(`<button class="btn btn-primary" data-action="start-code" data-id="${r.id}">Get start code</button>`);
    if(mineRole==="passenger"&&r.status==="started")actions.push(`<button class="btn btn-primary" data-action="finish-code" data-id="${r.id}">Get completion code</button>`);
    if(mineRole==="passenger"&&r.status==="completed")actions.push(`<button class="btn btn-outline" data-action="rate" data-id="${r.id}">Rate driver</button>`);
    const hasGps=Number.isFinite(Number(r.pickup_latitude))&&Number.isFinite(Number(r.pickup_longitude))&&(Number(r.pickup_latitude)!==0||Number(r.pickup_longitude)!==0);
    const nav=hasGps?`<a class="btn btn-outline" target="_blank" rel="noopener" href="${mapsUrl(r.pickup_latitude,r.pickup_longitude,r.pickup_location)}">Navigate to pickup ↗</a>`:"";
    return `<article class="ride-card"><div class="ride-top"><span class="status status-${escapeHtml(r.status)}">${escapeHtml(status)}</span><small>${new Date(r.requested_at).toLocaleString()}</small></div><h3>${escapeHtml(r.pickup_location)} <span class="arrow">→</span> ${escapeHtml(r.destination)}</h3><div class="ride-meta"><span>🚕 ${escapeHtml(r.vehicle_type)}</span><span>👤 ${escapeHtml(person)}</span></div><div class="ride-actions">${actions.join("")}${nav}</div><small class="muted">Ride ID: ${escapeHtml(r.id)}</small></article>`;
  }
  async function renderPassenger(root) {
    const rides=await getMyRides();
    const {data:carpools,error:ce}=await state.client.from("carpools").select("id,driver_id,pickup_location,destination,departure_time,seats_remaining,price_per_seat,status,driver:profiles!carpools_driver_id_fkey(full_name)").eq("status","open").gt("departure_time",new Date().toISOString()).order("departure_time").limit(30);
    if(ce)throw ce;
    const {data:myBookings,error:be}=await state.client.from("carpool_bookings").select("id,status,seats_booked,carpool:carpools!carpool_bookings_carpool_id_fkey(pickup_location,destination,departure_time,driver_id)").eq("passenger_id",state.user.id).order("created_at",{ascending:false}).limit(20);
    if(be)throw be;
    const activeRide=rides.find(r=>["accepted","arrived","started"].includes(r.status)&&r.driver_id);
    root.innerHTML=`
      <div class="dashboard-grid">
        <section class="card booking-card"><div class="card-heading"><span class="big-icon">⌖</span><div><h2>Book a local ride</h2><p>Choose where your journey starts and ends.</p></div></div>
          <form id="booking-form" class="stack-form">
            <label>Pickup location<input id="pickup" required placeholder="Enter pickup or use GPS"></label>
            <button type="button" class="btn btn-outline" id="use-location">⌖ Use my current location</button>
            <input type="hidden" id="pickup-lat"><input type="hidden" id="pickup-lng">
            <label>Destination<input id="destination" required placeholder="Where are you going?"></label>
            <label>Vehicle type<select id="vehicle-type"><option value="auto">Auto-rickshaw</option><option value="taxi">Taxi</option></select></label>
            <button class="btn btn-primary btn-large full" type="submit">Request ride →</button>
          </form>
        </section>
        <section class="card"><div class="card-heading"><span class="big-icon">🛡</span><div><h2>Safety centre</h2><p>Keep help within reach.</p></div></div><div class="emergency-box"><small>India emergency number</small><strong>112</strong><a href="tel:112" class="btn btn-dark">Call 112</a></div><button class="btn btn-outline full" id="report-help">Report a ride concern</button></section>
      </div>
      ${activeRide?`<section class="section-block card"><h2>Live ride map</h2><p class="muted small">Shows the driver's latest shared GPS position while their app is online.</p><div id="passenger-live-map" class="live-map"></div></section>`:""}
      <section class="section-block"><div class="section-title-row"><h2>Your recent rides</h2><span class="muted small">${rides.length} shown</span></div>${rides.length?rides.map(r=>rideCard(r,"passenger")).join(""):'<div class="empty-state"><span>🚕</span><h3>Your journeys will appear here</h3><p>Book a ride to get started.</p></div>'}</section>
      <section class="section-block"><div class="section-title-row"><h2>🚗 Find a carpool</h2><span class="muted small">Cost-sharing journeys</span></div>${carpools?.length?carpools.map(c=>`<article class="ride-card"><div class="ride-top"><span class="status">${c.seats_remaining} seats left</span><small>${new Date(c.departure_time).toLocaleString()}</small></div><h3>${escapeHtml(c.pickup_location)} → ${escapeHtml(c.destination)}</h3><p class="muted">Driver: ${escapeHtml(c.driver?.full_name||"AutoSetu driver")} · ₹${Number(c.price_per_seat).toFixed(0)} per seat</p><button class="btn btn-primary" data-carpool-request="${c.id}">Request 1 seat</button></article>`).join(""):'<div class="empty-state"><h3>No matching carpools listed</h3><p>New driver journeys will appear here.</p></div>'}</section>
      <section class="section-block"><h2>Your carpool requests</h2>${myBookings?.length?myBookings.map(b=>`<article class="ride-card"><span class="status">${escapeHtml(b.status)}</span><h3>${escapeHtml(b.carpool?.pickup_location||"Journey")} → ${escapeHtml(b.carpool?.destination||"")}</h3><p class="muted">${b.seats_booked} seat(s) · ${b.carpool?.departure_time?new Date(b.carpool.departure_time).toLocaleString():""}</p>${b.status==="requested"?`<button class="btn btn-outline" data-carpool-cancel="${b.id}">Withdraw request</button>`:""}</article>`).join(""):'<p class="muted">No carpool requests yet.</p>'}</section>`;
    if(activeRide)initPassengerMap(activeRide);
    $("booking-form").addEventListener("submit",bookRide);$("use-location").addEventListener("click",useCurrentLocation);
    $("report-help").addEventListener("click",()=>showReportForm(root));
    root.querySelectorAll('[data-action="cancel-ride"]').forEach(b=>b.addEventListener("click",()=>cancelRide(b.dataset.id)));
    root.querySelectorAll('[data-action="start-code"]').forEach(b=>b.addEventListener("click",()=>requestOtp(b.dataset.id,"start")));
    root.querySelectorAll('[data-action="finish-code"]').forEach(b=>b.addEventListener("click",()=>requestOtp(b.dataset.id,"finish")));
    root.querySelectorAll('[data-action="rate"]').forEach(b=>b.addEventListener("click",()=>rateRide(b.dataset.id)));
    root.querySelectorAll('[data-carpool-request]').forEach(b=>b.addEventListener("click",()=>requestCarpool(b.dataset.carpoolRequest,1)));
    root.querySelectorAll('[data-carpool-cancel]').forEach(b=>b.addEventListener("click",()=>respondCarpool(b.dataset.carpoolCancel,"cancelled")));
  }
  async function renderDriver(root) {
    const {data:driver,error}=await state.client.from("drivers").select("verification_status,is_online,vehicle_type,vehicle_number,rating,total_rides").eq("user_id",state.user.id).maybeSingle();
    if(error)throw error;
    if(!driver){root.innerHTML='<div class="card"><h2>Finish driver setup</h2><p>Your driver record is not set up yet. Contact support to enable driver registration.</p></div>';return;}
    const {data:rides,error:rideError}=await state.client.from("rides").select("id,passenger_id,driver_id,pickup_location,destination,pickup_latitude,pickup_longitude,vehicle_type,status,requested_at,passenger:profiles!rides_passenger_id_fkey(full_name)").or(`driver_id.eq.${state.user.id},and(driver_id.is.null,status.eq.requested,vehicle_type.eq.${driver.vehicle_type})`).order("requested_at",{ascending:false}).limit(30);
    if(rideError)throw rideError;
    const {data:myCarpools,error:carError}=await state.client.from("carpools").select("id,pickup_location,destination,departure_time,seats_remaining,status").eq("driver_id",state.user.id).order("departure_time",{ascending:false}).limit(20);if(carError)throw carError;
    const ids=(myCarpools||[]).map(c=>c.id);let bookings=[];if(ids.length){const q=await state.client.from("carpool_bookings").select("id,carpool_id,passenger_id,seats_booked,status,passenger:profiles!carpool_bookings_passenger_id_fkey(full_name)").in("carpool_id",ids).eq("status","requested");if(q.error)throw q.error;bookings=q.data||[];}
    root.innerHTML=`
      <div class="driver-status-card ${driver.is_online?"is-online":""}"><div><span class="eyebrow">YOUR STATUS</span><h2>${driver.is_online?"🟢 You're online":"⚪ You're offline"}</h2><p>${driver.is_online?"Keep this screen open for GPS updates and new requests.":"Go online when you're ready to drive."}</p></div><button class="btn ${driver.is_online?"btn-light":"btn-primary"} btn-large" id="availability">${driver.is_online?"GO OFFLINE / ऑफलाइन हों":"GO ONLINE / ऑनलाइन हों"}</button></div>
      ${driver.verification_status!=="approved"?`<div class="notice warning"><b>Approval required.</b> Your status is <b>${escapeHtml(driver.verification_status)}</b>. You cannot accept rides until an administrator approves your documents.</div>`:""}
      <div class="driver-stats"><div><small>Vehicle</small><b>${escapeHtml(driver.vehicle_type||"Not set")}</b></div><div><small>Rating</small><b>${Number(driver.rating||0).toFixed(1)} ★</b></div><div><small>Completed rides</small><b>${driver.total_rides||0}</b></div></div>
      <section class="section-block"><div class="section-title-row"><h2>Ride requests & active rides</h2><span class="muted small">${rides.length} shown</span></div>${rides.length?rides.map(r=>rideCard(r,"driver")).join(""):'<div class="empty-state"><span>🛺</span><h3>No ride requests yet</h3><p>Stay online to receive eligible requests.</p></div>'}</section>
      <section class="section-block card"><h2>Publish a carpool journey</h2><form id="carpool-form" class="stack-form"><label>Starting location<input name="pickup" required placeholder="e.g. Panipat"></label><label>Destination<input name="destination" required placeholder="e.g. Delhi"></label><label>Departure date and time<input name="departure" type="datetime-local" required min="${new Date(Date.now()+60000-new Date().getTimezoneOffset()*60000).toISOString().slice(0,16)}"></label><label>Available seats<input name="seats" type="number" min="1" max="12" value="3" required></label><label>Suggested contribution per seat (₹)<input name="cost" type="number" min="0" step="1" value="0"></label><button class="btn btn-primary">Publish carpool</button></form></section>
      <section class="section-block"><h2>Your carpool listings</h2>${myCarpools.length?myCarpools.map(c=>`<article class="ride-card"><span class="status">${escapeHtml(c.status)} · ${c.seats_remaining} seats left</span><h3>${escapeHtml(c.pickup_location)} → ${escapeHtml(c.destination)}</h3><small class="muted">${new Date(c.departure_time).toLocaleString()}</small><div class="ride-actions"><button class="btn btn-outline" data-carpool-close="${c.id}">Cancel listing</button></div></article>`).join(""):'<p class="muted">You have not published a carpool yet.</p>'}</section>
      <section class="section-block"><h2>Pending seat requests</h2>${bookings.length?bookings.map(b=>`<article class="ride-card"><h3>${escapeHtml(b.passenger?.full_name||"Passenger")} · ${b.seats_booked} seat(s)</h3><div class="ride-actions"><button class="btn btn-primary" data-booking-accept="${b.id}">Accept</button><button class="btn btn-outline" data-booking-reject="${b.id}">Reject</button></div></article>`).join(""):'<p class="muted">No pending carpool requests.</p>'}</section>
      <section class="card"><h2>Driver help / मदद</h2><p>Drive safely. Confirm pickup details before starting. Keep location permission enabled while online.</p><a class="btn btn-outline" href="tel:112">Emergency: call 112</a></section>`;
    $("availability").addEventListener("click",()=>toggleOnline(!driver.is_online));
    if(driver.is_online)startLocationWatch();else stopLocationWatch();
    root.querySelectorAll('[data-action="accept"]').forEach(b=>b.addEventListener("click",()=>acceptRide(b.dataset.id)));
    root.querySelectorAll('[data-action="arrived"]').forEach(b=>b.addEventListener("click",async()=>{try{const loc=await getLocation();const upd=await state.client.rpc("update_driver_location",{p_latitude:loc.lat,p_longitude:loc.lng});if(upd.error)throw upd.error;await updateRideStatus(b.dataset.id,"arrived");}catch(e){toast(e.message||friendlyError(e),"error");}}));
    root.querySelectorAll('[data-action="start-otp"]').forEach(b=>b.addEventListener("click",()=>verifyOtp(b.dataset.id,"start")));
    root.querySelectorAll('[data-action="finish-otp"]').forEach(b=>b.addEventListener("click",()=>verifyOtp(b.dataset.id,"finish")));
    $("carpool-form").addEventListener("submit",createCarpool);
    root.querySelectorAll('[data-booking-accept]').forEach(b=>b.addEventListener("click",()=>respondCarpool(b.dataset.bookingAccept,"confirmed")));
    root.querySelectorAll('[data-booking-reject]').forEach(b=>b.addEventListener("click",()=>respondCarpool(b.dataset.bookingReject,"cancelled")));
    root.querySelectorAll('[data-carpool-close]').forEach(b=>b.addEventListener("click",()=>closeCarpool(b.dataset.carpoolClose)));
  }
  async function renderAdmin(root) {
    const {data:stats,error}=await state.client.rpc("admin_dashboard_stats");if(error)throw error;
    const [{data:pending,error:pe},{data:users,error:ue},{data:rides,error:re},{data:reports,error:rp},{data:carpools,error:ca}]=await Promise.all([
      state.client.from("drivers").select("user_id,vehicle_type,vehicle_number,verification_status,profiles:user_id(full_name)").eq("verification_status","pending").limit(50),
      state.client.from("profiles").select("id,full_name,role,is_suspended,created_at").order("created_at",{ascending:false}).limit(100),
      state.client.from("rides").select("id,pickup_location,destination,status,requested_at,passenger:profiles!rides_passenger_id_fkey(full_name),driver:profiles!rides_driver_id_fkey(full_name)").order("requested_at",{ascending:false}).limit(40),
      state.client.from("ride_reports").select("id,ride_id,category,description,status,created_at,reporter:profiles!ride_reports_reported_by_fkey(full_name)").order("created_at",{ascending:false}).limit(40),
      state.client.from("carpools").select("id,pickup_location,destination,departure_time,seats_remaining,status,driver:profiles!carpools_driver_id_fkey(full_name)").order("departure_time",{ascending:false}).limit(40)
    ]);if(pe)throw pe;if(ue)throw ue;if(re)throw re;if(rp)throw rp;if(ca)throw ca;
    root.innerHTML=`<div class="stats-grid"><div class="stat-card"><small>Passengers</small><strong>${stats.passengers}</strong></div><div class="stat-card"><small>Drivers</small><strong>${stats.drivers}</strong></div><div class="stat-card"><small>Total rides</small><strong>${stats.rides}</strong></div><div class="stat-card"><small>Completed</small><strong>${stats.completed}</strong></div><div class="stat-card"><small>Cancelled</small><strong>${stats.cancelled}</strong></div><div class="stat-card accent-stat"><small>Pending approvals</small><strong>${stats.pending_drivers}</strong></div></div>
      <section class="section-block"><div class="section-title-row"><h2>Driver verification</h2><span class="muted small">Review documents independently</span></div>${pending.length?pending.map(d=>`<article class="ride-card"><h3>${escapeHtml(d.profiles?.full_name||"Driver")}</h3><p>${escapeHtml(d.vehicle_type||"Vehicle not set")} · ${escapeHtml(d.vehicle_number||"Registration not supplied")}</p><span class="status">pending</span><div class="ride-actions"><button class="btn btn-primary" data-approve="${d.user_id}">Approve</button><button class="btn btn-outline" data-reject="${d.user_id}">Reject</button></div></article>`).join(""):'<div class="empty-state">No pending driver approvals.</div>'}</section>
      <section class="section-block"><h2>Platform users</h2>${users.map(u=>{const action=u.role!=="admin"?('<button class="btn '+(u.is_suspended?'btn-primary':'btn-outline')+'" data-user-toggle="'+u.id+'" data-suspended="'+(u.is_suspended?'false':'true')+'">'+(u.is_suspended?'Restore account':'Suspend account')+'</button>'):'<small class="muted">Administrator account</small>';return '<article class="ride-card"><div class="ride-top"><span class="status">'+escapeHtml(u.role)+'</span><small>'+(u.is_suspended?'Suspended':'Active')+'</small></div><h3>'+escapeHtml(u.full_name||'New user')+'</h3><p class="muted">'+escapeHtml(u.id)+'</p>'+action+'</article>';}).join("")}</section>
      <section class="section-block"><h2>Ride monitoring</h2>${rides.length?rides.map(r=>`<article class="ride-card"><span class="status">${escapeHtml(r.status)}</span><h3>${escapeHtml(r.pickup_location)} → ${escapeHtml(r.destination)}</h3><p class="muted">Passenger: ${escapeHtml(r.passenger?.full_name||"—")} · Driver: ${escapeHtml(r.driver?.full_name||"Unassigned")}</p><small class="muted">${new Date(r.requested_at).toLocaleString()} · ${r.id}</small></article>`).join(""):'<p class="muted">No rides recorded.</p>'}</section>
      <section class="section-block"><h2>Carpool monitoring</h2>${carpools.length?carpools.map(c=>`<article class="ride-card"><span class="status">${escapeHtml(c.status)} · ${c.seats_remaining} seats</span><h3>${escapeHtml(c.pickup_location)} → ${escapeHtml(c.destination)}</h3><p class="muted">Driver: ${escapeHtml(c.driver?.full_name||"Unknown")} · ${new Date(c.departure_time).toLocaleString()}</p></article>`).join(""):'<p class="muted">No carpools listed.</p>'}</section>
      <section class="section-block"><h2>Safety reports</h2>${reports.length?reports.map(r=>`<article class="ride-card"><div class="ride-top"><span class="status">${escapeHtml(r.status)}</span><small>${escapeHtml(r.category)}</small></div><p>${escapeHtml(r.description)}</p><small class="muted">Reported by ${escapeHtml(r.reporter?.full_name||"User")} · Ride ${escapeHtml(r.ride_id)}</small><div class="ride-actions"><button class="btn btn-outline" data-report-status="${r.id}" data-status="reviewing">Review</button><button class="btn btn-primary" data-report-status="${r.id}" data-status="resolved">Resolve</button><button class="btn btn-outline" data-report-status="${r.id}" data-status="dismissed">Dismiss</button></div></article>`).join(""):'<p class="muted">No reports submitted.</p>'}</section>
      <p class="muted small">Admin actions are executed by protected database functions. Public signup cannot create administrator accounts.</p>`;
    root.querySelectorAll("[data-approve]").forEach(b=>b.addEventListener("click",()=>adminVerify(b.dataset.approve,"approved")));
    root.querySelectorAll("[data-reject]").forEach(b=>b.addEventListener("click",()=>adminVerify(b.dataset.reject,"rejected")));
    root.querySelectorAll("[data-user-toggle]").forEach(b=>b.addEventListener("click",()=>adminSuspend(b.dataset.userToggle,b.dataset.suspended==="true")));
    root.querySelectorAll("[data-report-status]").forEach(b=>b.addEventListener("click",()=>adminReport(b.dataset.reportStatus,b.dataset.status)));
  }
  async function adminVerify(userId,status){try{const {error}=await state.client.rpc("admin_set_driver_verification",{p_user_id:userId,p_status:status});if(error)throw error;toast(`Driver ${status}.`,"success");await renderDashboard();}catch(e){toast(friendlyError(e),"error");}}
  function showReportForm(root) {
    const box=document.createElement("div");box.className="card report-form";box.innerHTML=`<h2>Report a safety concern</h2><form id="report-form" class="stack-form"><label>Ride ID (from ride details)<input id="report-ride-id" placeholder="Ride UUID" required></label><label>Category<select id="report-category"><option value="safety">Safety</option><option value="conduct">Conduct</option><option value="payment">Payment</option><option value="other">Other</option></select></label><label>What happened?<textarea id="report-description" required maxlength="2000" rows="3"></textarea></label><button class="btn btn-primary">Submit report</button></form>`;
    root.prepend(box);$("report-form").addEventListener("submit",async e=>{e.preventDefault();try{const {error}=await state.client.from("ride_reports").insert({ride_id:$("report-ride-id").value.trim(),reported_by:state.user.id,category:$("report-category").value,description:$("report-description").value.trim()});if(error)throw error;toast("Report submitted. Thank you for letting us know.","success");box.remove();}catch(err){toast(friendlyError(err),"error");}});
  }
  async function init() {
    $("year").textContent=new Date().getFullYear();
    $("nav-login").addEventListener("click",()=>navToAuth("passenger"));
    $("nav-logout").addEventListener("click",logout);
    $("hero-book").addEventListener("click",()=>navToAuth("passenger"));
    $("hero-drive").addEventListener("click",()=>navToAuth("driver"));
    $("auth-back").addEventListener("click",()=>showView("landing-view"));
    setAuthMode("login");
    $("email-auth-form").addEventListener("submit",submitEmailAuth);
    $("auth-tab-login").addEventListener("click",()=>setAuthMode("login"));
    $("auth-tab-signup").addEventListener("click",()=>setAuthMode("signup"));
    $("profile-form").addEventListener("submit",saveProfile);
    if("serviceWorker" in navigator && location.protocol.startsWith("https")) navigator.serviceWorker.register("./sw.js").catch(()=>{});
    if(!requireClient())return;
    state.client.auth.onAuthStateChange((_event, session)=>{setTimeout(()=>onSession(session),0);});
    const {data:{session}}=await state.client.auth.getSession();
    await onSession(session);
  }
  document.addEventListener("DOMContentLoaded",init);
})();
