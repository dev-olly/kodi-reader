-- Run only against a disposable database after 001_analytics.sql.
-- Fixtures are rolled back; this deliberately creates >1,000 events.
begin;
set local time zone 'Pacific/Kiritimati';

do $$
declare
  v_now timestamptz := now() + interval '10 seconds';
  v_time timestamptz := now();
  v_previous timestamptz := now() - interval '7 days';
  v_first uuid := '11111111-1111-4111-8111-111111111111';
  v_second uuid := '22222222-2222-4222-8222-222222222222';
  v_old uuid := '33333333-3333-4333-8333-333333333333';
  v_session uuid := '44444444-4444-4444-8444-444444444444';
  v_id uuid := '55555555-5555-4555-8555-555555555555';
  v_event jsonb;
  v_data jsonb;
  v_summary jsonb;
begin
  assert not has_table_privilege('anon', 'public.analytics_events', 'SELECT'), 'anonymous table reads';
  assert not has_table_privilege('authenticated', 'public.analytics_installations', 'SELECT'), 'authenticated registry reads';
  assert not has_table_privilege('anon', 'public.analytics_events', 'INSERT'), 'anonymous direct writes';
  assert not has_function_privilege('anon', 'public.analytics_dashboard(integer,timestamptz)', 'EXECUTE'), 'anonymous dashboard RPC';
  assert not has_function_privilege('authenticated', 'public.analytics_ingest(jsonb)', 'EXECUTE'), 'authenticated ingest RPC';
  assert not has_function_privilege('anon', 'public.analytics_prune(timestamptz)', 'EXECUTE'), 'anonymous prune RPC';
  assert has_function_privilege('service_role', 'public.analytics_dashboard(integer,timestamptz)', 'EXECUTE'), 'service role dashboard';
  assert (select relrowsecurity from pg_class where oid = 'public.analytics_events'::regclass), 'events RLS';
  assert (select relrowsecurity from pg_class where oid = 'public.analytics_installations'::regclass), 'installations RLS';

  begin
    perform public.analytics_dashboard(null);
    raise exception 'Expected null analytics period rejection';
  exception when raise_exception then
    assert sqlerrm = 'Invalid analytics period', 'specific null period rejection';
  end;

  -- A configured but empty database returns honest zeros and a full daily series.
  v_data := public.analytics_dashboard(7, v_now);
  assert v_data #>> '{summary,active_users,value}' = '0', 'empty active devices';
  assert jsonb_array_length(v_data->'daily') = 7, 'empty calendar';
  assert v_data->'versions' = '[]'::jsonb, 'empty versions';

  v_event := jsonb_build_object(
    'id', v_id, 'installation_id', v_first, 'session_id', v_session,
    'occurred_at', v_time, 'name', 'app_active',
    'properties', jsonb_build_object('platform', 'macOS', 'version', '0.4.0', 'build', '27')
  );
  assert public.analytics_ingest(jsonb_build_array(v_event))->>'stored' = '1', 'first insert';
  assert public.analytics_ingest(jsonb_build_array(v_event, v_event))->>'stored' = '0', 'idempotent retries';
  assert (select count(*) from public.analytics_events) = 1, 'deduplicated event IDs';
  assert (select count(*) from public.analytics_installations) = 1, 'single installation';
  begin
    perform public.analytics_ingest(jsonb_build_array(
      jsonb_set(v_event, '{id}', to_jsonb(gen_random_uuid())),
      jsonb_set(jsonb_set(v_event, '{id}', to_jsonb(gen_random_uuid())), '{occurred_at}', to_jsonb(now() - interval '91 days'))
    ));
    raise exception 'Expected old event batch rejection';
  exception when raise_exception then
    assert sqlerrm = 'Event timestamp outside accepted window', 'specific invalid timestamp rejection';
  end;
  assert (select count(*) from public.analytics_events) = 1, 'invalid batches never partially store';

  insert into public.analytics_events (id, installation_id, session_id, occurred_at, name, duration_seconds, app_version)
  values
    (gen_random_uuid(), v_first, v_session, v_time, 'reading_started', null, '0.4.0'),
    (gen_random_uuid(), v_first, v_session, v_time, 'reading_heartbeat', 60, '0.4.0'),
    (gen_random_uuid(), v_first, v_session, v_time, 'page_turned', null, '0.4.0'),
    (gen_random_uuid(), v_first, v_session, v_time, 'ai_request_started', null, '0.4.0'),
    (gen_random_uuid(), v_first, v_session, v_time, 'ai_request_completed', null, '0.4.0'),
    (gen_random_uuid(), v_second, v_session, v_time, 'ai_request_started', null, '0.5.0'),
    (gen_random_uuid(), v_second, v_session, v_time, 'ai_request_failed', null, '0.5.0'),
    (gen_random_uuid(), v_old, v_session, v_previous, 'app_active', null, '0.3.0'),
    (gen_random_uuid(), v_old, v_session, v_previous, 'reading_heartbeat', 30, '0.3.0'),
    (gen_random_uuid(), v_old, v_session, v_previous, 'ai_request_started', null, '0.3.0');
  insert into public.analytics_installations values (v_second, v_time, v_time), (v_old, v_previous, v_previous);
  insert into public.analytics_events (id, installation_id, session_id, occurred_at, name, app_version)
  select gen_random_uuid(), v_first, v_session, v_time, 'page_turned', '0.4.0' from generate_series(1, 1005);

  v_data := public.analytics_dashboard(7, v_now);
  v_summary := v_data->'summary';
  assert v_summary #>> '{active_users,value}' = '2', 'current distinct devices';
  assert v_summary #>> '{active_users,previous}' = '1', 'previous distinct devices';
  assert v_summary #>> '{readers,value}' = '1', 'current readers';
  assert v_summary #>> '{readers,previous}' = '1', 'previous readers';
  assert v_summary #>> '{ai_users,value}' = '2', 'current AI devices';
  assert v_summary #>> '{reading_seconds,value}' = '60', 'current reading duration';
  assert v_summary #>> '{reading_seconds,previous}' = '30', 'previous reading duration';
  assert v_summary #>> '{new_users,value}' = '2', 'first-seen current devices';
  assert v_summary #>> '{new_users,previous}' = '1', 'first-seen previous devices';
  assert v_summary #>> '{sessions,value}' = '2', 'sessions scoped to installations';
  assert v_summary #>> '{ai_requests,value}' = '2', 'AI requests';
  assert v_summary #>> '{ai_completed,value}' = '1', 'AI completions';
  assert v_summary #>> '{ai_failed,value}' = '1', 'AI failures';
  assert (select feature->>'count' from jsonb_array_elements(v_data->'features') feature where feature->>'name' = 'page_turned') = '1006', 'aggregate beyond REST row cap';
  assert v_data #>> '{daily,0,date}' = (((v_now at time zone 'UTC')::date - 6)::text), 'UTC first day';
  assert v_data #>> '{daily,6,active_users}' = '2', 'UTC current day';
  assert (v_data #>> '{period,start}')::timestamptz = (((v_now at time zone 'UTC')::date - 6)::timestamp at time zone 'UTC'), 'UTC window';
  assert (v_data #>> '{period,end}')::timestamptz - (v_data #>> '{period,start}')::timestamptz =
    (v_data #>> '{period,previous_end}')::timestamptz - (v_data #>> '{period,previous_start}')::timestamptz, 'equal comparison duration';
  assert jsonb_array_length(v_data->'versions') = 2, 'current versions only';
  assert jsonb_array_length(public.analytics_dashboard(30, v_now)->'daily') = 30, '30 day calendar';
  assert jsonb_array_length(public.analytics_dashboard(90, v_now)->'daily') = 90, '90 day calendar';

  assert public.analytics_ingest(jsonb_build_array(v_event))->>'stored' = '0', 'duplicates accepted after rate limit';
  v_event := jsonb_set(v_event, '{id}', to_jsonb(gen_random_uuid()));
  assert public.analytics_ingest(jsonb_build_array(v_event))->>'rate_limited' = 'true', 'per-installation rate limit';

  -- Active installations keep their first-seen record, inactive ones expire.
  insert into public.analytics_events (id, installation_id, session_id, occurred_at, name)
  values (gen_random_uuid(), '66666666-6666-4666-8666-666666666666', v_session, v_now - interval '181 days', 'app_active');
  insert into public.analytics_installations values ('66666666-6666-4666-8666-666666666666', v_now - interval '181 days', v_now - interval '181 days');
  v_data := public.analytics_prune(v_now);
  assert v_data->>'events_deleted' = '1', '180 day event retention';
  assert v_data->>'installations_deleted' = '1', '180 day inactive installation retention';
  assert (select count(*) from public.analytics_installations) = 3, 'active registries preserved';
end;
$$;

rollback;
