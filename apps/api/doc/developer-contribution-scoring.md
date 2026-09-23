# Developer Contribution Scoring Model

This document defines the scoring model requested in issue #32. It extends the existing
PullRequestEvent-based ranking without replacing unrelated ranking surfaces.

## Goals

- Produce a numeric contribution score and deterministic rank per developer.
- Support both one ecosystem and all-Web3 scopes.
- Avoid counting repeated lifecycle events for the same pull request as separate work.
- Reduce the weight of old work while making inactivity rules explicit.
- Keep the SQL practical for the 10B+ row `data.events` table.

## Canonical contribution unit

A contribution is one distinct pull request authored by an actor in an eligible repository.
The PR identity is read from `payload.pull_request.id`; if it is absent, the event id is used
as a conservative fallback so malformed historical rows never collapse unrelated work.

Multiple `PullRequestEvent` rows for the same PR are collapsed to one contribution.
The contribution timestamp is the latest event observed for that PR inside the lookback window.
A merged PR receives 5 raw points; any other PR receives 1 raw point. The maximum state seen for
the PR wins, so an opened-then-merged PR scores once, not twice.
## Time and inactivity

The query is anchored to an explicit `as_of` timestamp rather than `NOW()`, which makes
backfills and benchmarks reproducible.

Parameters:

- `lookback_days`: history eligible for scoring; default recommendation 365.
- `active_window_days`: developer must have at least one contribution this recently; default 180.
- `half_life_days`: exponential score half-life; default 180.
- `repo_cap`: maximum raw points from one actor/repository pair before decay; default 50.

For a contribution with age `d` days, the decay multiplier is:

`power(0.5, d / half_life_days)`

The inactivity rule is deliberately separate from decay. Decay changes score continuously;
the activity window determines whether an actor appears in the current ranking at all.

## Ecosystem semantics

For an ecosystem score, a repository is eligible when `data.repos.upstream_marks` contains
that ecosystem key. A repository tagged to multiple ecosystems may contribute independently to
each ecosystem's ranking.

For the Web3-wide score, each repository is included once regardless of how many ecosystem
keys it carries. This prevents one pull request from being multiplied by taxonomy overlap.
## Ranking

Scores are summed after the per-repository raw-point cap. Ranking uses `ROW_NUMBER()` over:

1. decayed score descending,
2. raw points descending,
3. actor id ascending as a stable tie-break key.

The actor id is the final stable tie-break key, so ranks are deterministic even when scores tie.
The SQL also returns `last_contribution_at` so consumers can display freshness and audit the
inactivity decision.

Bot filtering follows the existing service behavior and excludes common login patterns:
`%[bot]%`, `bot-%`, `%-bot`, and `Copilot`.

## Performance strategy

The query filters `data.events` by event type and time before JSON extraction, and it builds the
eligible repository set before joining to the event table.

Recommended production indexes should be evaluated with `EXPLAIN (ANALYZE, BUFFERS)` before
being created on the production dataset:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_pr_created_repo_actor
ON data.events (created_at, repo_id, actor_id)
WHERE event_type = 'PullRequestEvent';
```

The repository table should have an index on `repo_id`; JSONB ecosystem filtering can benefit
from a GIN index on `upstream_marks` if one is not already present.
## Benchmark protocol

The implementation accepts all time parameters explicitly. For the issue's "within one hour"
requirement, run the query against the agreed production-like data volume with:

```sql
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
-- paste the parameterized query from scripts/developer-contribution-score.sql
```

Record PostgreSQL version, row counts for `data.events` and `data.repos`, the parameter values,
execution time, rows removed by filters, buffer reads/hits, and the final plan.

No production credentials or raw user data are required in the report. A maintainer can provide
the sanitized plan and timing when the full dataset is not available to contributors.

## Edge cases covered by the model

- repeated opened/synchronize/closed events for one PR count once;
- a PR promoted from open to merged receives the merged weight once;
- multi-ecosystem repositories do not multiply the all-Web3 score;
- inactive actors are omitted even if they have old decayed score;
- actors tied on score receive deterministic ordering;
- missing PR ids fall back to event ids instead of collapsing rows.

The model is intentionally limited to pull requests because that is the contribution signal the
current ranking service already uses. Adding reviews, issues, pushes, or commits should be a
separate policy decision with independently agreed weights and anti-gaming rules.
