# Reporting performance

What the batch methods cost, what still grows with a report, and what to do
about it. The numbers come from a developer workstation on SQLite (see
[measuring](#measuring)). Use them to compare shapes and options, not as
latency promises.

## Use the batch methods

`report`, `analyze_scope`, `analyze_many`, and `compare_many` load history for
all their records together, so their query count depends on the associations
you ask for, not on how many records you report on. Calling `compare`,
`analyze`, or `reify` in a loop does the same work once per record.

Most association shapes are read from stored history without building a
model instance for each past state. A `report` over the last hour that asks
for one association, at 1, 5, and 20 records:

| Association | Queries | `reify` calls |
| --- | --- | --- |
| None | 9 / 9 / 9 | 0 |
| `has_many` | 17 / 17 / 17 | 0 |
| `belongs_to` | 15 / 15 / 15 | 0 |
| A `has_many` scope of plain conditions, or a default scope | 17 / 17 / 17 | 0 |
| `has_many :through` | 25 / 25 / 25 | 0 |
| Polymorphic `belongs_to` | 19 / 19 / 19 | 0 |
| `has_many :through` with `source_type:` | 25 / 25 / 25 | 0 |
| A `has_many` with `order(:id).limit(1)` | 18 / 22 / 37 | 0 |
| A scope that takes the owner, read with PT-AT | 29 / 77 / 257 | 9 / 45 / 180 |
| None, with a querying `after_initialize` | 13 / 29 / 89 | 2 / 10 / 40 |
| None, with a callable `historical_filter:` that queries | 15 / 19 / 34 | 2 / 10 / 40 |

The last four rows grow with the number of records, for the reasons in
[what costs a query per record](#what-costs-a-query-per-record).

## What still grows

Flat query counts do not make a report's cost flat:

- **Ruby work grows with the history you report on.** Every version in the
  window is decoded and compared: an `analyze_scope` of articles with five
  updates each took about 1.5 ms per article, and one article with 5,000
  updates took 1.2 s.
- **Memory grows with the number of records.** A `report` of 1,000 articles
  with their comments, replies, and author peaked at about 100 KB per
  article. `limit:` is a safety ceiling, not a page size, so to bound memory,
  page with the relation (`Article.where(...).order(:id).limit(200)`), or
  report on shorter windows.
- **A wide collection in an activity timeline grows with its size times its
  changes.** Each step copies the collection's list of records, so an
  activity timeline over `n` comments that changed `m` times does about
  `n × m` work: 800 comments edited 1,000 times took about 3 s. `timeline`, which has a step per
  version of the root rather than per change, does less.
- **`snapshots: true` and `recorded_changes: true` cost memory and time.** Ask
  for them only when you use them.

## Database indexes

On a large version table, add both indexes from the
[README](../README.md#performance-and-defaults). Without the second, every
`since:` or `within:` report reads all of the model's versions to find the
records that changed: with 5 million versions on PostgreSQL, about 230 ms per
report instead of 2 ms. [Database indexes](architecture.md#database-indexes)
explains why.

## What costs a query per record

- **A path PT-AT reads.** History cannot read a few scopes, such as one that
  takes the owner, SQL text, or a `limit` ordered by a string. PT-AT reads
  those, one record at a time and only approximately, so every method refuses
  them unless you pass `allow_approximate: true`. See
  [costly associations](reference.md#costly-associations).
- **A limited association on the current record.** Active Record's `preload`
  applies a `limit` or `offset` across all the records it loads, so each
  record's limited association is loaded on its own: one query per record.
  The deprecated `reload_live_endpoints: false` does the same for one you
  preloaded.
- **Your own code.** Model callbacks that query, such as an `after_initialize`,
  custom attribute types, and a callable `historical_filter:` run for each
  state they are given.

## Selecting by past values

`historical_filter:` reads the window's history of the records the relation
selects, and of deleted records, which a relation cannot test. A hash of
attributes is read straight from stored history. A callable is given a model
instance for each state, so it costs a `reify` per version, plus its own
queries. `max_filter_versions:` (10,000 by default) caps the versions it loads.
Either way, every version of every candidate in the window is decoded: with
1,000 candidates and no match, a hash and a callable each took about 0.8 s.
Finding the relation's records among the candidates takes up to two queries
per 250 of them.

## Large reports

- Report on a window with `since:` or `within:`, not on all history.
- Page with the relation, and set `limit:` a little above the page size, so a
  page that grew raises instead of running long.
- Ask only for the associations the report shows.
- For a dashboard, run the report in a background job and keep the result.

## Measuring

From a repository checkout (the scripts are not in the installed gem):

```console
mise exec -- bundle exec ruby benchmark/investigation/reconstruction.rb comments 20
mise exec -- bundle exec ruby benchmark/reporting.rb --case many_roots --samples 3
```

`reconstruction.rb` prints the queries, `reify` calls, and model instances
one `report` makes for a scenario and a number of records; the table above
comes from its scenarios. `PTD_PROBE_ALLOW_APPROXIMATE=1` passes
`allow_approximate: true`.
`reporting.rb` times `analyze_scope` over articles with no associations, each
in a fresh process, and records memory; `--output` keeps the raw samples.
Both use an in-memory SQLite database, never your application's. Compare
counts as well as times, and run the correctness suites separately; no CI
job checks timings.

The numbers here were measured on 2026-10-30 at revision `6c3d30b` with Ruby
4.0.1, Active Record 8.1.3.1, PaperTrail 17.0.0, and SQLite 3.53.2, on WSL2
on an AMD Ryzen 7 7800X3D. The memory, wide-collection, and index figures come
from one-off scripts rather than these two. The benchmark's raw samples are in
[`benchmark/results/reporting-2026-10-30.json`](../benchmark/results/reporting-2026-10-30.json),
next to earlier runs.
