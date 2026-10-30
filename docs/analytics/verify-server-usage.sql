-- Disposable database only, after 001_analytics.sql and 002_server_usage.sql.
-- Fixtures verify existing account / billing history independently of telemetry.
begin;
set local time zone 'Pacific/Kiritimati';

insert into auth.users (id, created_at, last_sign_in_at, deleted_at) values
  ('00000000-0000-4000-8000-000000000001', '2026-09-01T00:00:00Z', '2026-10-24T11:00:00Z', null),
  ('00000000-0000-4000-8000-000000000002', '2026-10-20T00:00:00Z', '2026-10-21T00:00:00Z', null),
  ('00000000-0000-4000-8000-000000000003', '2026-10-15T00:00:00Z', '2026-10-16T00:00:00Z', null),
  ('00000000-0000-4000-8000-000000000004', '2026-10-21T00:00:00Z', '2026-10-22T00:00:00Z', '2026-10-23T00:00:00Z'),
  ('00000000-0000-4000-8000-000000000005', '2026-09-01T00:00:00Z', null, null);
insert into kodi_private.accounts (id, auth_user_id, created_at, deleted_at)
select id, id, created_at, case when id = '00000000-0000-4000-8000-000000000005' then '2026-10-23T00:00:00Z'::timestamptz end
from auth.users;
insert into kodi_private.accounts values ('00000000-0000-4000-8000-000000000006', null, '2026-09-01T00:00:00Z', null);
insert into kodi_private.ledger (account_id, kind, reference, created_at) values
  ('00000000-0000-4000-8000-000000000001', 'reserve', 'one', '2026-10-23T10:00:00Z'),
  ('00000000-0000-4000-8000-000000000001', 'answer', 'one', '2026-10-23T10:01:00Z'),
  ('00000000-0000-4000-8000-000000000001', 'reserve', 'two', '2026-10-24T10:00:00Z'),
  ('00000000-0000-4000-8000-000000000001', 'release', 'two', '2026-10-24T10:01:00Z'),
  ('00000000-0000-4000-8000-000000000002', 'reserve', 'three', '2026-10-20T10:00:00Z'),
  ('00000000-0000-4000-8000-000000000002', 'answer', 'three', '2026-10-20T10:01:00Z'),
  ('00000000-0000-4000-8000-000000000002', 'reserve', 'boundary', '2026-10-18T00:00:00Z'),
  ('00000000-0000-4000-8000-000000000002', 'answer', 'boundary', '2026-10-18T00:00:00Z'),
  ('00000000-0000-4000-8000-000000000003', 'reserve', 'previous', '2026-10-15T10:00:00Z'),
  ('00000000-0000-4000-8000-000000000003', 'answer', 'previous', '2026-10-15T10:01:00Z'),
  ('00000000-0000-4000-8000-000000000003', 'reserve', 'previous-partial-gap', '2026-10-17T15:00:00Z'),
  ('00000000-0000-4000-8000-000000000003', 'reserve', 'historical', '2026-09-30T10:00:00Z'),
  ('00000000-0000-4000-8000-000000000003', 'answer', 'historical', '2026-09-30T10:01:00Z'),
  ('00000000-0000-4000-8000-000000000003', 'reserve', 'future', '2026-10-24T13:00:00Z'),
  ('00000000-0000-4000-8000-000000000004', 'reserve', 'deleted-auth', '2026-10-23T10:00:00Z'),
  ('00000000-0000-4000-8000-000000000005', 'reserve', 'deleted-credit', '2026-10-23T10:00:00Z'),
  ('00000000-0000-4000-8000-000000000006', 'reserve', 'orphan', '2026-10-23T10:00:00Z');

