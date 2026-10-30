-- Read-only aggregate export for the local preview, using an already authorized
-- Supabase administrator connection. No DDL, credentials, account IDs, or content.
-- Save the returned snapshot JSON to the ignored .analytics-local/snapshot.json.
with capture as (select now() as at),
windows as (
 select d.days,c.at,
 (c.at at time zone 'UTC')::date-(d.days-1) as first_day,
 ((c.at at time zone 'UTC')::date-(d.days-1))::timestamp at time zone 'UTC' as start_at,
 (((c.at at time zone 'UTC')::date-(d.days-1))::timestamp at time zone 'UTC')-make_interval(days=>d.days) as prev_start,
 c.at-make_interval(days=>d.days) as prev_end
 from capture c cross join (values(7),(30),(90)) d(days)
),
users_active as (select id,created_at,last_sign_in_at from auth.users where deleted_at is null),
accounts_active as (select a.id from kodi_private.accounts a join users_active u on u.id=a.auth_user_id where a.deleted_at is null),
l as (select account_id,kind,created_at from kodi_private.ledger where kind in ('reserve','answer','release') and account_id in (select id from accounts_active)),
totals as (select jsonb_build_object(
 'registered_accounts',(select count(*) from users_active),
 'credit_accounts',(select count(*) from accounts_active),
 'ai_accounts',(select count(distinct account_id) from l where kind='reserve'),
 'ai_requests',(select count(*) from l where kind='reserve'),
 'ai_charged',(select count(*) from l where kind='answer')
) as data),
periods as (
 select w.days,
 public.analytics_dashboard(w.days) || jsonb_build_object('server_metrics',jsonb_build_object(
 'totals',t.data,
 'summary',jsonb_build_object(
 'new_accounts',jsonb_build_object('value',(select count(*) from users_active where created_at >= w.start_at and created_at < w.at),'previous',(select count(*) from users_active where created_at>=w.prev_start and created_at<w.prev_end)),
 'signed_in_accounts',jsonb_build_object('value',(select count(*) from users_active where last_sign_in_at >= w.start_at and last_sign_in_at < w.at),'previous',(select count(*) from users_active where last_sign_in_at>=w.prev_start and last_sign_in_at<w.prev_end)),
 'ai_accounts',jsonb_build_object('value',(select count(distinct account_id) from l where kind='reserve' and created_at >= w.start_at and created_at < w.at),'previous',(select count(distinct account_id) from l where kind='reserve' and created_at>=w.prev_start and created_at<w.prev_end)),
 'ai_requests',jsonb_build_object('value',(select count(*) from l where kind='reserve' and created_at >= w.start_at and created_at < w.at),'previous',(select count(*) from l where kind='reserve' and created_at>=w.prev_start and created_at<w.prev_end)),
 'ai_charged',jsonb_build_object('value',(select count(*) from l where kind='answer' and created_at >= w.start_at and created_at < w.at),'previous',(select count(*) from l where kind='answer' and created_at>=w.prev_start and created_at<w.prev_end)),
 'ai_released',jsonb_build_object('value',(select count(*) from l where kind='release' and created_at >= w.start_at and created_at < w.at),'previous',(select count(*) from l where kind='release' and created_at>=w.prev_start and created_at<w.prev_end))
 ),
 'daily',(select jsonb_agg(jsonb_build_object(
  'date',dt::date,
  'new_accounts',(select count(*) from users_active where (created_at at time zone 'UTC')::date=dt::date and created_at<=w.at),
  'ai_accounts',(select count(distinct account_id) from l where kind='reserve' and (created_at at time zone 'UTC')::date=dt::date and created_at<=w.at),
  'ai_requests',(select count(*) from l where kind='reserve' and (created_at at time zone 'UTC')::date=dt::date and created_at<=w.at),
  'ai_charged',(select count(*) from l where kind='answer' and (created_at at time zone 'UTC')::date=dt::date and created_at<=w.at),
  'ai_released',(select count(*) from l where kind='release' and (created_at at time zone 'UTC')::date=dt::date and created_at<=w.at)
 ) order by dt) from generate_series(w.first_day::timestamp,(w.at at time zone 'UTC')::date::timestamp,interval '1 day') dt),
 'recent',(select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) from (
   select date,name,count(*) as count from (
     select (created_at at time zone 'UTC')::date as date,'account_created' as name from users_active where created_at >= w.start_at and created_at < w.at
     union all select (created_at at time zone 'UTC')::date,case kind when 'reserve' then 'ai_request_reserved' when 'answer' then 'ai_request_charged' else 'ai_request_released' end from l where created_at >= w.start_at and created_at < w.at
   ) e group by date,name order by date desc,name limit 12
 ) r)
 )) as data from windows w cross join totals t
)
select jsonb_build_object('version',1,'captured_at',(select at from capture),'periods',(select jsonb_object_agg(days::text,data) from periods)) as snapshot;
