-- Disposable database only. Fixtures and checks roll back completely.
begin;
set local time zone 'Pacific/Kiritimati';

do $$
declare
  v_now timestamptz := now() + interval '10 seconds';
  v_time timestamptz := now();
  v_start timestamptz := (((now() at time zone 'UTC')::date - 6)::timestamp at time zone 'UTC');
  v_a uuid := 'a1111111-1111-4111-8111-111111111111';
  v_b uuid := 'b1111111-1111-4111-8111-111111111111';
  v_c uuid := 'c1111111-1111-4111-8111-111111111111';
  v_d uuid := 'd1111111-1111-4111-8111-111111111111';
  v_e uuid := 'e1111111-1111-4111-8111-111111111111';
  v_session uuid := 'f1111111-1111-4111-8111-111111111111';
  v_event jsonb;
  v_second jsonb;
  v_data jsonb;
  v_outcomes jsonb;
  v_r1 uuid := '11111111-2222-4222-8222-111111111111';
  v_r2 uuid := '22222222-2222-4222-8222-111111111111';
  v_r3 uuid := '33333333-2222-4222-8222-111111111111';
  v_r4 uuid := '44444444-2222-4222-8222-111111111111';
  v_r5 uuid := '55555555-2222-4222-8222-111111111111';
  v_r6 uuid := '66666666-2222-4222-8222-111111111111';
  v_r7 uuid := '77777777-2222-4222-8222-111111111111';
  v_r8 uuid := '88888888-2222-4222-8222-111111111111';
