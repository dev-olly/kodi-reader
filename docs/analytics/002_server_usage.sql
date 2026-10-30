-- Apply after 001_analytics.sql, as the database owner.
-- Read-only aggregate access to existing auth / AI credit history. No source
-- tables, account records, credit balances, or client privileges are changed.
begin;

create schema if not exists analytics_private;
revoke all on schema analytics_private from public, anon, authenticated;
grant usage on schema analytics_private to service_role;

-- Existing auth / billing tables are deliberately inaccessible to service_role.
-- This private helper exposes only fixed aggregates, never rows or identifiers.
-- Authorization is its service-role-only EXECUTE grant: administrative requests
-- do not have an auth.uid(), so user-level ownership checks do not apply here.
create or replace function analytics_private.server_usage_metrics(p_days integer, p_now timestamptz)
returns jsonb
language plpgsql
stable
security definer
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

  with accounts as materialized (
    select id, created_at, last_sign_in_at from auth.users
    where deleted_at is null and created_at < p_now
  ), credit_accounts as materialized (
    select a.id from kodi_private.accounts a
    join accounts u on u.id = a.auth_user_id
    where a.deleted_at is null and a.created_at < p_now
  ), ai_history as materialized (
    select l.account_id, l.kind, l.created_at
    from kodi_private.ledger l join credit_accounts a on a.id = l.account_id
    where l.kind in ('reserve', 'answer', 'release') and l.created_at < p_now
  ), account_metrics as (
    select periods.is_current,
      count(*) filter (where u.created_at >= periods.starts_at and u.created_at < periods.ends_at) as new_accounts,
      count(*) filter (where u.last_sign_in_at >= periods.starts_at and u.last_sign_in_at < periods.ends_at) as signed_in_accounts
    from (values (true, v_start, p_now), (false, v_previous_start, v_previous_end)) as periods(is_current, starts_at, ends_at)
    left join accounts u on true
    group by periods.is_current
  ), ai_metrics as (
    select periods.is_current,
      count(distinct l.account_id) filter (where l.kind = 'reserve') as ai_accounts,
      count(*) filter (where l.kind = 'reserve') as ai_requests,
      count(*) filter (where l.kind = 'answer') as ai_charged,
      count(*) filter (where l.kind = 'release') as ai_released
    from (values (true, v_start, p_now), (false, v_previous_start, v_previous_end)) as periods(is_current, starts_at, ends_at)
    left join ai_history l on l.created_at >= periods.starts_at and l.created_at < periods.ends_at
    group by periods.is_current
  ), activity as materialized (
    select u.created_at, 'account_created'::text as name, null::uuid as ai_account_id
    from accounts u where u.created_at >= v_start
    union all
    select l.created_at,
      case l.kind when 'reserve' then 'ai_request_reserved' when 'answer' then 'ai_request_charged' else 'ai_request_released' end,
      case when l.kind = 'reserve' then l.account_id end
    from ai_history l where l.created_at >= v_start
  ), daily as (
    select dates.day::date as date,
      count(*) filter (where a.name = 'account_created') as new_accounts,
      count(distinct a.ai_account_id) as ai_accounts,
      count(*) filter (where a.name = 'ai_request_reserved') as ai_requests,
      count(*) filter (where a.name = 'ai_request_charged') as ai_charged,
      count(*) filter (where a.name = 'ai_request_released') as ai_released
    from generate_series(v_start at time zone 'UTC', (p_now at time zone 'UTC')::date::timestamp, interval '1 day') as dates(day)
    left join activity a on (a.created_at at time zone 'UTC')::date = dates.day::date
    group by dates.day order by dates.day
  ), recent as (
    select (created_at at time zone 'UTC')::date as date, name, count(*) as count
    from activity group by (created_at at time zone 'UTC')::date, name
    order by date desc, count(*) desc, name limit 12
  )
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'registered_accounts', (select count(*) from accounts),
      'credit_accounts', (select count(*) from credit_accounts),
      'ai_accounts', (select count(distinct account_id) from ai_history where kind = 'reserve'),
      'ai_requests', (select count(*) from ai_history where kind = 'reserve'),
      'ai_charged', (select count(*) from ai_history where kind = 'answer')
    ),
    'summary', jsonb_build_object(
      'new_accounts', jsonb_build_object('value', a.new_accounts, 'previous', b.new_accounts),
      'signed_in_accounts', jsonb_build_object('value', a.signed_in_accounts, 'previous', b.signed_in_accounts),
      'ai_accounts', jsonb_build_object('value', c.ai_accounts, 'previous', p.ai_accounts),
      'ai_requests', jsonb_build_object('value', c.ai_requests, 'previous', p.ai_requests),
      'ai_charged', jsonb_build_object('value', c.ai_charged, 'previous', p.ai_charged),
      'ai_released', jsonb_build_object('value', c.ai_released, 'previous', p.ai_released)
    ),
    'daily', coalesce((select jsonb_agg(to_jsonb(daily) order by date) from daily), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(to_jsonb(recent) order by date desc, count desc, name) from recent), '[]'::jsonb)
  ) into v_result
  from account_metrics a cross join account_metrics b cross join ai_metrics c cross join ai_metrics p
  where a.is_current and not b.is_current and c.is_current and not p.is_current;
  return v_result;
end;
$$;

revoke all on function analytics_private.server_usage_metrics(integer, timestamptz) from public, anon, authenticated;
grant execute on function analytics_private.server_usage_metrics(integer, timestamptz) to service_role;

-- The public RPC remains SECURITY INVOKER. Its definition below preserves all
-- telemetry calculations and appends the separately named server_metrics.

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
  return v_result || jsonb_build_object('server_metrics', analytics_private.server_usage_metrics(p_days, p_now));
end;
$$;

revoke all on function public.analytics_dashboard(integer, timestamptz) from public, anon, authenticated;
grant execute on function public.analytics_dashboard(integer, timestamptz) to service_role;

commit;
