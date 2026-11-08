-- Apply after 001_analytics.sql, 003_usage_v2.sql, and 004_feature_usage.sql.
-- V4 records client-observed Ask AI elapsed times in whole milliseconds, without
-- content, account identifiers, or billing linkage. Existing V1-V3 rows remain valid.
begin;

alter table public.analytics_events add column if not exists response_time_ms integer;
alter table public.analytics_events add column if not exists latency_ms integer;
alter table public.analytics_events add column if not exists streaming_time_ms integer;
alter table public.analytics_events drop constraint if exists analytics_events_schema_version_check;
alter table public.analytics_events add constraint analytics_events_schema_version_check check (schema_version in (1, 2, 3, 4));
alter table public.analytics_events drop constraint if exists analytics_events_ai_timing_check;
alter table public.analytics_events add constraint analytics_events_ai_timing_check check (
  (response_time_ms is null and latency_ms is null and streaming_time_ms is null)
  or (
    schema_version = 4 and request_id is not null
    and name in ('ai_request_completed', 'ai_request_failed', 'ai_request_cancelled')
    and response_time_ms is not null and response_time_ms between 0 and 86400000
    and (
      (name <> 'ai_request_completed' and latency_ms is null and streaming_time_ms is null)
      or (latency_ms is not null and streaming_time_ms is not null
        and latency_ms between 0 and 86400000 and streaming_time_ms between 0 and 86400000
        and response_time_ms = latency_ms + streaming_time_ms)
    )
  )
);

create or replace function public.analytics_ingest(p_events jsonb, p_country_code text)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_installation uuid;
  v_stored integer;
  v_new_count integer;
begin
  if jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) not between 1 and 50 then
    raise exception 'Invalid event batch';
  end if;
  if p_country_code is not null and not (p_country_code = any(string_to_array('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW', ' '))) then
    raise exception 'Invalid country observation';
  end if;
  if (select count(distinct (e->>'installation_id')::uuid) from jsonb_array_elements(p_events) e) <> 1 then
    raise exception 'One installation is required';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_events) as e(occurred_at timestamptz)
    where e.occurred_at is null or e.occurred_at < now() - interval '90 days 5 minutes'
      or e.occurred_at > now() + interval '5 minutes'
  ) then
    raise exception 'Event timestamp outside accepted window';
  end if;
  v_installation := (p_events->0->>'installation_id')::uuid;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_installation::text, 0));
  select count(distinct (e->>'id')::uuid) into v_new_count
  from jsonb_array_elements(p_events) e
  where not exists (select 1 from public.analytics_events stored where stored.id = (e->>'id')::uuid);
  if v_new_count > 0 and (
    v_new_count + (select count(*) from public.analytics_events where installation_id = v_installation and received_at > now() - interval '1 minute') > 240
    or v_new_count + (select count(*) from public.analytics_events where installation_id = v_installation and received_at > now() - interval '24 hours') > 10000) then
    return jsonb_build_object('rate_limited', true, 'stored', 0);
  end if;

  with inserted as (
    insert into public.analytics_events (
      id, installation_id, session_id, occurred_at, name, duration_seconds,
      platform, app_version, app_build, content_type, error_category, request_id, schema_version,
      response_time_ms, latency_ms, streaming_time_ms
    )
    select distinct on (e.id)
      e.id, e.installation_id, e.session_id, e.occurred_at, e.name, e.duration_seconds,
      e.properties->>'platform', e.properties->>'version', e.properties->>'build',
      e.properties->>'content_type', e.properties->>'error_category',
      (e.properties->>'request_id')::uuid, coalesce((e.properties->>'schema_version')::smallint, 1),
      (e.properties->>'response_time_ms')::integer, (e.properties->>'latency_ms')::integer,
      (e.properties->>'streaming_time_ms')::integer
    from jsonb_to_recordset(p_events) as e (
      id uuid, installation_id uuid, session_id uuid, occurred_at timestamptz,
      name text, duration_seconds integer, properties jsonb
    )
    on conflict (id) do nothing
    returning id, installation_id, occurred_at
  ), registry as (
    insert into public.analytics_installations (installation_id, first_seen, last_seen)
    select installation_id, min(occurred_at), max(occurred_at) from inserted group by installation_id
    on conflict (installation_id) do update
      set first_seen = least(analytics_installations.first_seen, excluded.first_seen),
          last_seen = greatest(analytics_installations.last_seen, excluded.last_seen)
  ), observation as (
    insert into public.analytics_country_observations (event_id, installation_id, country_code)
    select id, installation_id, p_country_code from inserted order by id limit 1
  )
  select count(*) into v_stored from inserted;
  return jsonb_build_object('rate_limited', false, 'stored', v_stored);
