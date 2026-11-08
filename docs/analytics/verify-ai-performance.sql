-- Disposable database only, after 001, 003, 004, and 005. Fixtures roll back.
begin;
set local time zone 'Pacific/Kiritimati';
do $$
declare
  v_now timestamptz := now() + interval '10 seconds';
  v_start timestamptz := (((now() + interval '10 seconds') at time zone 'UTC')::date - 6)::timestamp at time zone 'UTC';
  v_a uuid := 'a5555555-5555-4555-8555-555555555551';
  v_b uuid := 'b5555555-5555-4555-8555-555555555552';
  v_session uuid := 'f5555555-5555-4555-8555-555555555556';
  v_request uuid;
  v_event jsonb;
  v_data jsonb;
  v_metric jsonb;
  v_result jsonb;
  v_name text;
  v_response integer;
  v_latency integer;
  v_stream integer;
  v_schema integer;
  v_i integer;
begin
  assert not has_function_privilege('anon','public.analytics_dashboard(integer,timestamptz)','EXECUTE'), 'anonymous dashboard denied';
  assert not has_function_privilege('authenticated','public.analytics_ingest(jsonb,text)','EXECUTE'), 'ordinary collector RPC denied';
  assert not has_table_privilege('anon','public.analytics_events','SELECT'), 'raw timings remain private';
  assert not has_table_privilege('authenticated','public.analytics_events','INSERT'), 'ordinary writes denied';
  assert (select relrowsecurity from pg_class where oid='public.analytics_events'::regclass), 'RLS retained';
  assert not (select prosecdef from pg_proc where oid='public.analytics_dashboard(integer,timestamptz)'::regprocedure), 'dashboard remains invoker';
  assert not (select prosecdef from pg_proc where oid='public.analytics_ingest(jsonb,text)'::regprocedure), 'collector remains invoker';

  v_data := public.analytics_dashboard(7,v_now)->'ai_performance';
  assert v_data->>'available'='false' and v_data->>'previous_available'='false', 'empty periods unmeasured';
  foreach v_name in array array['completed','failed','cancelled'] loop
    assert v_data #>> array[v_name,'requests']='0', 'empty request sample count';
    for v_metric in select value from jsonb_each((v_data->v_name)-'requests') loop
      assert v_metric='{"samples":0,"average":null,"p50":null,"p95":null}'::jsonb, 'empty stats are null, not zero';
    end loop;
  end loop;

  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version)
  values(gen_random_uuid(),v_a,v_session,now(),'app_active',4),
        (gen_random_uuid(),v_b,v_session,now(),'app_active',3);
  v_data:=public.analytics_dashboard(7,v_now)->'ai_performance';
  assert v_data->>'available'='true' and v_data->>'previous_available'='false', 'current capability does not establish historical coverage';
  assert v_data->'coverage'='{"devices":1,"older_devices":1}'::jsonb, 'timing-capable and older devices separate';

  -- Four completed responses produce a known mean, median and interpolated p95.
  -- Retried semantic starts and later competing terminal events count once.
  for v_i in 1..4 loop
    v_request:=gen_random_uuid();
    v_response:=case v_i when 1 then 1000 when 2 then 2000 when 3 then 4000 else 6000 end;
    insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version)
    values(gen_random_uuid(),v_a,v_session,now()-interval '2 minutes','ai_request_started',v_request,4),
          (gen_random_uuid(),v_a,v_session,now()-interval '90 seconds','ai_request_started',v_request,4);
    insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version,response_time_ms,latency_ms,streaming_time_ms)
    values(gen_random_uuid(),v_a,v_session,now()-interval '1 minute','ai_request_completed',v_request,4,v_response,v_response/10,v_response-v_response/10),
          (gen_random_uuid(),v_a,v_session,now()-interval '30 seconds','ai_request_failed',v_request,4,9000,1000,8000);
  end loop;
  -- Failed and stopped requests can end before first text or after partial text.
  for v_i in 1..4 loop
    v_request:=gen_random_uuid();
    insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version)
    values(gen_random_uuid(),v_a,v_session,now()-interval '2 minutes','ai_request_started',v_request,4);
    insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version,response_time_ms,latency_ms,streaming_time_ms)
    values(gen_random_uuid(),v_a,v_session,now()-interval '1 minute',case when v_i<3 then 'ai_request_failed' else 'ai_request_cancelled' end,v_request,4,
      case v_i when 1 then 500 when 2 then 2000 when 3 then 100 else 3000 end,
      case v_i when 2 then 300 when 4 then 400 end,
      case v_i when 2 then 1700 when 4 then 2600 end);
  end loop;
  -- First terminal wins even if only a later duplicate includes timing data.
  v_request:=gen_random_uuid();
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version)
  values(gen_random_uuid(),v_a,v_session,now()-interval '2 minutes','ai_request_started',v_request,3),
        (gen_random_uuid(),v_a,v_session,now()-interval '1 minute','ai_request_completed',v_request,3);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version,response_time_ms,latency_ms,streaming_time_ms)
  values(gen_random_uuid(),v_a,v_session,now()-interval '30 seconds','ai_request_completed',v_request,4,50000,10000,40000);
  -- Cross-boundary starts, orphan terminals, other devices and future outcomes
  -- must never enter the current cohort's timing distribution.
  v_request:=gen_random_uuid();
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version)
  values(gen_random_uuid(),v_a,v_session,v_start-interval '1 minute','ai_request_started',v_request,4);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,schema_version)
  values(gen_random_uuid(),v_a,v_session,v_now-interval '8 days','app_active',4);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version,response_time_ms,latency_ms,streaming_time_ms)
  values(gen_random_uuid(),v_a,v_session,now()-interval '1 minute','ai_request_completed',v_request,4,60000,10000,50000),
        (gen_random_uuid(),v_a,v_session,now()-interval '1 minute','ai_request_completed',gen_random_uuid(),4,60000,10000,50000);
  v_request:=gen_random_uuid();
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version)
  values(gen_random_uuid(),v_a,v_session,now()-interval '2 minutes','ai_request_started',v_request,4);
  insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version,response_time_ms,latency_ms,streaming_time_ms)
  values(gen_random_uuid(),v_b,v_session,now()-interval '1 minute','ai_request_completed',v_request,4,60000,10000,50000),
        (gen_random_uuid(),v_a,v_session,v_now+interval '1 minute','ai_request_completed',v_request,4,60000,10000,50000);

  v_result:=public.analytics_dashboard(7,v_now);
  v_data:=v_result->'ai_performance';
  assert v_data->>'previous_available'='true', 'prior schema-v4 activity establishes previous coverage';
  assert v_data #>> '{completed,requests}'='4', 'completed samples match deduplicated cohort outcomes';
  assert (v_data #>> '{completed,response_time_ms,average}')::numeric=3250, 'mean response time';
  assert (v_data #>> '{completed,response_time_ms,p50}')::numeric=3000, 'median response time';
  assert abs((v_data #>> '{completed,response_time_ms,p95}')::numeric-5700)<0.001, 'p95 response time';
  assert (v_data #>> '{completed,latency_ms,average}')::numeric=325, 'mean first-text latency';
  assert (v_data #>> '{completed,streaming_time_ms,average}')::numeric=2925, 'mean streaming duration';
  assert v_data #>> '{failed,requests}'='2' and v_data #>> '{cancelled,requests}'='2', 'failure and stop samples stay separate';
  assert v_data #>> '{failed,latency_ms,samples}'='1' and v_data #>> '{cancelled,streaming_time_ms,samples}'='1', 'pre-text outcomes do not fabricate zero latency or stream time';
  assert (v_data #>> '{failed,response_time_ms,average}')::numeric=1250, 'failure elapsed time';
  assert (v_data #>> '{cancelled,response_time_ms,average}')::numeric=1550, 'stopped elapsed time';
  assert not v_result::text like '%5555-4555-%', 'aggregates exclude telemetry UUIDs';
  assert public.analytics_dashboard(30,v_now) ? 'ai_performance', '30-day performance available';
  assert public.analytics_dashboard(90,v_now) ? 'ai_performance', '90-day performance available';

  -- Database constraints independently enforce the timing contract.
  for v_name,v_schema,v_response,v_latency,v_stream in
    select * from (values
      ('app_active',4,100,null::int,null::int), ('ai_request_started',4,100,null,null),
      ('ai_request_failed',3,100,null,null), ('ai_request_failed',4,-1,null,null),
      ('ai_request_cancelled',4,86400001,null,null), ('ai_request_completed',4,100,null,null),
      ('ai_request_failed',4,null,10,20), ('ai_request_completed',4,100,10,null),
      ('ai_request_completed',4,100,-1,101), ('ai_request_completed',4,100,10,20)
    ) as invalid(name,schema_version,response_ms,latency_ms,streaming_ms)
  loop
    begin
      insert into public.analytics_events(id,installation_id,session_id,occurred_at,name,request_id,schema_version,response_time_ms,latency_ms,streaming_time_ms)
      values(gen_random_uuid(),v_a,v_session,now(),v_name,case when v_name<>'app_active' then gen_random_uuid() end,v_schema,v_response,v_latency,v_stream);
      raise exception 'Expected invalid timing rejection';
    exception when check_violation then null;
    end;
  end loop;
end;
$$;

set local role service_role;
do $$
declare
  v_event jsonb := jsonb_build_object('id',gen_random_uuid(),'installation_id','a5555555-5555-4555-8555-555555555551',
    'session_id','f5555555-5555-4555-8555-555555555556','occurred_at',now(),'name','ai_request_completed',
    'properties',jsonb_build_object('schema_version',4,'request_id',gen_random_uuid(),'response_time_ms',2200,'latency_ms',200,'streaming_time_ms',2000));
begin
  assert public.analytics_ingest(jsonb_build_array(v_event),'DE')->>'stored'='1', 'service collector stores milliseconds';
  assert public.analytics_ingest(jsonb_build_array(v_event),'US')->>'stored'='0', 'retry deduplicates timing';
  assert (select response_time_ms=2200 and latency_ms=200 and streaming_time_ms=2000 from public.analytics_events where id=(v_event->>'id')::uuid), 'all timings persisted';
  assert public.analytics_dashboard(7,now()+interval '10 seconds') ? 'ai_performance', 'service dashboard reads private timings';
end;
$$;
reset role;
rollback;
