-- Run only against a disposable database after 001, 003, and 004. All fixtures
-- roll back. No authentication, billing, note content, or audio is read or stored.
begin;
set local time zone 'Pacific/Kiritimati';

do $$
declare
  v_now timestamptz := now() + interval '10 seconds';
  v_time timestamptz := now();
  v_a uuid := 'a3333333-3333-4333-8333-333333333331';
  v_b uuid := 'b3333333-3333-4333-8333-333333333332';
  v_old uuid := 'c3333333-3333-4333-8333-333333333333';
  v_v2 uuid := 'd3333333-3333-4333-8333-333333333334';
  v_v1 uuid := 'e3333333-3333-4333-8333-333333333335';
  v_session uuid := 'f3333333-3333-4333-8333-333333333336';
  v_event jsonb;
  v_data jsonb;
  v_name text;
  v_group jsonb;
  v_metric jsonb;
  v_duration integer;
  v_probe uuid := gen_random_uuid();
  v_probe_second uuid := gen_random_uuid();
  v_actions text[] := array[
    'reminder_created', 'reminder_updated', 'reminder_completed', 'reminder_reopened',
    'reminder_deleted', 'reminder_restored', 'reminder_opened',
    'sketch_created', 'sketch_edit_session', 'sketch_opened', 'sketch_deleted',
    'audio_recording_started', 'audio_recording_paused', 'audio_recording_resumed',
    'audio_recording_saved', 'audio_recording_discarded', 'audio_recording_failed',
    'tts_listening_started', 'tts_listening_paused', 'tts_listening_resumed',
    'tts_listening_stopped', 'tts_listening_completed', 'tts_listening_failed'
  ];
