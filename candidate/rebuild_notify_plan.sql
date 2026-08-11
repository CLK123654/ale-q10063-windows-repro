PRAGMA foreign_keys=ON;

DROP TABLE IF EXISTS candidate_decision;
DROP TABLE IF EXISTS send_plan;
DROP TABLE IF EXISTS suppression_audit;
DROP TABLE IF EXISTS campaign_quota_report;
DROP TABLE IF EXISTS repair_meta;

CREATE TABLE candidate_decision AS
WITH base AS (
  SELECT
    c.event_id,
    c.user_id,
    c.campaign_id,
    c.channel,
    c.requested_at_utc,
    c.dedupe_key,
    c.idempotency_key,
    s.status AS subscriber_status,
    s.tier,
    s.timezone_offset_min,
    s.quiet_start_local,
    s.quiet_end_local,
    r.priority,
    r.daily_cap,
    r.campaign_cap,
    r.dedupe_minutes,
    r.allowed_tiers_json,
    time(datetime(c.requested_at_utc,printf('%+d minutes',coalesce(s.timezone_offset_min,0)))) AS local_time,
    h.provider_message_id AS existing_provider_message_id,
    o.reason AS override_reason
  FROM candidate_queue AS c
  LEFT JOIN subscribers AS s ON s.user_id=c.user_id
  LEFT JOIN campaign_rules AS r ON r.campaign_id=c.campaign_id AND r.channel=c.channel
  LEFT JOIN delivery_history AS h ON h.provider_message_id=c.idempotency_key
  LEFT JOIN suppression_overrides AS o
    ON o.user_id=c.user_id
   AND o.campaign_id=c.campaign_id
   AND julianday(c.requested_at_utc)<julianday(o.until_utc)
),
base_reasoned AS (
  SELECT
    b.*,
    CASE
      WHEN b.subscriber_status IS NULL THEN 'unknown_user'
      WHEN b.priority IS NULL THEN 'unknown_campaign'
      WHEN b.existing_provider_message_id IS NOT NULL THEN 'already_delivered'
      WHEN b.subscriber_status<>'active' THEN 'subscriber_paused'
      WHEN b.override_reason IS NOT NULL THEN 'manual_suppression'
      WHEN NOT EXISTS (SELECT 1 FROM json_each(b.allowed_tiers_json) WHERE value=b.tier) THEN 'tier_not_allowed'
      WHEN CASE
        WHEN b.quiet_start_local>b.quiet_end_local
          THEN b.local_time>=b.quiet_start_local OR b.local_time<b.quiet_end_local
        ELSE b.local_time>=b.quiet_start_local AND b.local_time<b.quiet_end_local
      END THEN 'quiet_hours'
      ELSE NULL
    END AS base_reason
  FROM base AS b
),
deduped AS (
  SELECT
    current.*,
    CASE
      WHEN current.base_reason IS NULL
       AND EXISTS (
         SELECT 1
         FROM base_reasoned AS prior
         WHERE prior.base_reason IS NULL
           AND prior.user_id=current.user_id
           AND prior.campaign_id=current.campaign_id
           AND prior.channel=current.channel
           AND prior.dedupe_key=current.dedupe_key
           AND (
             julianday(prior.requested_at_utc)<julianday(current.requested_at_utc)
             OR (prior.requested_at_utc=current.requested_at_utc AND prior.event_id<current.event_id)
           )
           AND (julianday(current.requested_at_utc)-julianday(prior.requested_at_utc))*1440<=current.dedupe_minutes
       ) THEN 'duplicate_candidate'
      ELSE current.base_reason
    END AS reason_after_dedupe
  FROM base_reasoned AS current
),
daily_sequence AS (
  SELECT
    d.*,
    (
      SELECT count(*)
      FROM delivery_history AS h
      WHERE h.user_id=d.user_id
        AND h.campaign_id=d.campaign_id
        AND date(h.sent_at_utc)=date(d.requested_at_utc)
    ) AS existing_user_daily,
    sum(CASE WHEN d.reason_after_dedupe IS NULL THEN 1 ELSE 0 END) OVER (
      PARTITION BY d.user_id,d.campaign_id,date(d.requested_at_utc)
      ORDER BY julianday(d.requested_at_utc),d.event_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS candidate_user_daily_seq
  FROM deduped AS d
),
daily_reasoned AS (
  SELECT
    d.*,
    CASE
      WHEN d.reason_after_dedupe IS NULL
       AND d.existing_user_daily+d.candidate_user_daily_seq>d.daily_cap THEN 'user_daily_cap'
      ELSE d.reason_after_dedupe
    END AS reason_after_daily
  FROM daily_sequence AS d
),
campaign_sequence AS (
  SELECT
    d.*,
    (
      SELECT count(*)
      FROM delivery_history AS h
      WHERE h.campaign_id=d.campaign_id
        AND julianday(h.sent_at_utc)>=julianday((SELECT report_start_utc FROM temp.run_contract))
        AND julianday(h.sent_at_utc)<julianday((SELECT report_end_utc FROM temp.run_contract))
    ) AS existing_campaign_sent,
    sum(CASE WHEN d.reason_after_daily IS NULL THEN 1 ELSE 0 END) OVER (
      PARTITION BY d.campaign_id
      ORDER BY d.priority DESC,julianday(d.requested_at_utc),d.event_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS candidate_campaign_seq
  FROM daily_reasoned AS d
)
SELECT
  event_id,
  user_id,
  campaign_id,
  channel,
  requested_at_utc,
  dedupe_key,
  idempotency_key,
  subscriber_status,
  tier,
  local_time,
  priority,
  daily_cap,
  campaign_cap,
  existing_user_daily,
  candidate_user_daily_seq,
  existing_campaign_sent,
  candidate_campaign_seq,
  CASE
    WHEN reason_after_daily IS NULL
     AND existing_campaign_sent+candidate_campaign_seq>campaign_cap THEN 'campaign_cap_reached'
    ELSE reason_after_daily
  END AS final_reason
FROM campaign_sequence;

CREATE UNIQUE INDEX candidate_decision_event_id_idx ON candidate_decision(event_id);

CREATE TABLE send_plan AS
SELECT
  event_id,
  user_id,
  campaign_id,
  channel,
  requested_at_utc,
  local_time,
  idempotency_key AS provider_message_id,
  priority AS send_priority,
  'send' AS action
FROM candidate_decision
WHERE final_reason IS NULL
ORDER BY priority DESC,requested_at_utc,event_id;

CREATE UNIQUE INDEX send_plan_event_id_idx ON send_plan(event_id);
CREATE UNIQUE INDEX send_plan_provider_message_id_idx ON send_plan(provider_message_id);

CREATE TABLE suppression_audit AS
SELECT
  d.event_id,
  d.user_id,
  d.campaign_id,
  d.channel,
  d.requested_at_utc,
  d.local_time,
  d.final_reason AS reason,
  p.detail
FROM candidate_decision AS d
JOIN temp.decision_policy AS p ON p.reason=d.final_reason
WHERE d.final_reason IS NOT NULL
ORDER BY d.requested_at_utc,d.event_id;

CREATE UNIQUE INDEX suppression_audit_event_id_idx ON suppression_audit(event_id);

CREATE TABLE campaign_quota_report AS
SELECT
  r.campaign_id,
  r.channel,
  r.daily_cap,
  r.campaign_cap,
  (
    SELECT count(*)
    FROM delivery_history AS h
    WHERE h.campaign_id=r.campaign_id
      AND julianday(h.sent_at_utc)>=julianday((SELECT report_start_utc FROM temp.run_contract))
      AND julianday(h.sent_at_utc)<julianday((SELECT report_end_utc FROM temp.run_contract))
  ) AS existing_sent_count,
  (SELECT count(*) FROM send_plan AS p WHERE p.campaign_id=r.campaign_id) AS planned_send_count,
  (SELECT count(*) FROM suppression_audit AS a WHERE a.campaign_id=r.campaign_id) AS suppressed_count,
  max(
    0,
    r.campaign_cap
    - (
      SELECT count(*)
      FROM delivery_history AS h
      WHERE h.campaign_id=r.campaign_id
        AND julianday(h.sent_at_utc)>=julianday((SELECT report_start_utc FROM temp.run_contract))
        AND julianday(h.sent_at_utc)<julianday((SELECT report_end_utc FROM temp.run_contract))
    )
    - (SELECT count(*) FROM send_plan AS p WHERE p.campaign_id=r.campaign_id)
  ) AS remaining_after_plan
FROM campaign_rules AS r
ORDER BY r.campaign_id;

CREATE UNIQUE INDEX campaign_quota_report_campaign_id_idx ON campaign_quota_report(campaign_id);

CREATE TABLE repair_meta(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO repair_meta
VALUES
  ('report_start_utc',(SELECT report_start_utc FROM temp.run_contract)),
  ('report_end_utc',(SELECT report_end_utc FROM temp.run_contract)),
  ('fixed_now_utc',(SELECT fixed_now_utc FROM temp.run_contract)),
  ('source_candidate_count',(SELECT count(*) FROM candidate_queue)),
  ('send_count',(SELECT count(*) FROM send_plan)),
  ('suppression_count',(SELECT count(*) FROM suppression_audit)),
  ('campaign_report_rows',(SELECT count(*) FROM campaign_quota_report));
