-- Apply after 001_analytics.sql. 002_server_usage.sql is optional and is NOT
-- required: this migration never grants access to account or billing records.
-- Country observations describe a connection at upload time, never where an
-- offline event occurred. Only the Vercel collector supplies p_country_code.
begin;

alter table public.analytics_events add column if not exists request_id uuid;
alter table public.analytics_events add column if not exists schema_version smallint not null default 1;
alter table public.analytics_events drop constraint if exists analytics_events_name_check;
alter table public.analytics_events add constraint analytics_events_name_check check (name in ('app_active', 'reading_started', 'reading_heartbeat', 'page_turned', 'book_imported', 'highlight_created', 'note_saved', 'sketch_saved', 'web_opened', 'ai_request_started', 'ai_request_completed', 'ai_request_failed', 'note_created', 'note_edit_session', 'sketch_created', 'sketch_edit_session', 'ai_request_cancelled'));
alter table public.analytics_events drop constraint if exists analytics_events_schema_version_check;
alter table public.analytics_events add constraint analytics_events_schema_version_check check (schema_version in (1, 2));
alter table public.analytics_events drop constraint if exists analytics_events_request_id_check;
alter table public.analytics_events add constraint analytics_events_request_id_check check (
  (request_id is null or name in ('ai_request_started', 'ai_request_completed', 'ai_request_failed', 'ai_request_cancelled'))
  and (schema_version < 2 or name not in ('ai_request_started', 'ai_request_completed', 'ai_request_failed', 'ai_request_cancelled') or request_id is not null)
);
create index if not exists analytics_events_request_idx on public.analytics_events (installation_id, request_id, occurred_at, id) where request_id is not null;

-- One observation per newly stored upload. Its immutable event anchor means a
-- retried event cannot update country, and normal event retention removes it.
create table if not exists public.analytics_country_observations (
  event_id uuid primary key references public.analytics_events(id) on delete cascade,
  installation_id uuid not null,
  observed_at timestamptz not null default now(),
  country_code text check (country_code is null or country_code = any(string_to_array('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW', ' ')))
);
create index if not exists analytics_country_observations_installation_time_idx
  on public.analytics_country_observations (installation_id, observed_at desc, event_id);
alter table public.analytics_country_observations enable row level security;
revoke all on public.analytics_country_observations from public, anon, authenticated;
grant select, insert, delete on public.analytics_country_observations to service_role;

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
      platform, app_version, app_build, content_type, error_category, request_id, schema_version
    )
    select distinct on (e.id)
      e.id, e.installation_id, e.session_id, e.occurred_at, e.name, e.duration_seconds,
      e.properties->>'platform', e.properties->>'version', e.properties->>'build',
      e.properties->>'content_type', e.properties->>'error_category',
      (e.properties->>'request_id')::uuid, coalesce((e.properties->>'schema_version')::smallint, 1)
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
      'note_created', 'note_edit_session', 'sketch_created', 'sketch_edit_session'
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
    from window_events where is_current and name not in ('app_active', 'reading_heartbeat')
    group by (occurred_at at time zone 'UTC')::date, name
    order by date desc, count(*) desc, name limit 12
  ), returning_devices as (
    select periods.is_current, count(distinct e.installation_id) as users
    from (values (true, v_start), (false, v_previous_start)) as periods(is_current, starts_at)
    left join window_events e on e.is_current = periods.is_current
    join public.analytics_installations i on i.installation_id = e.installation_id and i.first_seen < periods.starts_at
    group by periods.is_current
  ), active_installations as (
    select installation_id, bool_or(schema_version >= 2) as instrumented
    from window_events where is_current group by installation_id
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
  ), outcomes as (
    select s.installation_id, s.request_id, terminal.name
    from cohort s
    left join lateral (
      select e.name from public.analytics_events e
      where e.installation_id = s.installation_id and e.request_id = s.request_id
        and e.name in ('ai_request_completed', 'ai_request_failed', 'ai_request_cancelled')
        and e.occurred_at >= s.occurred_at and e.occurred_at < p_now
      order by e.occurred_at, e.id limit 1
    ) terminal on true
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
      'semantic_features_available', exists(select 1 from active_installations where instrumented)
    ),
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

revoke all on function public.analytics_ingest(jsonb), public.analytics_ingest(jsonb, text), public.analytics_dashboard(integer, timestamptz) from public, anon, authenticated;
grant execute on function public.analytics_ingest(jsonb), public.analytics_ingest(jsonb, text), public.analytics_dashboard(integer, timestamptz) to service_role;

commit;