begin
  assert not has_function_privilege('anon', 'public.analytics_dashboard(integer,timestamptz)', 'EXECUTE'), 'no anonymous dashboard';
  assert not has_function_privilege('authenticated', 'public.analytics_dashboard(integer,timestamptz)', 'EXECUTE'), 'no ordinary signed-in dashboard';
  assert not has_function_privilege('anon', 'public.analytics_ingest(jsonb,text)', 'EXECUTE'), 'no anonymous collector RPC';
  assert not has_function_privilege('authenticated', 'public.analytics_ingest(jsonb)', 'EXECUTE'), 'no signed-in legacy collector RPC';
  assert not has_table_privilege('anon', 'public.analytics_events', 'SELECT'), 'no anonymous event reads';
  assert not has_table_privilege('authenticated', 'public.analytics_events', 'INSERT'), 'no direct signed-in event writes';
  assert (select relrowsecurity from pg_class where oid = 'public.analytics_events'::regclass), 'event RLS preserved';
  assert not (select prosecdef from pg_proc where oid = 'public.analytics_dashboard(integer,timestamptz)'::regprocedure), 'dashboard remains invoker';
  assert not (select prosecdef from pg_proc where oid = 'public.analytics_ingest(jsonb,text)'::regprocedure), 'collector remains invoker';

  v_data := public.analytics_dashboard(7, v_now);
  assert v_data #>> '{coverage,feature_usage_available}' = 'false', 'empty data is not measured';
  assert v_data #>> '{coverage,feature_usage_previous_available}' = 'false', 'empty prior period is not measured';
  assert v_data #>> '{coverage,feature_usage_devices}' = '0', 'no collection-capable devices';
  for v_group in select value from jsonb_each(v_data->'feature_usage') loop
    assert v_group->>'available' = 'false', 'empty feature group unavailable';
    assert v_group->>'previous_available' = 'false', 'empty prior feature group unavailable';
    for v_metric in select value from jsonb_each(v_group - 'available' - 'previous_available') loop
      assert v_metric = '{"value":0,"previous":0}'::jsonb, 'honest empty metric totals';
    end loop;
  end loop;

  -- Capability belongs to each reporting period independently. A new release
  -- cannot establish that a pre-instrumentation comparison period measured zero.
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,duration_seconds,schema_version)
  values(v_probe,v_a,v_session,v_time,'audio_recording_heartbeat',9,3);
  v_data := public.analytics_dashboard(7,v_now);
  assert v_data #>> '{coverage,feature_usage_available}' = 'true', 'current-only V3 coverage detected';
  assert v_data #>> '{coverage,feature_usage_previous_available}' = 'false', 'current-only V3 does not establish prior coverage';
  for v_group in select value from jsonb_each(v_data->'feature_usage') loop
    assert v_group->>'available' = 'true' and v_group->>'previous_available' = 'false', 'current-only group coverage stays distinct';
  end loop;
  assert v_data #> '{feature_usage,recording,seconds}' = '{"value":9,"previous":0}'::jsonb, 'counts retained with explicit unmeasured-prior flag';
  delete from public.analytics_events where id = v_probe;

  -- A prior-only V3 installation still exposes its recorded totals and prior
  -- availability even when no currently active device establishes coverage.
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,duration_seconds,schema_version)
  values(v_probe,v_old,v_session,v_time - interval '7 days','audio_recording_heartbeat',11,3);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version)
  values(v_probe_second,v_old,v_session,v_time - interval '7 days','reminder_created',3);
  v_data := public.analytics_dashboard(7,v_now);
  assert v_data #>> '{coverage,feature_usage_available}' = 'false', 'prior-only V3 does not establish current coverage';
  assert v_data #>> '{coverage,feature_usage_previous_available}' = 'true', 'prior-only V3 coverage retained';
  for v_group in select value from jsonb_each(v_data->'feature_usage') loop
    assert v_group->>'available' = 'false' and v_group->>'previous_available' = 'true', 'prior-only groups remain available for comparison';
  end loop;
  assert v_data #> '{feature_usage,recording,seconds}' = '{"value":0,"previous":11}'::jsonb, 'prior-only duration exposed';
  assert v_data #> '{feature_usage,reminders,created}' = '{"value":0,"previous":1}'::jsonb, 'prior-only action exposed';
  delete from public.analytics_events where id in (v_probe,v_probe_second);

  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version)
  values(v_probe,v_v2,v_session,v_time - interval '7 days','sketch_created',2);
  v_data := public.analytics_dashboard(7,v_now);
  assert v_data #>> '{feature_usage,sketching,available}' = 'false', 'prior-only V2 has no current drawing coverage';
  assert v_data #>> '{feature_usage,sketching,previous_available}' = 'true', 'prior-only V2 drawing coverage retained';
  assert v_data #>> '{feature_usage,sketching,created,previous}' = '1', 'prior-only V2 sketch count retained';
  assert v_data #>> '{coverage,feature_usage_previous_available}' = 'false', 'prior V2 does not establish V3 drawing-open/delete coverage';
  assert v_data #>> '{feature_usage,reminders,previous_available}' = 'false', 'prior V2 cannot establish reminder coverage';
  delete from public.analytics_events where id = v_probe;

  -- V2 sketch history remains measurable independently of the new V3 features.
  v_event := jsonb_build_object('id',gen_random_uuid(),'installation_id',v_v2,'session_id',v_session,
    'occurred_at',v_time,'name','sketch_created','properties',jsonb_build_object('schema_version',2));
  assert public.analytics_ingest(jsonb_build_array(v_event))->>'stored' = '1', 'legacy ingest signature preserves V2';
  v_data := public.analytics_dashboard(7,v_now);
  assert v_data #>> '{feature_usage,sketching,available}' = 'true', 'V2 sketches already measured';
  assert v_data #>> '{feature_usage,sketching,previous_available}' = 'false', 'current V2 does not establish prior drawing coverage';
  assert v_data #>> '{feature_usage,sketching,created,value}' = '1', 'V2 sketch totals included';
  assert v_data #>> '{feature_usage,reminders,available}' = 'false', 'V2 does not establish reminder coverage';
  assert v_data #>> '{feature_usage,recording,available}' = 'false', 'V2 does not establish recording coverage';
  assert v_data #>> '{feature_usage,listening,available}' = 'false', 'V2 does not establish listening coverage';

  foreach v_name in array v_actions loop
    v_event := jsonb_build_object('id',gen_random_uuid(),'installation_id',v_a,'session_id',v_session,
      'occurred_at',v_time,'name',v_name,'properties',jsonb_build_object('schema_version',3));
    assert public.analytics_ingest(jsonb_build_array(v_event),'NG')->>'stored' = '1', 'V3 actions accepted';
    assert public.analytics_ingest(jsonb_build_array(v_event),'US')->>'stored' = '0', 'feature retries deduplicate';
  end loop;

  v_data := public.analytics_dashboard(7,v_now);
  assert v_data #>> '{coverage,feature_usage_previous_available}' = 'false', 'current V3 actions do not invent prior coverage';
  assert v_data #>> '{feature_usage,recording,previous_available}' = 'false', 'prior recording zero is explicitly unmeasured';

  -- Bound interval events preserve recording/listening time without counting it
  -- as reading time, and do not inflate action counts or the recent-action log.
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,duration_seconds,schema_version)
  values
    (gen_random_uuid(),v_a,v_session,v_time,'audio_recording_heartbeat',30,3),
    (gen_random_uuid(),v_a,v_session,v_time,'tts_listening_heartbeat',60,3),
    (gen_random_uuid(),v_a,v_session,v_time,'reading_heartbeat',45,3),
    (gen_random_uuid(),v_b,v_session,v_time,'audio_recording_heartbeat',10,3),
    (gen_random_uuid(),v_old,v_session,v_time - interval '7 days','audio_recording_heartbeat',20,3),
    (gen_random_uuid(),v_old,v_session,v_time - interval '7 days','tts_listening_heartbeat',30,3);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version)
  values
    (gen_random_uuid(),v_b,v_session,v_time,'reminder_created',3),
    (gen_random_uuid(),v_b,v_session,v_time,'audio_recording_started',3),
    (gen_random_uuid(),v_v1,v_session,v_time,'app_active',1),
    (gen_random_uuid(),v_old,v_session,v_time - interval '7 days','reminder_created',3),
    (gen_random_uuid(),v_old,v_session,v_time - interval '7 days','sketch_created',2),
    (gen_random_uuid(),v_old,v_session,v_time - interval '7 days','audio_recording_saved',3),
    (gen_random_uuid(),v_old,v_session,v_time - interval '7 days','tts_listening_started',3);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,received_at,name,duration_seconds,schema_version)
  values(gen_random_uuid(),v_a,v_session,v_now + interval '1 minute',v_now + interval '1 minute','audio_recording_heartbeat',60,3);

  v_data := public.analytics_dashboard(7,v_now);
  assert v_data #>> '{summary,active_users,value}' = '4', 'feature-only devices are active';
  assert v_data #>> '{summary,reading_seconds,value}' = '45', 'feature intervals do not inflate reader engagement';
  assert v_data #>> '{coverage,feature_usage_available}' = 'true', 'V3 capability reported';
  assert v_data #>> '{coverage,feature_usage_previous_available}' = 'true', 'prior V3 capability reported independently';
  assert v_data #>> '{coverage,feature_usage_devices}' = '2', 'distinct V3 capable devices';
  assert v_data #>> '{coverage,feature_usage_legacy_devices}' = '2', 'legacy feature coverage explicit';
  for v_group in select value from jsonb_each(v_data->'feature_usage') loop
    assert v_group->>'available' = 'true', 'capable devices establish collection availability';
    assert v_group->>'previous_available' = 'true', 'prior capable devices establish comparison availability';
  end loop;
  assert v_data #> '{feature_usage,reminders,devices}' = '{"value":2,"previous":1}'::jsonb, 'distinct reminder devices by comparison period';
  assert v_data #> '{feature_usage,reminders,created}' = '{"value":2,"previous":1}'::jsonb, 'reminder creation totals';
  foreach v_name in array array['updated','completed','reopened','deleted','restored','opened'] loop
    assert v_data #> array['feature_usage','reminders',v_name] = '{"value":1,"previous":0}'::jsonb, 'reminder actions remain separate';
  end loop;
  assert v_data #> '{feature_usage,sketching,devices}' = '{"value":2,"previous":1}'::jsonb, 'distinct sketch users include legacy semantic telemetry';
  assert v_data #> '{feature_usage,sketching,created}' = '{"value":2,"previous":1}'::jsonb, 'sketch creations preserve V2';
  assert v_data #> '{feature_usage,sketching,edit_sessions}' = '{"value":1,"previous":0}'::jsonb, 'successful meaningful sketch edit sessions';
  assert v_data #>> '{feature_usage,sketching,opened,value}' = '1', 'sketch opens';
  assert v_data #>> '{feature_usage,sketching,deleted,value}' = '1', 'sketch deletes';
  assert not ((v_data #> '{feature_usage,sketching}') ? 'seconds'), 'sketching does not imply a measured timer';
  assert v_data #> '{feature_usage,recording,devices}' = '{"value":2,"previous":1}'::jsonb, 'distinct recording devices';
  assert v_data #> '{feature_usage,recording,started}' = '{"value":2,"previous":0}'::jsonb, 'recording starts';
  assert v_data #> '{feature_usage,recording,saved}' = '{"value":1,"previous":1}'::jsonb, 'saved recordings separate from starts';
  assert v_data #> '{feature_usage,recording,seconds}' = '{"value":40,"previous":20}'::jsonb, 'recording intervals sum once and exclude future events';
  foreach v_name in array array['discarded','paused','resumed','failed'] loop
    assert v_data #> array['feature_usage','recording',v_name] = '{"value":1,"previous":0}'::jsonb, 'recording outcomes separate';
  end loop;
  assert v_data #> '{feature_usage,listening,devices}' = '{"value":1,"previous":1}'::jsonb, 'distinct listening devices';
  assert v_data #> '{feature_usage,listening,started}' = '{"value":1,"previous":1}'::jsonb, 'listening starts';
  assert v_data #> '{feature_usage,listening,seconds}' = '{"value":60,"previous":30}'::jsonb, 'listening intervals separate from recording and reading';
  foreach v_name in array array['paused','resumed','stopped','completed','failed'] loop
    assert v_data #> array['feature_usage','listening',v_name] = '{"value":1,"previous":0}'::jsonb, 'listening actions separate';
  end loop;
  assert not exists(select 1 from jsonb_array_elements(v_data->'recent') e where e->>'name' like '%heartbeat'), 'intervals excluded from recent actions';
  foreach v_name in array v_actions loop
    assert exists(select 1 from jsonb_array_elements(v_data->'features') e where e->>'name' = v_name and (e->>'count')::int > 0), 'feature totals expose each action';
  end loop;
  assert not v_data::text like '%3333-4333-%', 'aggregate response excludes installation/session IDs';
  assert jsonb_array_length(public.analytics_dashboard(30,v_now)->'daily') = 30, '30-day feature dashboard';
  assert jsonb_array_length(public.analytics_dashboard(90,v_now)->'daily') = 90, '90-day feature dashboard';

  -- Constraints defend the database even when the API validator is bypassed.
  foreach v_name in array array['reading_heartbeat','audio_recording_heartbeat','tts_listening_heartbeat'] loop
    foreach v_duration in array array[null::integer,0,61,-1] loop
      begin
        insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,duration_seconds,schema_version)
        values(gen_random_uuid(),v_a,v_session,v_time,v_name,v_duration,3);
        raise exception 'Expected invalid heartbeat rejection';
      exception when check_violation then null;
      end;
    end loop;
  end loop;
  foreach v_name in array v_actions loop
    begin
      insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,duration_seconds,schema_version)
      values(gen_random_uuid(),v_a,v_session,v_time,v_name,1,3);
      raise exception 'Expected action duration rejection';
    exception when check_violation then null;
    end;
  end loop;
  begin
    insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version)
    values(gen_random_uuid(),v_a,v_session,v_time,'app_active',99);
    raise exception 'Expected future schema rejection';
  exception when check_violation then null;
  end;
  begin
    insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version)
    values(gen_random_uuid(),v_a,v_session,v_time,'ai_request_started',3);
    raise exception 'Expected V3 AI request identifier requirement';
  exception when check_violation then null;
  end;