begin
  assert (select relrowsecurity from pg_class where oid = 'public.analytics_country_observations'::regclass), 'country observations RLS';
  assert not has_table_privilege('anon', 'public.analytics_country_observations', 'SELECT'), 'no public country reads';
  assert not has_table_privilege('authenticated', 'public.analytics_country_observations', 'INSERT'), 'no client country writes';
  assert not has_function_privilege('anon', 'public.analytics_ingest(jsonb,text)', 'EXECUTE'), 'no public country RPC';
  assert has_function_privilege('service_role', 'public.analytics_ingest(jsonb,text)', 'EXECUTE'), 'collector country RPC';
  assert not (select prosecdef from pg_proc where oid = 'public.analytics_dashboard(integer,timestamptz)'::regprocedure), 'dashboard remains invoker';
  assert not exists(select 1 from information_schema.columns where table_schema='public' and table_name like 'analytics_%' and column_name in ('ip','ip_address','city','latitude','longitude','email','auth_user_id')), 'no identifying/geographic detail columns';

  v_data := public.analytics_dashboard(7, v_now);
  assert v_data->'countries' = '[]'::jsonb, 'empty countries';
  assert v_data #>> '{coverage,semantic_features_available}' = 'false', 'empty instrumentation is not measured zero';
  assert v_data #>> '{coverage,first_event_at}' is null, 'no fabricated first activity';
  assert v_data #>> '{ai_outcomes,started}' = '0', 'empty AI cohort';

  v_event := jsonb_build_object('id', 'a0000000-0000-4000-8000-000000000001', 'installation_id', v_a,
    'session_id', v_session, 'occurred_at', v_time, 'name', 'app_active', 'properties', jsonb_build_object('platform','macOS','schema_version',2));
  assert public.analytics_ingest(jsonb_build_array(v_event), 'US')->>'stored' = '1', 'store v2 event and observation';
  assert public.analytics_ingest(jsonb_build_array(v_event), 'NG')->>'stored' = '0', 'retry does not reassign country';
  assert (select count(*) from public.analytics_country_observations) = 1, 'retry has no new observation';
  assert (select country_code from public.analytics_country_observations) = 'US', 'original observation immutable';
  begin
    perform public.analytics_ingest(jsonb_build_array(v_event), 'ZZ');
    raise exception 'Expected invalid country rejection';
  exception when raise_exception then
    assert sqlerrm = 'Invalid country observation', 'assigned country codes only';
  end;
  -- A delayed event has an observation at NOW, not at its historical event time.
  v_second := jsonb_set(jsonb_set(jsonb_set(v_event,'{id}','"a0000000-0000-4000-8000-000000000002"'),'{name}','"note_created"'),'{occurred_at}',to_jsonb(v_time - interval '2 days'));
  assert public.analytics_ingest(jsonb_build_array(v_second), 'NG')->>'stored' = '1', 'next country observation';
  assert (select observed_at > v_time - interval '1 minute' from public.analytics_country_observations where event_id = 'a0000000-0000-4000-8000-000000000002'), 'upload country is not historical event location';
  update public.analytics_country_observations set observed_at = v_time - interval '1 minute' where event_id = 'a0000000-0000-4000-8000-000000000001';
  -- Missing geo on the latest upload remains Unknown rather than carrying a
  -- potentially stale country forward. Legacy clients still use one argument.
  v_event := jsonb_set(jsonb_set(v_event,'{installation_id}',to_jsonb(v_b)),'{id}','"b0000000-0000-4000-8000-000000000001"');
  v_event := jsonb_set(v_event,'{properties}','{"platform":"macOS"}');
  perform public.analytics_ingest(jsonb_build_array(v_event), 'US');
  v_event := jsonb_set(jsonb_set(v_event,'{id}','"b0000000-0000-4000-8000-000000000002"'),'{name}','"note_saved"');
  perform public.analytics_ingest(jsonb_build_array(v_event));
  update public.analytics_country_observations set observed_at = v_time - interval '1 minute' where event_id = 'b0000000-0000-4000-8000-000000000001';
  assert (select schema_version from public.analytics_events where id='b0000000-0000-4000-8000-000000000002') = 1, 'legacy defaults';

  insert into public.analytics_installations values (v_c,v_time,v_time),(v_d,v_time - interval '2 days',v_time - interval '2 days'),(v_e,v_start - interval '1 day',v_start - interval '1 day');
  update public.analytics_installations set first_seen = v_start - interval '1 day' where installation_id = v_a;
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version,duration_seconds) values
    ('c0000000-0000-4000-8000-000000000001',v_c,v_session,v_time,'reading_heartbeat',2,45),
    ('d0000000-0000-4000-8000-000000000001',v_d,v_session,v_time - interval '2 days','reading_heartbeat',2,30),
    ('e0000000-0000-4000-8000-000000000001',v_e,v_session,v_start - interval '1 day','app_active',2,null),
    (gen_random_uuid(),v_a,v_session,v_time,'reading_heartbeat',2,15),
    (gen_random_uuid(),v_a,v_session,v_time,'note_edit_session',2,null),
    (gen_random_uuid(),v_a,v_session,v_time,'sketch_created',2,null),
    (gen_random_uuid(),v_a,v_session,v_time,'sketch_edit_session',2,null);
  insert into public.analytics_country_observations(event_id,installation_id,observed_at,country_code) values
    ('c0000000-0000-4000-8000-000000000001',v_c,v_start - interval '1 second','DE'),
    ('d0000000-0000-4000-8000-000000000001',v_d,v_time,'CA'),
    ('e0000000-0000-4000-8000-000000000001',v_e,v_time,'FR');

  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version,request_id) values
    (gen_random_uuid(),v_a,v_session,v_time - interval '2 hours','ai_request_started',2,v_r1),
    (gen_random_uuid(),v_a,v_session,v_time - interval '119 minutes','ai_request_started',2,v_r1),
    (gen_random_uuid(),v_a,v_session,v_time - interval '1 hour','ai_request_completed',2,v_r1),
    (gen_random_uuid(),v_a,v_session,v_time - interval '59 minutes','ai_request_failed',2,v_r1),
    (gen_random_uuid(),v_a,v_session,v_time - interval '90 minutes','ai_request_started',2,v_r2),
    (gen_random_uuid(),v_a,v_session,v_time - interval '89 minutes','ai_request_cancelled',2,v_r2),
    (gen_random_uuid(),v_a,v_session,v_time - interval '88 minutes','ai_request_completed',2,v_r2),
    (gen_random_uuid(),v_a,v_session,v_time - interval '60 minutes','ai_request_started',2,v_r3),
    (gen_random_uuid(),v_a,v_session,v_time - interval '59 minutes','ai_request_failed',2,v_r3),
    (gen_random_uuid(),v_a,v_session,v_time - interval '50 minutes','ai_request_started',2,v_r4),
    (gen_random_uuid(),v_a,v_session,v_time - interval '40 minutes','ai_request_started',2,v_r5),
    (gen_random_uuid(),v_a,v_session,v_time - interval '41 minutes','ai_request_completed',2,v_r5),
    (gen_random_uuid(),v_a,v_session,v_time - interval '30 minutes','ai_request_started',2,v_r6),
    (gen_random_uuid(),v_b,v_session,v_time - interval '29 minutes','ai_request_completed',1,v_r6),
    (gen_random_uuid(),v_a,v_session,v_start - interval '1 day','ai_request_started',2,v_r7),
    (gen_random_uuid(),v_a,v_session,v_time - interval '10 minutes','ai_request_started',2,v_r7),
    (gen_random_uuid(),v_a,v_session,v_time - interval '9 minutes','ai_request_completed',2,v_r7),
    (gen_random_uuid(),v_a,v_session,v_time - interval '5 minutes','ai_request_started',2,v_r8),
    (gen_random_uuid(),v_b,v_session,v_time,'ai_request_started',1,null),
    (gen_random_uuid(),v_b,v_session,v_time,'ai_request_completed',1,null);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,received_at,name,schema_version,request_id)
  values(gen_random_uuid(),v_a,v_session,v_now + interval '1 minute',v_now + interval '1 minute','ai_request_completed',2,v_r8);

  v_data := public.analytics_dashboard(7, v_now);
  assert v_data #>> '{summary,active_users,value}' = '4', 'distinct active installations';
  assert v_data #>> '{summary,returning_users,value}' = '1', 'returning installations based on first seen';
  assert v_data #>> '{summary,reading_seconds,value}' = '90', 'engagement durations';
  assert v_data #>> '{coverage,instrumented_devices}' = '3', 'schema2 devices';
  assert v_data #>> '{coverage,legacy_devices}' = '1', 'legacy-only devices';
  assert v_data #>> '{coverage,semantic_features_available}' = 'true', 'semantic metrics coverage';
  assert (select (item->>'devices')::int from jsonb_array_elements(v_data->'countries') item where item->>'country_code' = 'NG') = 1, 'latest country per active installation';
  assert (select (item->>'devices')::int from jsonb_array_elements(v_data->'countries') item where item->>'country_code' = 'CA') = 1, 'delayed upload country';
  assert (select (item->>'devices')::int from jsonb_array_elements(v_data->'countries') item where item->>'country_code' is null) = 2, 'missing or outside-window observations Unknown';
  assert (select sum((item->>'devices')::int) from jsonb_array_elements(v_data->'countries') item) = 4, 'one country bucket per active device';
  assert not exists(select 1 from jsonb_array_elements(v_data->'countries') item where item->>'country_code' in ('DE','FR','US')), 'old, inactive, and superseded countries excluded';
  for v_event in select value from jsonb_array_elements(v_data->'features') loop
    if v_event->>'name' in ('note_created','note_edit_session','sketch_created','sketch_edit_session','note_saved') then
      assert v_event->>'count' = '1', 'semantic and legacy events reported separately';
    end if;
  end loop;
  v_outcomes := v_data->'ai_outcomes';
  assert v_outcomes = '{"started":8,"completed":1,"failed":1,"cancelled":1,"unknown":5,"legacy_started":1}'::jsonb, 'AI start cohort, duplicate lifecycle, cancellations, legacy, wrong-installation and future outcomes';
  assert not v_data::text like '%a1111111-%', 'dashboard never returns installation IDs';
  assert not v_data::text like '%2222-4222-%', 'dashboard never returns telemetry request IDs';
  assert jsonb_array_length(public.analytics_dashboard(30,v_now)->'daily') = 30, '30-day v2 view';
  assert jsonb_array_length(public.analytics_dashboard(90,v_now)->'daily') = 90, '90-day v2 view';

  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name)
  values('f0000000-0000-4000-8000-000000000001',v_e,v_session,v_time - interval '181 days','app_active');
  insert into public.analytics_country_observations(event_id,installation_id,observed_at,country_code)
  values('f0000000-0000-4000-8000-000000000001',v_e,v_time - interval '181 days','US');
  perform public.analytics_prune(v_now);
  assert not exists(select 1 from public.analytics_country_observations where event_id='f0000000-0000-4000-8000-000000000001'), 'country observations follow raw retention';
end;
$$;
-- Exercise the actual collector/dashboard database role even when no optional
-- account-history helper or private application schemas exist.
set local role service_role;
do $$
declare v_event jsonb;
begin
  assert public.analytics_dashboard(7, now() + interval '10 seconds') #>> '{summary,active_users,value}' = '4', 'service-role telemetry-only dashboard';
  v_event := jsonb_build_object('id',gen_random_uuid(),'installation_id','a1111111-1111-4111-8111-111111111111',
    'session_id','f1111111-1111-4111-8111-111111111111','occurred_at',now(),'name','app_active','properties',jsonb_build_object('schema_version',2));
  assert public.analytics_ingest(jsonb_build_array(v_event), 'NG')->>'stored' = '1', 'service-role collector stores country observation';
  assert (select count(*) from public.analytics_country_observations) > 0, 'service-role aggregate country reads';
end;
$$;
reset role;
rollback;