do $$
begin
  assert not has_schema_privilege('service_role', 'kodi_private', 'USAGE'), 'private schema remains inaccessible';
  assert not has_table_privilege('service_role', 'auth.users', 'SELECT'), 'auth table remains inaccessible';
  assert not has_table_privilege('service_role', 'kodi_private.ledger', 'SELECT'), 'billing table remains inaccessible';
  assert not has_schema_privilege('anon', 'analytics_private', 'USAGE'), 'no anonymous helper schema access';
  assert not has_schema_privilege('authenticated', 'analytics_private', 'USAGE'), 'no signed-in helper schema access';
  assert not has_function_privilege('anon', 'analytics_private.server_usage_metrics(integer,timestamptz)', 'EXECUTE'), 'no anonymous helper execution';
  assert not has_function_privilege('authenticated', 'analytics_private.server_usage_metrics(integer,timestamptz)', 'EXECUTE'), 'no signed-in helper execution';
  assert not (select prosecdef from pg_proc where oid = 'public.analytics_dashboard(integer,timestamptz)'::regprocedure), 'public dashboard remains invoker';
  assert (select prosecdef from pg_proc where oid = 'analytics_private.server_usage_metrics(integer,timestamptz)'::regprocedure), 'private helper explicitly owns aggregate access';
end;
$$;

-- Exercise the actual service-role path: this fails if a grant is missing or if
-- the public invoker accidentally starts selecting private rows directly.
set local role service_role;
do $$
declare
  v_data jsonb;
  v_metrics jsonb;
begin
  v_data := public.analytics_dashboard(7, '2026-10-24T12:00:00Z');
  v_metrics := v_data->'server_metrics';
  assert v_data #>> '{summary,active_users,value}' = '0', 'account history never impersonates telemetry';
  assert v_metrics #>> '{totals,registered_accounts}' = '4', 'undeleted registered accounts';
  assert v_metrics #>> '{totals,credit_accounts}' = '3', 'undeleted credit accounts linked to current users';
  assert v_metrics #>> '{totals,ai_accounts}' = '3', 'all-time distinct AI accounts';
  assert v_metrics #>> '{totals,ai_requests}' = '7', 'all-time reservations, excluding deleted and future';
  assert v_metrics #>> '{totals,ai_charged}' = '5', 'all-time charges, never reservations twice';
  assert v_metrics #>> '{summary,new_accounts,value}' = '1', 'new accounts in period';
  assert v_metrics #>> '{summary,new_accounts,previous}' = '1', 'new accounts in previous period';
  assert v_metrics #>> '{summary,signed_in_accounts,value}' = '2', 'latest sign-in in period';
  assert v_metrics #>> '{summary,signed_in_accounts,previous}' = '1', 'latest sign-in in previous period';
  assert v_metrics #>> '{summary,ai_accounts,value}' = '2', 'current AI accounts';
  assert v_metrics #>> '{summary,ai_accounts,previous}' = '1', 'previous AI accounts';
  assert v_metrics #>> '{summary,ai_requests,value}' = '4', 'current reservations';
  assert v_metrics #>> '{summary,ai_requests,previous}' = '1', 'elapsed previous cutoff excludes later partial day';
  assert v_metrics #>> '{summary,ai_charged,value}' = '3', 'current charged requests';
  assert v_metrics #>> '{summary,ai_released,value}' = '1', 'released requests';
  assert jsonb_array_length(v_metrics->'daily') = 7, 'UTC daily calendar';
  assert v_metrics #>> '{daily,0,date}' = '2026-10-18', 'UTC first day despite session time zone';
  assert v_metrics #>> '{daily,0,ai_requests}' = '1', 'start boundary included';
  assert v_metrics #>> '{daily,6,ai_released}' = '1', 'release dated by ledger time';
  assert jsonb_array_length(public.analytics_dashboard(30, '2026-10-24T12:00:00Z') #> '{server_metrics,daily}') = 30, '30-day server calendar';
  assert jsonb_array_length(public.analytics_dashboard(90, '2026-10-24T12:00:00Z') #> '{server_metrics,daily}') = 90, '90-day server calendar';
  assert not v_metrics::text like '%00000000-0000%', 'no account identifiers returned';
end;
$$;
reset role;
rollback;