end;
$$;

-- This is the actual database role used by the authenticated dashboard API and
-- collector. A Google account never gets direct SQL or analytics table access.
set local role service_role;
do $$
declare v_event jsonb;
begin
  assert public.analytics_dashboard(7,now() + interval '10 seconds') #>> '{feature_usage,recording,seconds,value}' = '40', 'service role can aggregate features';
  v_event := jsonb_build_object('id',gen_random_uuid(),'installation_id','a3333333-3333-4333-8333-333333333331',
    'session_id','f3333333-3333-4333-8333-333333333336','occurred_at',now(),'name','reminder_created','properties',jsonb_build_object('schema_version',3));
  assert public.analytics_ingest(jsonb_build_array(v_event),'NG')->>'stored' = '1', 'service role accepts V3 collector';
  v_event := jsonb_set(jsonb_set(v_event,'{id}',to_jsonb(gen_random_uuid())),'{name}',to_jsonb('app_active'::text));
  v_event := v_event - 'properties';
  assert public.analytics_ingest(jsonb_build_array(v_event))->>'stored' = '1', 'original V1 RPC callers remain valid';
  assert (select schema_version from public.analytics_events where id=(v_event->>'id')::uuid) = 1, 'missing schema remains V1';
end;
$$;
reset role;
rollback;
