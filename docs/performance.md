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
| None | 6 / 6 / 6 | 0 |
| `has_many` | 13 / 13 / 13 | 0 |
| `belongs_to` | 13 / 13 / 13 | 0 |
| A `has_many` scope of plain conditions, or a default scope | 13 / 13 / 13 | 0 |
| `has_many :through` | 19 / 19 / 19 | 0 |
| Polymorphic `belongs_to` | 17 / 17 / 17 | 0 |
| `has_many :through` with `source_type:` | 21 / 21 / 21 | 0 |
| A `has_many` with `order(:id).limit(1)` | 14 / 18 / 33 | 0 |
| A scope that takes the owner, read with PT-AT | 25 / 73 / 253 | 9 / 45 / 180 |
| None, with a querying `after_initialize` | 10 / 26 / 86 | 2 / 10 / 40 |
| None, with a callable `historical_filter:` that queries | 11 / 15 / 30 | 2 / 10 / 40 |

The last four rows grow with the number of records, for the reasons in
[what costs a query per record](#what-costs-a-query-per-record).

The counts leave out transaction statements. On PostgreSQL and MySQL each call
also runs in one snapshot transaction, which adds two or three statements per
call whatever its size. On SQL Server a call first checks whether the
database allows snapshot isolation, in one statement, and when it does, runs
in a snapshot transaction too. See [limitations](reference.md#limitations).

## What still grows

Flat query counts do not make a report's cost flat:

- **Ruby work grows with the history you report on.** Every version in the
  window is decoded and compared: an `analyze_scope` of articles with five
  updates each took about 1.5 ms per article, and one article with 5,000
  updates took 1.2 s.
- **Versions stored as JSON read about 40% faster than YAML.** A `report` on
  500 articles with 31 versions each took 7.9 s with PaperTrail's default
  YAML serializer and 4.5 s with its JSON one, or 14.5 s and 8.6 s with their
  comments, and peaked at a fifth to a quarter less memory. JSON keeps times
  to milliseconds and stores a few values differently (see
  [history stored as JSON](reference.md#history-stored-as-json)). PaperTrail
  reads every stored version with the one serializer, so switching means
  converting the versions already saved.
- **Memory grows with the number of records.** A `report` of 1,000 articles
  with their comments, replies, and author peaked at about 100 KB per
  article. `limit:` is a safety ceiling, not a page size, so to bound memory,
  page with the relation (`Article.where(...).order(:id).limit(200)`), or
  report on shorter windows.
- **Work on a wide collection grows with its size times its history.** Each
  step of an activity timeline copies the collection's list of records, so
  an activity timeline over `n` comments that changed `m` times does about
  `n × m` work: 800 comments edited 1,000 times took about 3 s. `timeline`
  reads every member at each version of the root instead: 300 comments over
  2,001 versions of their article took about 7.5 s.
- **`snapshots: true` and `recorded_changes: true` cost memory and time.** Ask
  for them only when you use them.
- **Each edge of a window takes one to three statements per 500 records.** A
  window from `within:` or `since:` looks for transactions that cross either
  edge, and with associations also for those that saved a record before it
  and an associated record after it. A `report` window has no end, so only
  its start is read. With associations, it also takes one statement per 500
  of the transactions its history reads, to find one that saved associated
  records on both sides of its start; when it finds one, it reads the
  window's history again from where that transaction began. On 1.4 million
  versions, both edges of a window over 10,800 records took about 6 s on SQL
  Server and 1.5 s on PostgreSQL and MySQL.
- **`version_scope:` on activity reads every version in the range**, as
  activity without one does. With associations, it takes one more statement
  per 500 of the transactions its history reads, to find those the filter
  keeps a version of.

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
per 500 of them, and with PT-AT, finding where their windows move one to three
statements per edge for each 500.

The relation then reads the records that matched in pages of up to 2,000, and
each page lists every matching id, so the relation keeps its own order,
`limit`, and `offset`. A version table whose `item_id` does not share the key's
type selects records the same way. SQL Server compiles each such statement
afresh: with 10,000 matching records, each page took about 0.7 s, 5 s of a
12 s report, and with about 20,000 a page can outlast the adapter's default
timeout of 5 seconds. Narrow the window, or page with the relation.

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
Both use an in-memory SQLite database, never your application's, and read
time from the [test clock](testing.md#test-clock), so a host clock that steps
backwards cannot reorder the versions they seed. Compare counts as well as
times, and run the correctness suites separately; no CI job checks timings.

The query counts in the first table, the `timeline` of 300 comments, and the
serializers were measured on 2026-11-03, the counts after `report`'s window
lost its end; the other numbers on 2026-10-30 at revision `6c3d30b`. Both used
Ruby 4.0.1, Active Record 8.1.3.1, PaperTrail 17.0.0, and SQLite 3.53.2, on
WSL2 on an AMD Ryzen 7 7800X3D. The memory, wide-collection, serializer, and
index figures come from one-off scripts rather than these two. The benchmark's
raw samples are in
[`benchmark/results/reporting-2026-10-30.json`](../benchmark/results/reporting-2026-10-30.json),
next to earlier runs.