end;
$$;

-- Retain the exact legacy RPC signature for older deployments and SQL callers.
create or replace function public.analytics_ingest(p_events jsonb)
returns jsonb language sql security invoker set search_path = ''
as $$ select public.analytics_ingest(p_events, null::text); $$;

create or replace function public.analytics_dashboard(p_days integer default 30, p_now timestamptz default now())
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_previous_start timestamptz;
  v_previous_end timestamptz;
  v_result jsonb;
  v_server_metrics jsonb;
begin
  if p_days is null or p_days not in (7, 30, 90) or p_now is null then raise exception 'Invalid analytics period'; end if;
  v_start := ((p_now at time zone 'UTC')::date - (p_days - 1))::timestamp at time zone 'UTC';
  v_previous_start := v_start - (p_days * interval '24 hours');
  v_previous_end := p_now - (p_days * interval '24 hours');
  with window_events as materialized (
    select *, occurred_at >= v_start as is_current
    from public.analytics_events
    where (occurred_at >= v_start and occurred_at < p_now)
      or (occurred_at >= v_previous_start and occurred_at < v_previous_end)
  ), metrics as (
    select periods.is_current,
      count(distinct e.installation_id) as active_users,
      count(distinct e.installation_id) filter (where e.name in ('reading_started', 'reading_heartbeat', 'page_turned')) as readers,
      count(distinct e.installation_id) filter (where e.name in ('ai_request_started', 'ai_request_completed', 'ai_request_failed', 'ai_request_cancelled')) as ai_users,
      coalesce(sum(e.duration_seconds) filter (where e.name = 'reading_heartbeat'), 0) as reading_seconds,
      count(distinct (e.installation_id, e.session_id)) filter (where e.id is not null) as sessions,
      count(*) filter (where e.name = 'ai_request_started') as ai_requests,
      count(*) filter (where e.name = 'ai_request_completed') as ai_completed,
      count(*) filter (where e.name = 'ai_request_failed') as ai_failed
    from (values (true), (false)) as periods(is_current)
    left join window_events e on e.is_current = periods.is_current
    group by periods.is_current
  ), new_devices as (
    select
      count(*) filter (where first_seen >= v_start and first_seen < p_now) as current_count,
      count(*) filter (where first_seen >= v_previous_start and first_seen < v_previous_end) as previous_count
    from public.analytics_installations
    where first_seen >= v_previous_start and first_seen < p_now
  ), daily as (
    select dates.day::date as date,
      count(distinct e.installation_id) as active_users,
      count(distinct e.installation_id) filter (where e.name in ('reading_started', 'reading_heartbeat', 'page_turned')) as readers,
      count(distinct e.installation_id) filter (where e.name in ('ai_request_started', 'ai_request_completed', 'ai_request_failed', 'ai_request_cancelled')) as ai_users,
      coalesce(sum(e.duration_seconds) filter (where e.name = 'reading_heartbeat'), 0) as reading_seconds,
      count(*) filter (where e.name = 'ai_request_started') as ai_requests
    from generate_series(v_start at time zone 'UTC', (p_now at time zone 'UTC')::date::timestamp, interval '1 day') as dates(day)
    left join window_events e on e.is_current and (e.occurred_at at time zone 'UTC')::date = dates.day::date
    group by dates.day order by dates.day
  ), features as (
    select names.name, count(e.id) as count, count(distinct e.installation_id) as users
    from unnest(array[
      'reading_started', 'page_turned', 'book_imported', 'highlight_created', 'note_saved',
      'sketch_saved', 'web_opened', 'ai_request_started', 'ai_request_completed', 'ai_request_failed', 'ai_request_cancelled',
      'note_created', 'note_edit_session', 'sketch_created', 'sketch_edit_session',
      'reminder_created', 'reminder_updated', 'reminder_completed', 'reminder_reopened',
      'reminder_deleted', 'reminder_restored', 'reminder_opened', 'sketch_opened', 'sketch_deleted',
      'audio_recording_started', 'audio_recording_paused', 'audio_recording_resumed',
      'audio_recording_saved', 'audio_recording_discarded', 'audio_recording_failed',
      'tts_listening_started', 'tts_listening_paused', 'tts_listening_resumed',
      'tts_listening_stopped', 'tts_listening_completed', 'tts_listening_failed'
    ]) as names(name)
    left join window_events e on e.is_current and e.name = names.name
    group by names.name order by count(e.id) desc, names.name
  ), latest_versions as (
    select distinct on (installation_id) installation_id, coalesce(app_version, 'Unknown') as version
    from window_events where is_current
    order by installation_id, occurred_at desc, id
  ), versions as (
    select version, count(*) as users from latest_versions
    group by version order by count(*) desc, version limit 10
  ), recent as (
    select (occurred_at at time zone 'UTC')::date as date, name, count(*) as count
    from window_events where is_current and name not in ('app_active', 'reading_heartbeat', 'audio_recording_heartbeat', 'tts_listening_heartbeat')
    group by (occurred_at at time zone 'UTC')::date, name
    order by date desc, count(*) desc, name limit 12
  ), returning_devices as (
    select periods.is_current, count(distinct e.installation_id) as users
    from (values (true, v_start), (false, v_previous_start)) as periods(is_current, starts_at)
    left join window_events e on e.is_current = periods.is_current
    join public.analytics_installations i on i.installation_id = e.installation_id and i.first_seen < periods.starts_at
    group by periods.is_current
  ), active_installations as (
    select installation_id, bool_or(schema_version >= 2) as instrumented,
      bool_or(schema_version >= 3) as feature_instrumented,
      bool_or(schema_version >= 4) as timing_instrumented
    from window_events where is_current group by installation_id
  ), previous_installations as (
    select installation_id, bool_or(schema_version >= 2) as instrumented,
      bool_or(schema_version >= 3) as feature_instrumented,
      bool_or(schema_version >= 4) as timing_instrumented
    from window_events where not is_current group by installation_id
  ), feature_groups as (
    select groups.*,
      array(select value from jsonb_each_text(groups.metric_events))
        || case when groups.heartbeat is null then array[]::text[] else array[groups.heartbeat] end as event_names
    from (values
      ('reminders', 3, '{"created":"reminder_created","updated":"reminder_updated","completed":"reminder_completed","reopened":"reminder_reopened","deleted":"reminder_deleted","restored":"reminder_restored","opened":"reminder_opened"}'::jsonb, null::text),
      ('sketching', 2, '{"created":"sketch_created","edit_sessions":"sketch_edit_session","opened":"sketch_opened","deleted":"sketch_deleted"}'::jsonb, null::text),
      ('recording', 3, '{"started":"audio_recording_started","saved":"audio_recording_saved","discarded":"audio_recording_discarded","paused":"audio_recording_paused","resumed":"audio_recording_resumed","failed":"audio_recording_failed"}'::jsonb, 'audio_recording_heartbeat'),
      ('listening', 3, '{"started":"tts_listening_started","paused":"tts_listening_paused","resumed":"tts_listening_resumed","stopped":"tts_listening_stopped","completed":"tts_listening_completed","failed":"tts_listening_failed"}'::jsonb, 'tts_listening_heartbeat')
    ) as groups(name, minimum_schema, metric_events, heartbeat)
  ), feature_event_counts as (
    select name,
      count(*) filter (where is_current) as current_count,
      count(*) filter (where not is_current) as previous_count
    from window_events group by name
  ), feature_group_activity as (
    select groups.name, periods.is_current,
      count(distinct e.installation_id) as devices,
      coalesce(sum(e.duration_seconds) filter (where e.name = groups.heartbeat), 0) as seconds
    from feature_groups groups cross join (values (true), (false)) as periods(is_current)
    left join window_events e on e.is_current = periods.is_current and e.name = any(groups.event_names)
    group by groups.name, groups.heartbeat, periods.is_current
  ), feature_usage as (
    select groups.name,
      jsonb_build_object(
        'available', exists(select 1 from active_installations where case when groups.minimum_schema = 2 then instrumented else feature_instrumented end),
        'previous_available', exists(select 1 from previous_installations where case when groups.minimum_schema = 2 then instrumented else feature_instrumented end),
        'devices', jsonb_build_object('value', c.devices, 'previous', p.devices)
      ) || (
        select jsonb_object_agg(metric.key, jsonb_build_object('value', coalesce(t.current_count, 0), 'previous', coalesce(t.previous_count, 0)))
        from jsonb_each_text(groups.metric_events) metric
        left join feature_event_counts t on t.name = metric.value
      ) || case when groups.heartbeat is null then '{}'::jsonb
        else jsonb_build_object('seconds', jsonb_build_object('value', c.seconds, 'previous', p.seconds)) end as totals
    from feature_groups groups
    join feature_group_activity c on c.name = groups.name and c.is_current
    join feature_group_activity p on p.name = groups.name and not p.is_current
  ), latest_countries as (
    select a.installation_id, location.country_code
    from active_installations a
    left join lateral (
      select o.country_code from public.analytics_country_observations o
      where o.installation_id = a.installation_id and o.observed_at >= v_start and o.observed_at < p_now
      order by o.observed_at desc, o.event_id desc limit 1
    ) location on true
  ), countries as (
    select country_code, count(*) as devices from latest_countries
    group by country_code order by count(*) desc, country_code nulls last
  ), all_ai_starts as materialized (
    select distinct on (installation_id, request_id) installation_id, request_id, occurred_at, id
    from public.analytics_events
    where name = 'ai_request_started' and request_id is not null and occurred_at < p_now
    order by installation_id, request_id, occurred_at, id
  ), cohort as (
    select * from all_ai_starts where occurred_at >= v_start
  ), outcomes as materialized (
    select s.installation_id, s.request_id, terminal.name,
      terminal.response_time_ms, terminal.latency_ms, terminal.streaming_time_ms
    from cohort s
    left join lateral (
      select e.name, e.response_time_ms, e.latency_ms, e.streaming_time_ms from public.analytics_events e
      where e.installation_id = s.installation_id and e.request_id = s.request_id
        and e.name in ('ai_request_completed', 'ai_request_failed', 'ai_request_cancelled')
        and e.occurred_at >= s.occurred_at and e.occurred_at < p_now
      order by e.occurred_at, e.id limit 1
    ) terminal on true
  ), performance_outcomes as materialized (
    select name, response_time_ms, latency_ms, streaming_time_ms from outcomes
    where response_time_ms is not null
  ), performance_stats as (
    select outcome.name, metric.name as metric,
      count(value.milliseconds) as samples,
      avg(value.milliseconds) as average,
      percentile_cont(0.5) within group (order by value.milliseconds) as p50,
      percentile_cont(0.95) within group (order by value.milliseconds) as p95
    from (values ('completed'), ('failed'), ('cancelled')) as outcome(name)
    cross join (values ('response_time_ms'), ('latency_ms'), ('streaming_time_ms')) as metric(name)
    left join performance_outcomes o on o.name = 'ai_request_' || outcome.name
    cross join lateral (select case metric.name when 'response_time_ms' then o.response_time_ms
      when 'latency_ms' then o.latency_ms else o.streaming_time_ms end as milliseconds) value
    group by outcome.name, metric.name
  ), performance_groups as (
    select name, jsonb_build_object('requests', max(samples) filter (where metric = 'response_time_ms'))
      || jsonb_object_agg(metric, jsonb_build_object('samples', samples, 'average', average, 'p50', p50, 'p95', p95)) as totals
    from performance_stats group by name
  ), ai_outcomes as (
    select count(*) as correlated_started,
      count(*) filter (where name = 'ai_request_completed') as completed,
      count(*) filter (where name = 'ai_request_failed') as failed,
      count(*) filter (where name = 'ai_request_cancelled') as cancelled,
      count(*) filter (where name is null) as unknown
    from outcomes
  ), legacy_ai as (
    select count(*) as started from window_events
    where is_current and name = 'ai_request_started' and request_id is null
  )
  select jsonb_build_object(
    'generated_at', p_now, 'days', p_days,
    'period', jsonb_build_object('start', v_start, 'end', p_now, 'previous_start', v_previous_start, 'previous_end', v_previous_end),
    'summary', jsonb_build_object(
      'active_users', jsonb_build_object('value', c.active_users, 'previous', p.active_users),
      'readers', jsonb_build_object('value', c.readers, 'previous', p.readers),
      'ai_users', jsonb_build_object('value', c.ai_users, 'previous', p.ai_users),
      'reading_seconds', jsonb_build_object('value', c.reading_seconds, 'previous', p.reading_seconds),
      'new_users', jsonb_build_object('value', n.current_count, 'previous', n.previous_count),
      'returning_users', jsonb_build_object('value', coalesce((select users from returning_devices where is_current), 0), 'previous', coalesce((select users from returning_devices where not is_current), 0)),
      'sessions', jsonb_build_object('value', c.sessions, 'previous', p.sessions),
      'ai_requests', jsonb_build_object('value', c.ai_requests, 'previous', p.ai_requests),
      'ai_completed', jsonb_build_object('value', c.ai_completed, 'previous', p.ai_completed),
      'ai_failed', jsonb_build_object('value', c.ai_failed, 'previous', p.ai_failed)
    ),
    'coverage', jsonb_build_object(
      'first_event_at', (select min(occurred_at) from public.analytics_events where occurred_at < p_now),
      'last_received_at', (select max(received_at) from public.analytics_events where received_at < p_now),
      'instrumented_devices', (select count(*) from active_installations where instrumented),
      'legacy_devices', (select count(*) from active_installations where not instrumented),
      'semantic_features_available', exists(select 1 from active_installations where instrumented),
      'feature_usage_devices', (select count(*) from active_installations where feature_instrumented),
      'feature_usage_legacy_devices', (select count(*) from active_installations where not feature_instrumented),
      'feature_usage_available', exists(select 1 from active_installations where feature_instrumented),
      'feature_usage_previous_available', exists(select 1 from previous_installations where feature_instrumented)
    ),
    'feature_usage', (select jsonb_object_agg(name, totals) from feature_usage),
    'ai_performance', jsonb_build_object(
      'available', exists(select 1 from active_installations where timing_instrumented),
      'previous_available', exists(select 1 from previous_installations where timing_instrumented),
      'coverage', jsonb_build_object(
        'devices', (select count(*) from active_installations where timing_instrumented),
        'older_devices', (select count(*) from active_installations where not timing_instrumented)
      )
    ) || (select jsonb_object_agg(name, totals) from performance_groups),
    'ai_outcomes', (select jsonb_build_object(
      'started', a.correlated_started + l.started, 'completed', a.completed, 'failed', a.failed,
      'cancelled', a.cancelled, 'unknown', a.unknown + l.started, 'legacy_started', l.started
    ) from ai_outcomes a cross join legacy_ai l),
    'countries', coalesce((select jsonb_agg(to_jsonb(countries) order by devices desc, country_code nulls last) from countries), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(to_jsonb(daily) order by date) from daily), '[]'::jsonb),
    'features', coalesce((select jsonb_agg(to_jsonb(features) order by count desc, name) from features), '[]'::jsonb),
    'versions', coalesce((select jsonb_agg(to_jsonb(versions) order by users desc, version) from versions), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(to_jsonb(recent) order by date desc, count desc, name) from recent), '[]'::jsonb)
  ) into v_result
  from metrics c cross join metrics p cross join new_devices n
  where c.is_current and not p.is_current;
  -- Preserve the optional pre-existing history panel without creating or
  -- expanding any account/billing access. Fresh telemetry-only installs omit it.
  if to_regprocedure('analytics_private.server_usage_metrics(integer,timestamp with time zone)') is not null then
    execute 'select analytics_private.server_usage_metrics($1, $2)' into v_server_metrics using p_days, p_now;
    v_result := v_result || jsonb_build_object('server_metrics', v_server_metrics);
  end if;
  return v_result;
end;
$$;

-- No new table or privilege is needed. Existing service-only RPC access and
-- RLS stay in place; the request lookup reuses analytics_events_request_idx.
alter table public.analytics_events enable row level security;
revoke all on public.analytics_events from public, anon, authenticated;
revoke all on function public.analytics_ingest(jsonb), public.analytics_ingest(jsonb, text), public.analytics_dashboard(integer, timestamptz) from public, anon, authenticated;
grant execute on function public.analytics_ingest(jsonb), public.analytics_ingest(jsonb, text), public.analytics_dashboard(integer, timestamptz) to service_role;

commit;
