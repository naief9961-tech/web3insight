-- Developer contribution scoring model for issue #32.
-- Parameters:
--   $1::text[]      ecosystem names to score (for example ARRAY['ethereum','solana'])
--   $2::timestamptz reproducible as-of timestamp
--   $3::integer     lookback days
--   $4::integer     active-window days
--   $5::numeric     score half-life in days
--   $6::numeric     maximum raw points per actor/repository pair
--
-- Returns one row per active actor and scope. "__web3__" is the all-Web3 scope.

WITH ecosystem_list AS (
  SELECT UNNEST($1::text[]) AS ecosystem_name
),
params AS (
  SELECT
    $2::timestamptz AS as_of,
    $3::integer AS lookback_days,
    $4::integer AS active_window_days,
    $5::numeric AS half_life_days,
    $6::numeric AS repo_cap
),
eligible_repos AS (
  SELECT
    ecosystem.ecosystem_name AS scope_name,
    repos.repo_id
  FROM data.repos repos
  CROSS JOIN ecosystem_list ecosystem
  WHERE repos.upstream_marks ? ecosystem.ecosystem_name
  UNION ALL

  SELECT
    '__web3__'::text AS scope_name,
    repos.repo_id
  FROM data.repos repos
  WHERE repos.upstream_marks IS NOT NULL
    AND repos.upstream_marks <> '{}'::jsonb
),
pr_events AS (
  SELECT
    eligible.scope_name,
    events.actor_id,
    events.repo_id,
    COALESCE(
      events.payload -> 'pull_request' ->> 'id',
      'event:' || events.id::text
    ) AS pr_key,
    events.created_at,
    CASE
      WHEN COALESCE(
        (events.payload -> 'pull_request' ->> 'merged')::boolean,
        false
      ) THEN 5::numeric
      ELSE 1::numeric
    END AS raw_points
  FROM eligible_repos eligible
  JOIN data.events events
    ON events.repo_id = eligible.repo_id
  CROSS JOIN params
  WHERE events.event_type = 'PullRequestEvent'
    AND events.created_at >=
      params.as_of - make_interval(days => params.lookback_days)
    AND events.created_at <= params.as_of
),
deduplicated_prs AS (
  SELECT
    scope_name,
    actor_id,
    repo_id,
    pr_key,
    MAX(raw_points) AS raw_points,
    MAX(created_at) AS contributed_at
  FROM pr_events
  GROUP BY scope_name, actor_id, repo_id, pr_key
),
weighted_prs AS (
  SELECT
    deduplicated.scope_name,
    deduplicated.actor_id,
    deduplicated.repo_id,
    deduplicated.raw_points,
    deduplicated.contributed_at,
    deduplicated.raw_points * POWER(
      0.5::double precision,
      EXTRACT(EPOCH FROM (params.as_of - deduplicated.contributed_at))
        / 86400.0
        / params.half_life_days::double precision
    ) AS decayed_points
  FROM deduplicated_prs deduplicated
  CROSS JOIN params
),
per_repo AS (
  SELECT
    weighted.scope_name,
    weighted.actor_id,
    weighted.repo_id,
    LEAST(SUM(weighted.raw_points), params.repo_cap) AS raw_points,
    SUM(weighted.decayed_points) * LEAST(
      1.0,
      params.repo_cap::double precision
        / NULLIF(SUM(weighted.raw_points)::double precision, 0.0)
    ) AS decayed_score,
    MAX(weighted.contributed_at) AS last_contribution_at
  FROM weighted_prs weighted
  CROSS JOIN params
  GROUP BY
    weighted.scope_name,
    weighted.actor_id,
    weighted.repo_id,
    params.repo_cap
),
actor_scores AS (
  SELECT
    per_repo.scope_name,
    per_repo.actor_id,
    actors.actor_login,
    SUM(per_repo.raw_points) AS raw_points,
    SUM(per_repo.decayed_score) AS contribution_score,
    MAX(per_repo.last_contribution_at) AS last_contribution_at
  FROM per_repo
  JOIN data.actors actors
    ON actors.actor_id = per_repo.actor_id
  CROSS JOIN params
  WHERE actors.actor_login NOT ILIKE '%[bot]%'
    AND actors.actor_login NOT ILIKE 'bot-%'
    AND actors.actor_login NOT ILIKE '%-bot'
    AND actors.actor_login NOT ILIKE 'Copilot'
    AND per_repo.last_contribution_at >=
      params.as_of - make_interval(days => params.active_window_days)
  GROUP BY per_repo.scope_name, per_repo.actor_id, actors.actor_login
),
ranked AS (
  SELECT
    actor_scores.scope_name,
    actor_scores.actor_id,
    actor_scores.actor_login,
    actor_scores.raw_points,
    actor_scores.contribution_score,
    actor_scores.last_contribution_at,
    ROW_NUMBER() OVER (
      PARTITION BY actor_scores.scope_name
      ORDER BY
        actor_scores.contribution_score DESC,
        actor_scores.raw_points DESC,
        actor_scores.actor_id ASC
    ) AS rank
  FROM actor_scores
)
SELECT
  CASE WHEN scope_name = '__web3__' THEN 'web3' ELSE 'ecosystem' END AS scope_type,
  scope_name,
  rank,
  actor_id,
  actor_login,
  raw_points,
  ROUND(contribution_score::numeric, 6) AS contribution_score,
  last_contribution_at
FROM ranked
ORDER BY scope_type, scope_name, rank;
