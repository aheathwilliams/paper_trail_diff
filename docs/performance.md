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
  updates took 1.2 s. A `report` of 1,000 articles with their comments, from
  a table of 114,000 versions, took about 4 ms an article on SQLite,
  PostgreSQL, and MySQL, and 5.5 ms on SQL Server, most of it in Ruby.
- **Versions stored as JSON read about a third faster than YAML.** A `report`
  on 500 articles with 31 versions each took 6.8 s with PaperTrail's default
  YAML serializer and 4.5 s with its JSON one, or 9.8 s and 6.7 s with their
  comments, and peaked at up to a fifth less memory. JSON keeps times
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
  `n × m` work: 800 comments edited 1,000 times took about 0.4 s, and 3,200
  edited 3,200 times about 1.8 s. A transaction that saves several records
  costs the same for each: its versions are applied to the records they
  saved at the event after its last, so 1,000 comments edited two at a time
  in 1,000 transactions took 1.9 s, and edited one at a time along with
  their article, 1.0 s. A record that joins a collection or leaves it costs
  a little more than an edit, because each such event also looks through the
  collection for the record as it stood before: 1,000 comments created one
  at a time on one article took about 0.7 s, and 3,000 about 3.6 s. Members
  saved in one transaction share one snapshot: a `report` on 100 articles,
  each created with 100 comments in one transaction and edited with all of
  them in another, took about 4.6 s. `timeline` reads every member at each
  version of the root instead: 300 comments over 2,001 versions of their
  article took about 7.5 s.
- **`snapshots: true` and `recorded_changes: true` cost memory and time.** Ask
  for them only when you use them. Records that did not change are shared
  between steps, so the cost is modest: an activity `report` of 10,000
  articles with their 57,000 comments (114,000 versions, 49,000 steps) took
  about 40 s and held 372 MB, and 411 MB with snapshots, at the same
  time within run-to-run noise. Folding its rows with `net_changes` took
  another 17 s, and listing them with `change_rows` 13 s.
- **A window with associations looks for the transactions open at its
  start.** A window reports the transactions that end inside it, so its
  history is asked where the earliest transaction open at its start began,
  whatever records it saved. That takes one statement per version table, and
  one per 500 transactions its history holds, to read where each ends. When
  one was open, the window's history is read once more, from where the
  earliest began. The
  statement for the start reads the versions saved since the window began
  that were not the first of their transaction, and no index of the README
  serves that. On SQLite, in a table of a million versions with the README's
  indexes and PT-AT's on `transaction_id`, it took 0.06 s for a window that
  began 1% of the table ago, 0.18 s for one that began half of it ago, and
  0.27 s for one that began near its start. An index on `created_at` alone
  took the first to 0.006 s and left the others as they were. `analyze_scope`
  and `report` run it once more, to select the records such a transaction
  saved before the window. A read without associations runs none of these
  statements, with a window or not.
- **A read with associations reads where its transactions end**, with
  `activity: true` or without. A
  transaction takes effect at the last version it saved, of any record, so a
  history asks its version table for the last version of each transaction it
  holds: one statement per 500 transactions, and one more when some of those
  versions are of records it does not hold. Each reads by `transaction_id`,
  which PT-AT indexes: in the same table, the ends of 10,000 transactions
  took 0.11 s in 20 statements, and 0.19 s in 40 when none of their last
  versions was held. With several version tables, one more
  statement per table per 500 finds the numbers two tables both gave a
  transaction.
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

Selecting a report's records does not grow with the model's own table. The
records changed in the window and deleted since are found with `NOT EXISTS`,
which every database plans as an anti-join. With 2 million articles on
PostgreSQL 17 and 2,000 of them edited in the window, that statement took 3 ms
and the `report` 1.4 s. Asked with `NOT IN`, which PostgreSQL reads the whole
table for, it took 14.8 s of a 16 s report, and 9.7 s of 11 s with 500,000
articles.

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
A relation with a `limit` reads candidates in its own order and stops when
its page is full: of 5,000 matching records with three versions each, the
first page of 20 took 0.09 s and the page at offset 2,000 took 0.4 s, where
reading every match took 1.0 s.
Finding the relation's records among the candidates takes up to two queries
per 500 of them.

The relation then reads the records that matched in pages of up to 2,000, and
each page lists every matching id, so the relation keeps its own order,
`limit`, and `offset`. A version table whose `item_id` does not share the key's
type selects records the same way. On SQL Server, more than 500 matching
records are first written to a temporary table, in statements of 1,000 rows,
and each page selects from it instead of listing them, since SQL Server
compiles a statement with its ids written in afresh. The table is dropped
when the selection ends. A read that prevents writes, as a replica read
through Rails' automatic role switching does, lists the ids instead, since
Active Record counts the table's statements as writes. On a local SQL Server 2022 container, with the plan
cache cleared before each run:

| Matching records | Listing every id | Temporary table |
| --- | --- | --- |
| 10,000, selection only | 5.0 s | 0.6 s |
| 20,000, selection only | 29.7 s | 1.1 s |
| 40,000, selection only | not run | 2.2 s |
| 10,000, `analyze_scope` with `historical_filter:` | 11.5 s, 4.3 s of it in pages | 7.4 s, 0.1 s in pages |

The `analyze_scope` row is the mean of three runs; the rest are one run each.
Other databases still list the ids on each page, which they parse quickly.

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
`reporting.rb` times `analyze_scope` over articles with no associations and,
as `association_window`, a `report` over articles with their comments read
through PT-AT, each in a fresh process, and records memory; `--output` keeps
the raw samples. Both use an in-memory SQLite database, never your
application's, and read time from the [test clock](testing.md#test-clock), so
a host clock that steps backwards cannot reorder the versions they seed.
Compare counts as well as times, and run the correctness suites separately.
No CI job checks timings, but one spec bounds how a report's SQL grows with
its window (see [SQL work](testing.md#sql-work)).

The query counts in the first table and the `timeline` of 300 comments were
measured on 2026-11-03, the counts after `report`'s window lost its end; the
serializers and the snapshot and net change costs on 2026-11-04; the other
numbers on 2026-10-30 at revision `6c3d30b`. Both used Ruby 4.0.1, Active
Record 8.1.3.1, PaperTrail 17.0.0, and SQLite 3.53.2, on WSL2 on an AMD
Ryzen 7 7800X3D. The per-database `report` costs were measured on 2026-11-04
with Ruby 4.0.9 in Docker, on SQLite, PostgreSQL 17.11, MySQL 8.4.13, and SQL
Server 2022, each holding the same rows. The memory, wide-collection,
serializer, snapshot, per-database, and index figures come from one-off
scripts rather than these two. The benchmark's
raw samples are in
[`benchmark/results/reporting-2026-10-30.json`](../benchmark/results/reporting-2026-10-30.json),
next to earlier runs.
