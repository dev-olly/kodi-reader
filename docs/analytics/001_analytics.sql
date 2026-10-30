-- Apply once in the Supabase SQL editor. No existing application tables are changed.
begin;

create table if not exists public.analytics_installations (
  installation_id uuid primary key,
  first_seen timestamptz not null,
  last_seen timestamptz not null
);

create table if not exists public.analytics_events (
  id uuid primary key,
  installation_id uuid not null,
  session_id uuid not null,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  name text not null check (name in (
    'app_active', 'reading_started', 'reading_heartbeat', 'page_turned',
    'book_imported', 'highlight_created', 'note_saved', 'sketch_saved',
    'web_opened', 'ai_request_started', 'ai_request_completed', 'ai_request_failed'
  )),
  duration_seconds integer,
  platform text check (platform in ('macOS', 'iOS', 'web')),
  app_version text check (app_version ~ '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$'),
  app_build text check (app_build ~ '^(unknown|[0-9]{1,10}(\.[0-9]{1,10}){0,3})$'),
  content_type text check (content_type in ('epub', 'pdf', 'web')),
  error_category text check (error_category in ('network', 'authentication', 'credits', 'service', 'rate_limit', 'provider', 'cancelled', 'unknown')),
  check ((name = 'reading_heartbeat' and duration_seconds is not null and duration_seconds between 1 and 60)
    or (name <> 'reading_heartbeat' and duration_seconds is null)),
  check (occurred_at > '2020-01-01'::timestamptz and occurred_at <= received_at + interval '5 minutes')
);

create index if not exists analytics_events_occurred_at_idx on public.analytics_events (occurred_at);
create index if not exists analytics_events_installation_received_idx on public.analytics_events (installation_id, received_at);
create index if not exists analytics_installations_first_seen_idx on public.analytics_installations (first_seen);
create index if not exists analytics_installations_last_seen_idx on public.analytics_installations (last_seen);

alter table public.analytics_events enable row level security;
alter table public.analytics_installations enable row level security;
-- No browser or signed-in app user may read or write these tables directly.
revoke all on public.analytics_events, public.analytics_installations from public, anon, authenticated;
grant select, insert, update, delete on public.analytics_events, public.analytics_installations to service_role;

create or replace function public.analytics_ingest(p_events jsonb)
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
  if (select count(distinct (e->>'installation_id')::uuid) from jsonb_array_elements(p_events) e) <> 1 then
    raise exception 'One installation is required';
  end if;
  -- Reject a batch atomically instead of silently dropping old events. Five minutes
  -- of grace avoids a validation race between the API clock and the database clock.
  if exists (
    select 1 from jsonb_to_recordset(p_events) as e(occurred_at timestamptz)
    where e.occurred_at is null or e.occurred_at < now() - interval '90 days 5 minutes'
      or e.occurred_at > now() + interval '5 minutes'
  ) then
    raise exception 'Event timestamp outside accepted window';
  end if;
  v_installation := (p_events->0->>'installation_id')::uuid;
  -- Serialize concurrent requests for the same installation; this is shared across functions.
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
      platform, app_version, app_build, content_type, error_category
    )
    select distinct on (e.id)
      e.id, e.installation_id, e.session_id, e.occurred_at, e.name, e.duration_seconds,
      e.properties->>'platform', e.properties->>'version', e.properties->>'build',
      e.properties->>'content_type', e.properties->>'error_category'
    from jsonb_to_recordset(p_events) as e (
      id uuid, installation_id uuid, session_id uuid, occurred_at timestamptz,
      name text, duration_seconds integer, properties jsonb
    )
    on conflict (id) do nothing
    returning installation_id, occurred_at
  ), registry as (
    insert into public.analytics_installations (installation_id, first_seen, last_seen)
    select installation_id, min(occurred_at), max(occurred_at) from inserted group by installation_id
    on conflict (installation_id) do update
      set first_seen = least(analytics_installations.first_seen, excluded.first_seen),
          last_seen = greatest(analytics_installations.last_seen, excluded.last_seen)
  )
  select count(*) into v_stored from inserted;
  return jsonb_build_object('rate_limited', false, 'stored', v_stored);
end;
$$;

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
      count(distinct e.installation_id) filter (where e.name in ('ai_request_started', 'ai_request_completed', 'ai_request_failed')) as ai_users,
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
      count(distinct e.installation_id) filter (where e.name in ('ai_request_started', 'ai_request_completed', 'ai_request_failed')) as ai_users,
      coalesce(sum(e.duration_seconds) filter (where e.name = 'reading_heartbeat'), 0) as reading_seconds,
      count(*) filter (where e.name = 'ai_request_started') as ai_requests
    from generate_series(v_start at time zone 'UTC', (p_now at time zone 'UTC')::date::timestamp, interval '1 day') as dates(day)
    left join window_events e on e.is_current and (e.occurred_at at time zone 'UTC')::date = dates.day::date
    group by dates.day order by dates.day
  ), features as (
    select names.name, count(e.id) as count, count(distinct e.installation_id) as users
    from unnest(array[
      'reading_started', 'page_turned', 'book_imported', 'highlight_created', 'note_saved',
      'sketch_saved', 'web_opened', 'ai_request_started', 'ai_request_completed', 'ai_request_failed'
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
      'sessions', jsonb_build_object('value', c.sessions, 'previous', p.sessions),
      'ai_requests', jsonb_build_object('value', c.ai_requests, 'previous', p.ai_requests),
      'ai_completed', jsonb_build_object('value', c.ai_completed, 'previous', p.ai_completed),
      'ai_failed', jsonb_build_object('value', c.ai_failed, 'previous', p.ai_failed)
    ),
    'daily', coalesce((select jsonb_agg(to_jsonb(daily) order by date) from daily), '[]'::jsonb),
    'features', coalesce((select jsonb_agg(to_jsonb(features) order by count desc, name) from features), '[]'::jsonb),
    'versions', coalesce((select jsonb_agg(to_jsonb(versions) order by users desc, version) from versions), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(to_jsonb(recent) order by date desc, count desc, name) from recent), '[]'::jsonb)
  ) into v_result
  from metrics c cross join metrics p cross join new_devices n
  where c.is_current and not p.is_current;
  return v_result;
end;
$$;

create or replace function public.analytics_prune(p_now timestamptz default now())
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_events integer; v_installations integer;
begin
  delete from public.analytics_events where occurred_at < p_now - interval '180 days';
  get diagnostics v_events = row_count;
  delete from public.analytics_installations where last_seen < p_now - interval '180 days';
  get diagnostics v_installations = row_count;
  return jsonb_build_object('events_deleted', v_events, 'installations_deleted', v_installations);
end;
$$;

revoke all on function public.analytics_ingest(jsonb), public.analytics_dashboard(integer, timestamptz), public.analytics_prune(timestamptz) from public, anon, authenticated;
grant execute on function public.analytics_ingest(jsonb), public.analytics_dashboard(integer, timestamptz), public.analytics_prune(timestamptz) to service_role;

commit;

-- REQUIRED retention setup: enable pg_cron in Supabase Database > Extensions,
-- then run once (or invoke analytics_prune daily through your existing scheduler):
-- select cron.schedule('analytics-retention', '20 3 * * *', $$select public.analytics_prune();$$);
-- Verify: select jobid, jobname, schedule, active from cron.job where jobname = 'analytics-retention';
-- Verify execution in cron.job_run_details. Without this job, retention is not automatic.
