# Changelog

All notable changes to this project will be documented in this file. The
project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Breaking changes

- `PaperTrailDiff.timeline` and `PaperTrailDiff.activity_timeline` are
  removed. Each returned what `analyze` already returns alongside its diff,
  from the same read:

  ```ruby
  PaperTrailDiff.timeline(article, **options)
  # becomes
  PaperTrailDiff.analyze(article, **options).timeline

  PaperTrailDiff.activity_timeline(article, **options)
  # becomes
  PaperTrailDiff.analyze(article, activity: true, **options).activity_timeline
  ```

  The options are the same. The `activity_timeline.paper_trail_diff`
  notification is replaced by `analyze.paper_trail_diff`, which every
  `analyze` emits, with the same payload; its `step_count` counts the
  activity timeline with `activity: true` and the root timeline without.
- `has_and_belongs_to_many` associations are no longer read. Naming one in
  `associations:`, at the root or below it, raises
  `UnsupportedAssociationError`, `association_paths` leaves it out, and
  `supported_association_macros` no longer lists it. A join table has no
  versions, so its history could only be read at the root's own
  transaction-backed versions, never up to the current record, and not at
  all with a scope or below the root. Replace it with a `has_many :through`
  a join model that has `has_paper_trail`, as
  [the reference shows](docs/reference.md#replacing-a-has_and_belongs_to_many):
  add an `id` to the join table, and put `dependent: :destroy` on the
  through association so that a member leaving saves a version. With it go
  `UnsupportedLiveActivityError`, which only a `has_and_belongs_to_many`
  raised, and the `habtm_transaction_shared`, `transaction_id_missing`, and
  `transaction_id_column_missing` codes of `diagnose`.

### Changed

- A transaction now takes effect where it saved its last version, in every
  activity timeline. A window from `within:` or `since:` reports the
  transactions that end inside it, each whole and under its own versions,
  instead of moving its edges to where a transaction began. `analysis.window`
  is therefore always the window you asked for, a step of a transaction that
  began before the window can hold a version saved before it, and a
  transaction group lists every version its transaction saved. The
  `moved_window.paper_trail_diff` notification is gone, since no window
  moves. Four things follow that you may notice:
  - `timeline`, and a window without associations, report each version of the
    record where it was saved, as before, but no longer move a window for a
    transaction that also saved an associated record.
  - `analyze_scope` and `report` select a record for a window by the versions
    saved in it. A record whose transaction saves in the window and ends after
    it is selected with nothing to report, and reported in the later window.
    With associations, a window also selects by the versions that
    transactions open at its start saved before it, since it reports those
    transactions.
  - `historical_filter:` reads each version where it was saved, so a record
    whose transaction began before the window is checked from the state its
    versions before the window left.
  - With associations and `activity: true`, a window after a destroyed
    record's last version reports nothing, or the deletion when the
    transaction that destroyed the record ends inside the window, as
    `analyze_scope` with `include_deleted: true` does. `analyze` and
    `activity_timeline` raised `IncompleteTimeRangeError` there.
- A window with associations, with `activity: true` or without, runs one
  more statement per version table, to find the transactions open at its
  start, and no longer one per 250 records
  for each edge, and `analyze_scope` and `report` run it once more to select
  their records. A read with associations runs one more statement per 500
  transactions its history holds, to read where each ends. See
  [performance](docs/performance.md#what-still-grows).

- On SQL Server, a selection that reads its candidates in Ruby, as one with
  `historical_filter:` or a version table whose `item_id` does not share the
  key's type does, writes more than 500 of them to a temporary table once and
  reads each page from it, instead of listing every id on every page. A
  selection of 10,000 records took 0.6 s instead of 5 s, and one of 20,000
  took 1.1 s instead of 30 s. A read that prevents writes, such as a replica
  read through Rails' automatic role switching, still lists the ids, since
  Active Record counts the table's statements as writes.

- An activity timeline no longer reads a whole association again for each
  event of a transaction that saved more than one record in the tree, such
  as two comments, or a comment and the article it touches. Each of the
  transaction's versions is applied to the record it saved, as a version
  alone in its transaction already was. One article with 1,000 comments and
  1,000 transactions that each edited two of them took 1.9 s instead of
  20.6 s, and 1.0 s instead of 18.8 s when each edited one comment and the
  article. Results are unchanged.

- Replaying a `has_many` whose membership a version did not change no
  longer sorts the collection again. A history of 3,200 comments edited
  3,200 times took 1.8 s instead of 11 s.

- Reads with associations do less work, with the same results:
  - A belongs_to target created inside an activity range no longer reads
    its owners' branch again from history unless an owner holds no target.
    An article with 1,000 comments, each given a newly created reviewer,
    took 0.97 s instead of 28.5 s for `comments.reviewer`.
  - Activity finds each owner's belongs_to targets in the states its history
    already loaded, and no longer runs two more statements per belongs_to
    path to read PT-AT's rows and the live rows.
  - A window finds where the transactions open at its start began once,
    before reading, instead of reading the window and then reading it again
    from there; `analyze_scope` and `report` share that one statement
    across record selection and every record of the model. A report with
    an unrelated open transaction ran 19 statements instead of 27.
  - `include_deleted:` with a relation that has no conditions, on a model
    that is not a subclass, asks the version table which destroys stored a
    state instead of decoding each one. 2,000 deleted articles took 37 ms
    instead of 753 ms.
  - A state read from JSON history converts only the attributes whose type
    needs it, listed once per model, and a value already frozen throughout
    is no longer walked again to keep it immutable. A report over records
    with 100-key JSON values took 2.0 s instead of 2.4 s.

- Association scopes, and ranges and orders in them, are read in Ruby only on
  the SQL column types the gem lists for each of SQLite, PostgreSQL, MySQL, and
  SQL Server, instead of on any column Active Record casts as an integer,
  boolean, string, date, or time. A column of another type, or on another
  adapter, is now refused unless you pass `allow_approximate: true`, like any
  scope the gem cannot read. On SQL Server this leaves out a legacy `datetime` or `smalldatetime` key, which
  rounds the times it stores.

- A `has_many` or `has_one` whose target declares no `belongs_to` on its
  foreign key, and a `has_many :through` with such a part, now raises
  `UnsupportedAssociationError` up front in every method. `diagnose` reports
  it as `:unsupported_association` and `association_paths` leaves it out.
  PT-AT records a record's owner on the record's own versions, once for each
  `belongs_to` it declares, so with none nothing said a record that was
  destroyed or moved away had been in the association: `compare`, timelines,
  analyses and `report` showed the records the association holds now and
  silently left out the ones that left. Declare the `belongs_to` on the
  target to request the path. Versions saved before then recorded no owner,
  so a record that left before then is still not reported.

- A version now reads alike wherever it is used: as an endpoint of
  `compare`, and as the start or the end of a range. Each reads the records
  around it as they stood before every transaction that had not ended where
  the version's own took effect, as windows already did. A range starts
  before its first version's transaction took effect and ends where its last
  version's took effect: what another transaction saved before the start is
  in the starting state if that transaction ended first, and reported in its
  own step if it ended later. `compare` used to read a version by when the
  records around it were saved, and `from:` used to count everything saved
  before it as settled. So two ranges that meet at a version now report each
  change once, as the range over both does, and a range from a version
  inside a transaction no longer reports another transaction's finished
  change as its own. A read with associations of a range of versions runs one
  more statement per version table, to find a transaction open at its start,
  and one more to find where its last version's transaction ended.
- A destroyed record's history ends where its destruction took effect. A
  window holding the destruction reports it even when another transaction
  that saved in the tree before it ends later, and a change another
  transaction committed in the tree before the destroying one ended is
  reported in the window it ended in.
- Activity on the record alone, without associations, reports each version
  where it was saved, as `timeline` does and as the reference said. A window
  edge between two saves of one transaction no longer loses the first.
- With associations, `version_scope:` selects a record in `analyze_scope`
  and `report` whenever its activity reports something: a version selects it
  when the filter keeps any version of its transaction, as activity keeps
  whole transactions.
- Values are compared in the form the database stores them, as the history
  stores them: times to the column's precision (to 1/300 s on a SQL Server
  `datetime`), MySQL `float` to single precision, SQLite decimals as the
  numbers SQLite returns, and fixed-width `char` columns padded or stripped as
  the database does. A record saved with a value the database rounds no
  longer shows a change against its own version. `historical_filter:`
  compares its expected values in the same form.
- A time of day reads in `ActiveRecord.default_timezone`, as Active Record
  stores it, including one stored as JSON text with a date and an offset.
- Errors are raised up front with the gem's own classes: `analyze_scope` and
  `report` on a model without PaperTrail raise `InvalidEndpointError`, and a
  version class without an `object` column `ConfigurationError`;
  `compare_many` with an unknown boundary symbol raises
  `InvalidTimelineRangeError`; `version_scope:` is checked where it is given,
  and must take the relation as its one argument and return it narrowed, or
  an array of its versions; `report(since:)` must be a time, date or string;
  boolean options must be `true` or `false`; a root with unsaved changes is
  refused; a version loaded without `object` is refused; and a relation that
  selects columns without the primary key raises `ConfigurationError`.
- `historical_filter:` refuses an attribute named twice, as a string and a
  symbol.
- `diagnose` raises `ReversedEndpointsError` for two versions given newest
  first, as `compare` does, instead of reporting `ok?`.
- `within:` and `since:` refuse a string that names no real day, such as
  `"12"` or `"2026-02-30"`, which `Time.zone.parse` read as noon today and
  as 2 March.
- `max_filter_versions:` is checked whether or not `historical_filter:` is
  given, and `recorded_changes` refuses a version loaded without its
  `object_changes` column instead of answering that it recorded nothing.
- `unreachable` and `deleted` list integer ids by value, so 2 comes before 10.
- A has_many or has_one read with associations runs one more statement per
  read, for the first versions of children made without a version (see
  Fixed).

### Fixed

- A date assigned to a datetime column, which Active Record leaves on the
  instance when time zone aware attributes are off or `update_columns`
  writes it, and PaperTrail stores from there, is read as midnight in
  Active Record's default time zone, as the database keeps it. It was read
  in `Time.zone`, or kept as a Date, so a version and the unchanged row
  differed.
- The digits JSON history keeps for a time are read from what its writer
  writes, a custom serializer that wraps PaperTrail's JSON one included.
  They were assumed from Active Support's setting, so such a serializer, or
  the legacy JSON format that writes whole seconds, read every unchanged
  time as changed.
- An attribute a model declares without a column, such as a form field, is
  left out of every diff, change row and snapshot, as no row holds it.
  PaperTrail stores whatever the instance held for it. `historical_filter:`
  refuses it as an unknown attribute, as `where` cannot name it.
- `historical_filter:` reads text or a date given for a datetime attribute
  as `where` does, in the database's time zone. In any zone but UTC the two
  selected different records. A value its attribute cannot take, such as a
  Hash for a time, raises `ConfigurationError` instead of Active Record's
  own error.
- `nested_changes` tells 1 from 1.0 inside arrays, as under a hash key and
  as the attribute diff does.
- In `analyze_many` and `report`, a root that sits in another root's tree
  is read there from the versions loaded for it. Its window's versions were
  used instead, so the other root could report a record that joined it
  only after the window, with the values it got then.
- `analyze_many` with associations and `activity: true` gives a root with
  no versions an empty analysis over its whole history, as `analyze` does.
  It raised `IncompleteTimeRangeError`.
- A `has_one :through` with no order reads, in history, the target of its
  first join row by key, as Active Record does, not the target with the
  lowest id. With two join rows, a diff from a past version to the
  unchanged record reported it replaced.
- Activity on a path below an association to an STI subclass no longer
  raises `UnknownAssociationError` when a child is retyped to its base class
  and back.
- `report` and `analyze_scope` select a root whose change sits below a row
  saved without versions, such as one from before PaperTrail, as `analyze`
  reports it. Such a row holds its live key throughout.
- With `version_scope:`, an analysis ends after the last change the filter
  keeps. A kept version of a record that had left the tree moved its end to
  the next event, so its `diff` and `to_snapshot` held a change the filter
  drops.
- A record moved by its own update is credited, in `change_rows`, to that
  version. Two records moved in one transaction were both credited to the
  last version the step read.
- `compare` from a version saved outside a transaction, as
  `save_with_version` saves one, reads a transaction still open there as
  open, as the range from that version does. Such a comparison runs one more
  statement, to find where the history's transactions end.
- `report` and `analyze_scope` with associations no longer select a record
  that changed only before the window while an unrelated transaction was
  open across its start. Before the start, only the versions of the
  transactions open there select a record. Such records came back with
  nothing to report, counted toward `limit:`, and a destroyed one was listed
  in `unreachable`.
- A transaction takes effect at its latest dated version, ids breaking a
  tie, and is open across a window's start when it has versions dated on
  both sides. A callback or nested save declared before `has_paper_trail`
  saves other records' versions first and its own last, dated as its save
  began. The transaction was placed at its last version by id, so another
  transaction's edit of the same record was reported by no step, and two
  windows cut between its dates reported its change in neither.
- Two ranges that meet at the destroy version of a record restored later
  under its id report its removal once, in the range from the destroy. A
  window over the record's earlier life credits the transaction that
  restored it as a window that begins after the destruction does.

- Comparing a JSON array that holds a BigDecimal NaN or infinity no longer
  raises `FloatDomainError`; it compares as a Float NaN or infinity did.
- An activity timeline no longer leaves a record as it was at one of two
  places a path reaches it. An article read with
  `associations: ["author.articles"]` is the root and one of its author's
  articles; a comment read with `["article.comments"]` is one of its
  article's comments; under `["articles.comments.article"]` an article is a
  member of a collection and the target of a `belongs_to` below it; and a
  polymorphic `belongs_to` can point back at any record in the tree. An
  event on such a record changed it at one place only. The step and any
  window around it then missed the change at the other, and the next event
  in that branch reported it, credited to its own author in `change_rows`.
  Such an event now has the branches that hold the record read again, or
  the whole snapshot for the root, which costs the size of what is read. See
  [performance](docs/performance.md#what-still-grows). `compare` and
  `timeline` were not affected.

- `activity_timeline`, `analyze` with `activity: true`, `analyze_many`, and
  `report` no longer raise `ConfigurationError` ("prepared activity graph is
  missing ...") for a path that continues past a `belongs_to` when no record
  read had one, such as `associations: ["article.author"]` on a comment
  created without an article. They read the record with nothing on that path.

- An activity timeline no longer reads a whole collection again for each event
  that put a record into it or took one out. A snapshot kept a table of its
  records' positions, and built it again and checked their order again
  whenever its members changed, so a replay's time grew with its events times
  the size of the collection: 3,000 comments created one at a time on one
  article took 19.2 s to replay and now take 3.6 s, and 1,000 took 2.1 s and
  now take 0.7 s. Edits were not affected. A record is now found by searching
  the order a snapshot holds its records in. See
  [performance](docs/performance.md#what-still-grows).

- A `has_many` or `has_one` whose owners use single-table inheritance no
  longer loses the records that left it when the target's `belongs_to` names
  another class of the owners' table than the owner's own or its base class.
  With `Doc`, `Report < Doc` and `AnnualReport < Report`, and notes that
  `belongs_to :report`, a note destroyed or moved away from an annual report
  was missing from `compare`, timelines and analyses, and when `Doc` declared
  the association, `analyze_scope` and `report` did not select a record whose
  only change was such a note. PT-AT records the class the `belongs_to` names,
  and the gem looked for the owner's class and its base class only.

- `analyze_scope` and `report` over a window no longer slow down with the size
  of the model's table on PostgreSQL. The statement that finds the records
  changed in the window and deleted since asked with `NOT IN (SELECT id ...)`,
  which PostgreSQL does not plan as an anti-join: it reads every id of the
  table, and reads them again for each version in the window once they
  outgrow `work_mem`. With 2 million articles and 2,000 of them edited in the
  window, a `report` took 16 s and now takes 1.4 s, and with 500,000 it took
  11 s and now takes 1.5 s. That statement, and the one like it for records
  selected by their associations, now asks with `NOT EXISTS`. Results are
  unchanged. See [performance](docs/performance.md#database-indexes).

- An activity timeline over a tree no longer slows down with the tree's size
  times its events. Each event of an associated record is checked against the
  snapshots around its transaction, to leave out a record that was outside
  the tree, and each check looked through every collection of the snapshot.
  The records each snapshot holds are now kept up from one snapshot to the
  next, by what its event changed. 2,000 replies created one at a time under
  2,000 comments of one article took 10.4 s to replay and now take 1.4 s, and
  3,000 comments created one at a time took 3.6 s and now take 1.8 s. A window
  with `activity: true` on a record not saved since the window, with 2,000
  comments created after it, took 1.8 s and now takes 0.8 s. Results are
  unchanged.

- A range that ended in the past no longer slows down with the children its
  records have gained since. A `has_many` or `has_one` read every child that
  was ever its owner's from the range's start onward, with each child's row
  and versions, and only then left out those created after the range. With
  2,000 comments added to an article after the range, a `compare` of two of
  its versions took 132 ms and now takes 10 ms, as with none, and `timeline`
  between them, or `analyze` over a window that a later version of the article
  ends, went from about 160 ms to about 12 ms. A child is left out when its
  first version is a `create` saved after the range's end, so one whose
  creation was never recorded is still read. Where `item_id` is not stored as
  the child's key is, as with a string `item_id` and integer keys, the child's
  current row is still read, though not its versions. Results are unchanged.

- An association scope that negates an empty list along with another
  condition, such as `where.not(status: [], score: 1)`, now reads a record
  whose `status` is NULL as the database does. Active Record writes the empty
  list as a condition that is always false, so the negation is true for every
  record, but history read it against a NULL as unknown and left the record
  out, reporting a current member as added.

- `recorded_changes`, and change rows with `recorded_changes: true`, now cast
  the values a `json` or `jsonb` `object_changes` column stores. PaperTrail
  leaves such a column's dates, times, and decimals as the strings JSON gives
  back, and the gem returned them that way: a recorded change no longer
  equalled the state it produced, so one change became three change rows, two
  of them credited to writes without a version, and a model with a `time`
  column raised `NoMethodError`.

- A report with `historical_filter:` can be paged with the relation, as the
  reference says. A relation with a `limit` now reads its candidates in its
  own order and stops matching when the page is full, and only the page
  counts toward `limit:`. Before, every match counted, so
  `Article.order(:id).limit(20)` with `limit: 20` raised
  `BatchLimitExceededError` whenever more than 20 records matched, and the
  history of every match was read to return one page.

- A hash `historical_filter:` now works on a model with an encrypted
  attribute, and on a version that names a column since dropped. It raised
  "cannot read recorded attributes directly"; such a version is now rebuilt
  as PaperTrail rebuilds it and compared by its decrypted, cast values.

- A hash `historical_filter:` with a list or a range as a value, such as
  `{ status: %i[published archived] }`, raises `ConfigurationError` instead
  of matching nothing. `where` would match any of the values; a filter
  compares one, so use a callable for several. A list is still the value of
  an attribute that holds one, such as a serialized or an array column.

- `include_deleted: true`, and a readable association scope, accept an
  equality or a list on a date or a time column, such as `where(due: date)`,
  wherever they already accepted a range on it. Before, the relation was
  refused, or the scope read by its slower path.

- `version_scope:` raises `ConfigurationError` when the callable returns
  anything but a relation on the version class it was given. A callable that
  returned another model's relation, such as `Document.all`, silently
  selected the versions whose ids equalled that model's ids.

- A relation ordered by another table's key written in quotes, such as
  `order('accounts."id"')`, is no longer read as ordered by the model's own
  key, so its pages get the tie-breaker they need.

- `recorded_changes(version)` leaves out a name the model no longer has,
  such as a column dropped since, as diffs, timelines, and change rows do.

- `nested_changes` compares two arrays in time proportional to their length.
  Arrays of objects took time proportional to its square: 16,000 objects
  took 53 s and now take 0.2 s. Results are unchanged.

- Without `activity:`, `analyze`, `analyze_many`, `analyze_scope` and
  `timeline` with associations could report an associated record's change
  backwards, and then again forwards, when two transactions interleaved: one
  edited a comment, another saved the article, and the first then saved the
  article too. The comment read as edited at the other transaction's version
  and as not yet edited at its own. Whether it did depended on how far back
  the history read went, so `analyze_many` could disagree with `analyze` for
  the same record. These reads now place each associated record's change
  where its transaction ends, as activity does, and report it once. They
  run the statements activity runs for that: one per version table for a
  window, to find the transactions open at its start, and one per 500
  transactions the history holds.
- `analyze_many`, `analyze_scope` and `report` without a window could read
  a record's history differently from `analyze`, when a transaction changed
  an associated record before the record's first version and ended after it,
  such as one that renamed an author and later saved an article created in
  between. The batch reported the rename as a change in the article's
  history, once backwards and once forwards, because its history also held
  an older record's versions. A history without a window now
  begins at the record's first version, however it is read.
- Two transactions that saved in one record's tree at the same time
  interleave their versions, and activity timelines read them wrongly in four
  ways, all fixed by reading each transaction where it ends:
  - A change could be credited to the other transaction's author, such as a
    comment one transaction removed reported under the one that saved
    meanwhile.
  - Back-to-back windows that met inside such a transaction could report one
    of its changes in neither window.
  - Back-to-back windows could report a change in both, when a transaction
    saved an associated record before the record itself, around another
    transaction.
  - A window that started inside a transaction credited an edit the
    transaction saved before the window to the version of another record.
- A transaction that went on to save a record outside the requested paths,
  such as a comment moved to another article, was placed at its last version
  on them, which depends on where a window starts. Back-to-back windows could
  then report one of its changes in neither. Where a transaction ends is now
  read from its version table, whatever records it saved.
- A range that ended while a transaction saving in the tree was still open
  read the records it had saved as changed. They now read as they stood
  before it, since it had not ended.
- A window that started while a transaction was open read a record that
  transaction had already saved as changed, when the transaction saved
  nothing else of the tree inside the window. Its snapshot then disagreed
  with the one the window before it ended on.
- Without `paper_trail-association_tracking` loaded, asking for an
  association between two versioned models raised `NoMethodError`. Reading
  its history now raises `AssociationTrackingUnavailableError`, as
  documented, and `association_paths` and a comparison of two current
  records work again.
- On PostgreSQL, an association scope with a condition on a `character(n)`
  column is no longer read as plain conditions. PostgreSQL pads such values
  and compares them without the padding, which Ruby does not, so a member
  could read as leaving and rejoining the association. It is now refused
  unless you pass `allow_approximate: true`, as a `citext` condition is.
- A `within:` window whose first later version tied with another version
  of the same record, with ids that cannot order them (such as UUIDs),
  ended in whichever of the two had the lower id. Such a tie now raises
  `AmbiguousVersionOrderError`, as one inside the window already did.
- `analyze_scope` and `report` raise `ConfigurationError` for a relation
  grouped by anything but its primary key that has no order of its own,
  instead of sending a query the database rejects.
- A `has_one` that two records point at, with no order of its own, now reads
  the one with the lowest primary key at every point in history, as Active
  Record reads it on SQLite, MySQL and SQL Server. History read another one,
  so comparing the last version with the current record reported the
  relationship changing when nothing had.
- A `within:` edge finer than a microsecond is cut to the microsecond, as
  adapters write it into SQL. A version saved in the edge's microsecond was
  in `timeline`'s window but not in `activity_timeline`'s or
  `analyze_many`'s.
- A `within:` edge is cut to the digits the version table's `created_at`
  keeps, as the database compares it. On a column that keeps whole seconds,
  as a MySQL `datetime` without a precision does, an edge with a fraction
  put a version saved in that second inside the window for one method and
  outside it for another.
- With more than one version table, a `within:` window no longer reads an
  unrelated transaction as one that crosses its edge. PaperTrail numbers a
  transaction by the id of its first version in whichever table that was, so
  two transactions can share a number in one table, and a window that started
  or ended before the later one moved to where the earlier one began,
  which could be years before: a window could take in changes from long
  before it, or come back empty. `analyze_scope` selected records by the
  earlier transaction too. Transactions of one number are now told apart
  by the versions they began with.
- A transaction of associated records that moved a record away from the
  root before a window's start, and after it saved only records under the
  one it moved, was reported in neither window: `activity_timeline` and an
  `activity: true` analysis left its changes out.
- A window that started inside a transaction which began at the instant
  another saved its last versions, as it can where `created_at` keeps whole
  seconds or two versions share a time, cut the earlier transaction in two,
  and part of its change surfaced in the later transaction's step.
- A comment one transaction created and deleted again while another saved in
  the same tree is no longer reported as added or removed in the other's
  steps, nor held in a window's starting state or diff.
- Two activity windows that meet inside a transaction no longer both report
  it when the transaction moved a `has_many :through` join row onto the
  root and destroyed it after the edge, such as a card moved to a board and
  destroyed while its assignee was renamed. The window after the edge judged
  the join row by its destroy alone, where it was on the root, so the change
  appeared in both halves. A join row's versions in one transaction are now
  judged by the whole transaction, wherever a window's edge falls in it.
- A destroyed record read without `within:` ends at its last version,
  instead of raising.
- A NaN stored on both sides no longer reads as a change, in attributes,
  nested JSON, arrays and recorded changes.
- `recorded_changes: true` keeps a serialized hash's symbol keys, reads
  versions of a custom class without `object_changes`, and leaves out a
  change whose two sides are the same.
- `analyze_many` and `analyze_scope` read a root that stands in another
  root's tree as `analyze` does when the roots are of two STI classes of one
  table, and a windowed batch reads such a root at its state in the window,
  not from its current row.
- A `belongs_to` naming an STI subclass reads no row of a sibling class, and
  an `as:` child is a member only while its type is its owner's polymorphic
  name, as Active Record reads them.
- A `has_many :through` with `source_type:` and a path below it descends only
  into targets of that type, instead of raising for another type's.
- A `has_many :through` join row created and destroyed in one transaction is
  no longer read as present, in another transaction's step or at the end of
  a window.
- The end boundary of a window's last step no longer depends on which other
  roots are in a batch.

## [0.17.1] - 2026-11-07

### Fixed

- A change to a root's own field that was saved without a version, after an
  earlier version of the same transaction changed that field, is no longer
  split with that earlier version's change. The earlier change is already in
  the state a step starts from, so the step's row for the field is the
  unversioned change alone.
- A window that starts inside a transaction now reports an associated
  record that the transaction moved out of the root's tree before the
  window's start, such as a comment moved to another parent and then saved
  again or destroyed. The window before it leaves such a change to this
  one, so a window split there no longer loses it from both halves.
- A serialized attribute that changed between values Ruby's `==` calls
  equal, such as a Time to the matching string or `1` to `1.0`, alone or
  nested, is reported as a change. Values must now be equal both ways, and a
  Float differs from the Integer it equals.
- `recorded_changes` types an STI subclass's version with the subclass's
  attribute types, as a step's states do, so an enum or a retyped column of
  the subclass reads as its value.
- A relation passed to `analyze_scope`, `report` or `include_deleted:` is
  read beside parts that choose no rows, such as `distinct`, `select`,
  `order`, `unscope`, `rewhere`, `lock`, `annotate`, `preload` or
  `create_with`, instead of being refused. Joins, `from`, `group`,
  `having` and `with` are still refused.
- `include_deleted:` refuses a condition on a column `has_paper_trail skip:`
  leaves out of history, as `historical_filter:` does, instead of comparing
  it with the column's default; and, on SQLite, a `Date` bound on a datetime
  column, which SQLite compares as text, instead of reading it as midnight.
- `historical_filter:` matches nothing for a value the attribute's type
  cannot write, such as `''` or `'abc'` for an integer or one out of its
  range, as `where` does.
- `historical_filter:`, with a hash or a callable, reads the live row as
  history keeps it, so an unchanged value matches alike whether a version or
  the live row closes the window, under JSON history too. A relation with
  `limit(0)` selects nothing with a filter, as without one.
- A child made without a version, whose first version moved it to another
  owner, is under the owner it left until then: PT-AT names only the owner a
  version saved, so the one before is read from the first version's state.
- A `has_one :through` over a `has_one` reads every row of its parts, as its
  one query joins them, rather than only the has_one's first row: a project
  whose first pin has no user now has the user of the next, as Active Record
  returns.
- A through's join row whose transaction changed nothing the tree shows,
  such as a pin that names no user, or a member's own versions under a
  through of a through before the member joined, is no longer a step of the
  root. A member's versions under such a through are steps only where a
  membership of the root named the member, and a record that is a join row
  under one association is judged as any member under the others.
- `compare` between two versions of a record whose STI class changed
  between them reads both from one history, so a change below the record in
  between, such as a note moved to a member, is reported. It was read from
  two histories, each beginning at its own version, and was missed.

## [0.17.0] - 2026-11-04

### Breaking changes

- The options deprecated in 0.15.0 are removed, and passing one raises
  `ArgumentError` (unknown keyword):
  - `close_on:` on `timeline`, `activity_timeline`, `analyze`, `analyze_many`,
    and `analyze_scope`. It had no effect: a window already closes on the
    current record when nothing on its requested paths was recorded after it.
  - `allow_expensive:` on `compare_many`, `analyze_many`, `analyze_scope`, and
    `report`. It had no effect: `allow_approximate: true` alone accepts a path
    read with PT-AT.
  - `reload_live_endpoints:` on `compare`, `compare_many`, and
    `activity_timeline`. Every method now reloads the current records it
    compares with, as it did by default.
- `UnloadedAssociationError`, which only `reload_live_endpoints: false` raised,
  and `UnsupportedBatchPathError`, which nothing raised since 0.15.0, are
  removed. Code that rescues either must stop naming it.
- The `compare.paper_trail_diff`, `compare_many.paper_trail_diff`, and
  `load_live_endpoints.paper_trail_diff` payloads no longer have a
  `reload_live_endpoints` key.
- `version_scope:` applies to the versions of the requested associations as
  it does to the root's own:
  - In `analyze_scope` and `report`, a change on a requested association
    selects a record only when the filter keeps its version. A record that
    only versions the filter leaves out changed is no longer selected, and no
    longer counts toward `limit:`.
  - In activity (`activity_timeline`, `activity: true`, and `report`), the
    filter decides which steps are reported: every step of a transaction in
    which it keeps a version, of any record, and each version saved outside a
    transaction that it keeps. Activity listed every step between the first
    and the last root version the filter kept, whoever made it, and every
    change on an association. Every version is still replayed, so each step
    shows what its own change did. An analysis starts at the first change the
    filter keeps, on the record or its associations, and ends after the last.
  - Without associations, activity reports the root's versions the filter
    keeps, as `timeline` does.

  The record and its associations keep their versions in one table, which
  the filter reads for all of them, so a condition on `item_type` or
  `item_id` now leaves out the associations' changes. A filter that keeps
  every version now reads as no filter: a range of one version, which no
  later version reveals, has that version's state rather than none.

### Added

- With `recorded_changes: true`, change rows tell a write saved without a
  version, such as `update_columns`, apart from the change it follows.
  PaperTrail reads such a write into the record's next version, or its
  current row, so it shows up in the step of the record's previous change,
  and its row was credited to that change's author. The part of a change no
  version recorded now has a row of its own, whose `source` has kind
  `:unversioned`, names the record, and has no version, event, author, or
  time; `ChangeRow#unversioned?` and `ActivityBoundary#unversioned?` tell
  them apart. A field a version recorded changing from 10 to 20, which an
  `update_columns` then set to 99, gives two rows: 10 to 20, credited to the
  version, and 20 to 99, unversioned. A write between two of a record's
  versions in one transaction, which no step shows on its own, is split off
  the same way. A row stays whole, credited to a version, where history
  cannot show the write was unrecorded: a version that recorded no changes,
  such as a `touch`; a column `has_paper_trail` leaves out of
  `object_changes`; a field a create left at its default; and the start of a
  transaction that began before a window and saved no version of the root.
  The [change rows](docs/reference.md#change-rows) reference lists them.

- `Analysis#net_changes` and `ScopedAnalysis#net_changes` fold an activity's
  change rows into one `NetChange` for each record: its fields before the
  rows a block keeps, its fields with only those changes made, and the
  difference. Keeping the rows that name an author reports what people
  changed, and with `recorded_changes: true` leaves out writes saved without
  a version: `report.net_changes { |row| row.source.whodunnit }`. The root
  comes first whenever anything changed. The states come from the steps'
  snapshots, so it needs `snapshots: true`. See
  [net changes](docs/reference.md#net-changes).

- `ScopedAnalysis#analysis_for(record)` returns the analysis of one of
  `roots`, the records `analyze_scope` and `report` load, without building
  its key: the base class's name and the ID as a string, which a subclass or
  an integer ID gets wrong when built by hand.

- `within:` accepts an endless range, such as `1.day.ago..`, which runs
  through the current saved state, as `report` does.

- `diagnose` warns with `inverted_version_order` when a record's versions are
  dated in another order than their IDs show they were saved in. PaperTrail
  dates an update with the record's `updated_at` unless `has_paper_trail
  synchronize_version_creation_timestamp: false`, so a save that set
  `updated_at` itself, such as an import keeping another system's times, a
  `touch(time:)`, or one made with timestamps off, can date its version in
  the past. History is read in time order, so such an update is read before
  the change it followed, and one dated before the record's `create` reads as
  the record deleted and created again. The
  [version order](docs/reference.md#version-order) section explains the fix.

- On SQL Server, each call reads its history and live rows in one `SNAPSHOT`
  transaction when the database allows snapshot isolation
  (`ALTER DATABASE ... SET ALLOW_SNAPSHOT_ISOLATION ON`), as it does at
  `REPEATABLE READ` on PostgreSQL and MySQL. A commit that lands during the
  call is then seen by none of its statements. Each call checks the setting
  first, in one statement; without it, nothing changes.

### Changed

- A change row names the version of its own record that made the change.
  It named its step's source boundary: for a transaction group, the
  transaction's first event, whichever record that was; and without
  grouping, a child's change that showed up at a later event of its
  transaction, in a step another record's version opens, named that version.
  A record created or destroyed names its create or destroy, and its fields
  the version that recorded each value. A record that joined or left through
  another record's change, such as a new `belongs_to` target, still names the
  step's source boundary.
  Without `recorded_changes: true` the gem cannot tell which of a record's
  versions in a transaction made a change, and names the last of them.

- `recorded_changes`, and each activity boundary's `recorded_changes`, read
  values as a step's diff reads them, so a recorded value equals the state it
  produced: a time of day on 2000-01-01, and with JSON history, times to the
  digits history stores and binary and `serialize`d values as JSON stored
  them.

- `report` reads every version saved since `since:`, with no end. Its window
  ended at the time of the call, so a version a server whose clock ran ahead
  of the reporting server's had dated a moment later was left out, and the
  report ended before a change the current record already held. It no longer
  looks for transactions that cross that end, or for each record's first
  version after it, which saves up to three statements per 500 records.
  `analysis.window` is endless (`since..`) for a report, and a `since:` in the
  future gives an empty report rather than raising `InvalidTimeRangeError`,
  whose message named `within:`.

- The README said change rows leave out the blank fields of a record that
  appeared or disappeared. Only `nil` fields are left out: an empty string or
  `false` gets a row.

- The performance guide's query counts were measured again, and it compares
  PaperTrail's JSON serializer with its default YAML one: a report read JSON
  in about 40% less time. It also says what `historical_filter:` costs on SQL
  Server, where each page of matching records lists every matching id. The
  architecture guide no longer says a window's transaction lookups take four
  per root, sent 200 roots per query.

- The reference says what happens when two transactions save in the same
  tree at the same time, so that their versions interleave: each forms more
  than one group with `group: :transaction`, and a record one of them changed
  and changed back can appear in the other's steps, and in a window's
  starting state and diff.

- `analyze_many`, `analyze_scope`, `report`, and `compare_many` list at most
  500 ids in a statement, as the rest of the gem does. Reading the batch's
  versions, the transactions its first versions belong to, its associations'
  candidates and rows, its deleted records' destroys, and its current rows
  and their associations each listed every record of the batch at once. On
  SQL Server, which writes such a list into the statement and compiles it
  afresh, a `report` of 10,000 articles and their comments took 17.1 s and
  now takes 11.4 s, and one of 20,000 took 38.9 s and now takes 23.0 s; a
  statement listing 20,000 transactions alone failed with error 8623. With
  `historical_filter:`, or a version table whose `item_id` does not share the
  key's type, the records are read among a list of ids, which each page of
  250 repeated: they are now read in pages of one past `limit:`, up to 2,000.
  On SQL Server, such a report of 10,000 articles took 47.4 s and now takes
  14.4 s, and one of 20,000 took 280.5 s and now takes 51.1 s.

- `analyze_scope` and `report` read the records a relation selects in pages
  of one past `limit:`, at least 250 and at most 2,000 records, rather than
  250. Each page runs again the subqueries that find which records changed
  and skips the rows before it, so a selection of 10,000 articles changed in
  the window, with their comments, took 1.5 s on SQLite and now takes 0.3 s.

- `historical_filter:` reads its candidates' versions, and selecting a record
  by a change on its associations reads ids, 500 to a statement rather than
  250, as the rest of the gem does.

- Activity on associations decodes each of the record's versions once for
  the call. It decoded a version again at every event the version bounded,
  up to five times: a `report` of 10,000 articles with their comments took
  about 20 s on SQLite and now takes about 18 s, and peaks at about 100 MB
  less memory.

- History on a `has_and_belongs_to_many` groups the members PT-AT recorded
  by transaction once. Each of the root's transactions looked through every
  member recorded for all of them, so the cost grew with the square of the
  root's versions: a `timeline` of an article with 2,000 versions and its
  tags took 9.2 s and now takes 1.9 s, and an `analyze_many` of 200 tagged
  articles with 20 versions each took 34.6 s and now takes 4.0 s. The
  members and the transactions' owners are read 500 transactions per
  statement, as other lists of ids are: on SQL Server, a statement listing
  40,000 ids timed out.

- With `version_scope:`, `timeline`, `analyze`, and the batch methods find
  the version after each one the filter keeps with a search. They passed
  every version in range before it, so the cost grew with the square of the
  record's versions: a `timeline` of an article with 4,000 versions, half of
  them kept, took 9.5 s and now takes 1.4 s, about as long as without the
  filter.

- Preparing history no longer checks each record against every one before
  it in two lists: the targets of a polymorphic `belongs_to`, and the owners
  of an association requested both alone and as the first part of a
  `has_many :through`. Each check cost little, about 0.1 s in an
  `analyze_many` of 3,000 authors with their articles and the comments
  through them, but the total grew with the square of the batch.

- Snapshots of a record with its associations do less work at each version
  of the record, with the same results. Each member's version times and its
  scope's condition are read once rather than at every version, a member
  that did not change is normalized once, and a snapshot that starts from
  the current record reads its associations from prepared history, as one
  that starts from a version does, rather than building each member as an
  Active Record record. A `timeline` of an article with 2,001 versions and
  300 comments took 14.9 s and now takes 7.5 s, and an `analyze_scope` with
  activity over a day's changes to 373 articles, with their comments,
  replies, reviewers, and authors, took 4.3 s and now takes 3.9 s.

- With `recorded_changes: true`, a boundary decodes its version's changes the
  first time its `recorded_changes` is read, and each version is decoded once
  for the whole call. Every boundary decoded its version when it was built,
  so a version that many records share in a batch, such as an author's, was
  decoded once for each of them, and a step nobody read cost as much as one
  that was. A decoding error now raises when the changes are read.

- Activity asks Active Record whether a value is a version or a record once
  for each model class, rather than on every read: Active Record answers
  `respond_to?` by also looking through the record's attributes. An
  `analyze_many` of 2,000 articles with their comments took about 9% less
  time.

- `analyze_many`, `analyze_scope`, and `report` with `activity: true` read
  the association history of a record that has no version in the window,
  but whose associated records changed there, together with the rest of the
  batch. Such a record, as in a `report(since:)` of articles that only gained
  comments, read its own history, at about nine statements each. A batch of
  20 such articles took 188 statements and now takes 14, as many as one.

- Activity on a `has_many` or `has_one` reads the children each owner had
  once. Preparing the history read them for its snapshots, and finding the
  activity read them again: an `analyze_many` of three articles with their
  comments took 16 statements and now takes 14.

- `analyze` and `activity_timeline` with activity on associations read the
  current record's row once for the snapshots that start from it, as
  `analyze_many` already did. Each such snapshot read the row again: after
  four transactions that changed two comments each, an article's activity
  read its row ten times rather than four.

- On SQL Server, a window's transaction-edge lookup sends its record ids as
  bound parameters, as the other id lists do, instead of writing them into
  each statement. SQL Server compiled each such statement afresh, at about
  0.05 ms per id. On 10,000 roots, the lookup's SQL time fell from 1.4 s to
  0.7 s and a report from 5.1 s to 4.4 s, with the same windows. The lookup
  now names 250 ids a statement rather than 500, since each id appears twice
  in it: 1,000 ids a statement was slower, and would exceed the 999 bound
  parameters SQLite allowed before 3.32.

- Activity reads the state of a transaction that saved its root together
  with descendants once for that transaction's descendant events, not again
  at each one. PT-AT reads what a transaction saved as it stood before the
  transaction began, so from one descendant's event to the next in the same
  transaction the snapshot is the same; it was rebuilt whole each time. A
  `report` on 100 articles, each created with 100 comments in one transaction
  and edited with all of them in another, took 20.1 s and now takes 4.6 s,
  and allocated a quarter as many objects. On 10,000 articles at about 1.5
  versions each with their comments, it took 14.6 s and now takes 13.9 s.
  The results are the same.

- Activity carries the snapshot at a root's version to the next event by
  comparing the root's state at the two, which the snapshots decode anyway.
  It decoded the version's recorded changes and the state after it a second
  time instead, which took longer than rebuilding the snapshot whole. The
  next descendant's event in the same transaction as a root's update is now
  carried forward the same way, where it was rebuilt whole. A `report` on
  2,000 articles with about 1.5 comments each, each article edited ten
  times and about a fifth of those edits saved with a comment, took 19.9 s
  and now takes 14.8 s, with a fifth fewer allocations. The results are the
  same.

- A batch reads its requested associations' reflections once for the whole
  call, where each root's activity resolved and checked them again, and it
  reads a current record's attributes for its history only when a read
  reaches past that record's last version. Most do not: in a `report` on
  10,000 articles with their comments, about a quarter of the 25,000 current
  records were read that way. The snapshots that start from a root's current
  row also share one reading of it, from the record the call loaded. That
  report takes about 7% less time and allocates 8% fewer objects; one on
  2,000 articles edited ten times each, and one on 100 articles with 100
  comments each, about 3% less time. The results are the same.

### Fixed

- `nested_changes` treats `:a` and `"a"` as one key inside arrays too, as it
  already did in objects. An array whose objects differed only in key type,
  such as a hash built in Ruby against one read back from JSON, was reported
  as having lost one element and gained another. Elements are still reported
  as they were given, and `{ a: 1, "a" => 2 }` inside an array now raises
  `AmbiguousNestedKeyError`, as it does in an object.

- With `historical_filter:`, `analyze_scope` and `report` test each record over
  the window its analysis covers. A transaction that crosses the window's
  start or end moves that window to where the transaction began, but the
  filter read the window as asked: it missed a value the record held at the
  moved start, such as its title before the transaction changed it, and
  matched one held only past a moved end.

- `analyze_scope` and `report` no longer lose a record's change when a
  window's edge falls inside a transaction that saved the record before the
  edge and another article, or a record off the requested paths, after it.
  The record's window moved to the later window, which did not select it,
  while the earlier window left the change out: an update, or a deletion with
  `include_deleted: true`, was in neither report. Such a transaction now moves
  no edge, so the change is in the earlier window, with the record's version.
  When the transaction saved a record on the requested paths after the edge,
  the edge still moves, and `analyze_scope` and `report` now select the record
  in the later window with or without `activity: true`.

- Activity over a window (`activity: true`, `activity_timeline`, and
  `report`) no longer raises `KeyError` when a record on one requested path,
  such as an author, is also a `belongs_to` target on another path with
  associations requested below it
  (`["author", "comments.reviewer.reviewed_comments"]`). A target named only
  by a version saved after the window was followed as if its own associations
  had been read, and they had not been.

- With `historical_filter:`, `analyze_scope` and `report` accept a relation
  grouped by anything but the ID, such as each author's latest article
  (`select("MAX(id) AS id").group(:author_id)`), and select the records it
  groups among those that match. Before filtering, they asked the relation
  for the IDs among each 250 candidates, which reads a group's column
  instead of its aggregate: PostgreSQL, MySQL, and SQL Server rejected the
  query, and SQLite returned any record of each group.

- History stored as JSON no longer reports two kinds of value as changed in
  every comparison with the current record, though nothing changed them. A
  `json` or `jsonb` `object` column stores a `serialize`d attribute as JSON
  writes it, so a `Date` or `Symbol` inside it came back as a String: that
  attribute is now read as JSON writes it on every side, the current
  record's included. PaperTrail's JSON serializer stores a `binary` column
  as `{ "value" => bytes }`, which is now read as the bytes.

- Without associations, activity (`activity_timeline`, `activity: true`, and
  `report`) reports a change saved without a version, such as one by
  `update_columns` or with versioning off, in the step for the record's
  previous recorded change, as `timeline` and activity on associations do.
  It was reported in the step for the record's next version, and so credited
  to that version's author: a title written by `update_columns` after
  Alice's edit was reported as part of Mallory's next edit.

- `analyze_scope` and `report` read every record a relation selects when its
  order has ties, such as `Article.order(:status)`, and more than 250 records
  match. Records were read 250 at a time in that order, and PostgreSQL and
  MySQL may return rows that tie in a different order for each query, so some
  records were read twice and others never, without an error: of 2,000
  changed articles ordered by status, PostgreSQL selected 1,606. The ID now
  ends any order that does not already sort by it. SQL text counts as sorting
  by the ID when it names the column, alone or after the table's name. The
  order of a relation grouped by anything but the ID is kept as given, since
  a database sorts groups only by what they group or aggregate.

- With PaperTrail's default YAML serializer, a `time` column reads as the
  time each version recorded. PaperTrail 16 and 17 decode such a value as
  `nil`, unless the column is time-zone aware and the time zone is UTC, and
  so did the gem, so the step that set a time showed no change, every
  comparison of a later version with the current record showed the time
  changing from `nil`, and `recorded_changes` reported
  `{ from: nil, to: nil }`. That includes records the gem rebuilds with
  PaperTrail's `reify`: models with initialization callbacks, custom types or
  defaults, default scopes that assign attributes, or encrypted attributes;
  a version that holds a column the model no longer has; the records a
  callable `historical_filter:` receives; and association members PT-AT
  rebuilds. Each such record's time is assigned from its own version, which
  is decoded a second time only when it holds a time of day. A time is read
  on 2000-01-01, as the row keeps it: a column that is not time-zone aware
  keeps in memory the date of the time assigned to it, such as
  `Time.current`'s, and the versions saved from that record store it. Before
  Active Record 8.1, a zone-aware time read from the database falls on
  2000-01-01 in UTC, and one assigned on 2000-01-01 in the time zone, so
  every time of day is compared on 2000-01-01 in its own zone, as Active
  Record 8.1 reads both.

- `analyze_scope` and `report` accept a relation whose `limit` or `offset` is
  a String, as request parameters are, such as
  `Article.offset(params[:offset])`. A String offset raised `TypeError`, and
  before Active Record 8.1, which casts a limit as it is set, a String limit
  raised `NoMethodError`. A String `limit` or `offset` in an association's
  scope is read from history as an Integer one is: before 8.1 a String limit
  raised `TypeError` there, and a String offset made the association one that
  only `allow_approximate: true` reads.

- Activity from a version reports a record that left one of the requested
  associations earlier in that version's transaction, such as a comment
  moved to another article or destroyed just before the article's version
  was saved. The range starts from the state before the transaction, which
  holds the record, but the record's own versions were not read, so its
  removal was left out, or reported in the next step that read the
  association again, under that step's transaction and author.

- Activity on a `has_many :through` leaves out the versions a join record
  saved while it joined another record, judged by transaction as any record
  is: by whether it joined the owner before the transaction or after it. A
  card created on one board and moved to another later brought every version
  it saved on the first board into the second board's activity, and so did a
  card created and destroyed inside one transaction: each was a step of its
  own, and a transaction group listed it in `sources`. Inside a transaction,
  where a change surfaces one event late, such a step also took the credit
  for the change made just before it, under its own author.

- A window in which every event was of a record outside the requested
  associations throughout, such as a comment past a scope's `limit` or one
  its default scope leaves out, reports nothing. With nothing recorded after
  it, such a window had a step whose `sources` held `nil` and that showed the
  record as created. With something recorded after it, the analysis was empty
  but still held both snapshots; both are `nil` now, as for any analysis that
  reports nothing.

- Back-to-back windows, or a `report` with `since:` after an earlier report,
  that meet inside a transaction that saved associated records on both sides
  of the edge, and no version of the root, report the changes it saved before
  the edge. Neither window reported them: the earlier one ended at the state
  before the transaction, as any window ending inside one does, and the later
  one started after them, and did not know a record the transaction
  destroyed before the edge. Now all of the transaction's changes are
  reported once: in the later window, which starts from the state before the
  transaction, when a version it saved after the edge is of a record on the
  requested paths, and otherwise in the earlier window. A transaction group
  lists in `sources` only the versions inside its window. Finding such
  transactions takes one statement per 500 of the transactions a window's
  history reads; when it finds one, the window's history is read again from
  where that transaction began.

- A window whose last change a `version_scope:` keeps is followed by the
  version that shows what that change did, and that version now comes after
  the window as well. Activity reported no step for the change, and
  `analyze_many` with associations read the associations' state at that
  version from history that ended with the window: a comment edited again
  after it showed its latest body instead of the one it had then.

- `analyze_many` with `activity: true`, associations, and a `version_scope:`
  that keeps none of a record's versions reports nothing for that record over
  its whole history, as `analyze` does. It raised `IncompleteTimeRangeError`.

- Activity reports a change to a `belongs_to` target that the root took
  without a version, such as an author set while `has_paper_trail only:`
  left `author_id` out, when the root's next version moved to another target.
  Only that version's stored state named the target, so the target's own
  versions were not events: its rename went unreported by activity read
  step by step, while the same history read in full showed it in an
  unrelated step.

- Activity on a `has_and_belongs_to_many` reports the addition of a record
  that the transaction saving the root created and attached, when the record
  was detached again before the root's next version. Only that transaction's
  root version records the record as a member. Its creation was judged by the
  states before and after the transaction, and the record was a member in
  neither, so the creation was left out: activity reported the record's
  removal but never its addition.

- `analyze` with `activity: true` from a version to the same version is
  empty, as is any analysis in which nothing is reported. It reported the
  record as destroyed: its `diff` held a presence change to `nil`, and its
  `to_snapshot` was `nil`.

- `analyze_many` and `analyze_scope` without associations raise
  `AmbiguousVersionOrderError` for versions they cannot order, as `timeline`
  and `analyze` already did: versions that share a timestamp and whose ids
  do not count up, such as UUIDs. They read such versions in the order of
  their ids, so a record's steps could follow a random sequence, including
  a destroy and re-creation that never happened.

### Development

- `ORACLE_SHRINK=1` reduces a failing oracle example to the few steps that
  matter. The generators draw through a random source that keeps each draw
  by step, and the reducer runs the example again with steps left out and
  choices set to the first one, while it still fails the same way. The example
  then reports the reduced history's versions and mismatches, and a file that
  replays it with `ORACLE_REPLAY`. An oracle failure prints the command. The
  replay differential oracle reports each read that differs, with both
  results, rather than only the transactions it made. The consistency checks'
  histories reduce the same way.

- `.github/workflows/oracle.yml` runs 200 more oracle seeds each night with
  `ORACLE_STEPS=40`, in eight jobs, from a window that moves 200 seeds a day,
  so each night tries histories no run has. A job reduces its first two
  failing examples and keeps its log and their replay files as an artifact.

- `spec/unit/engine_properties_spec.rb` and
  `spec/unit/nested_comparator_properties_spec.rb` check the comparison
  engine over generated snapshots and JSON values, without a database: an
  equal copy compares as no change, a diff applied to the first snapshot gives
  the second, comparing the other way gives the opposite diff, every change
  is real and in order, a carried-forward collection reports what one built
  whole does, and the result is frozen. The oracles compute the diffs they
  expect with the engine, so they cannot catch a bug in it. Of six engine bugs
  injected to try them, the properties caught all six in about a second; the
  engine's own specs missed two, which only integration and association
  examples caught.

- `spec/unit/net_changes_properties_spec.rb` checks the fold behind
  `net_changes` over generated histories in which each record has one state:
  the rows of any run of steps fold into each record's change between the
  run's first and last states, the root comes first and then each record by
  its first kept change, the rows that move records in and out leave each, kept
  alone, as its last move left it, and a record that stayed changes only in
  fields a kept row set. Of six fold bugs injected to try them, they caught
  all six, as the fold's own specs do.

- `spec/oracle/unversioned_writes_spec.rb` builds seeded histories of saves
  and `update_columns` writes to an article, its comments and its author,
  several to a transaction, and checks every change row against the writes:
  a field's rows chain into the step's change, a row credited to a version
  ends at a value that version recorded, an unversioned row ends at a value
  an `update_columns` wrote, and a write a later version or the current row
  reads has a row of its own. It runs over the whole history, grouped and
  not, and over windows that start and end inside transactions.

- Every oracle that reads an activity timeline from end to end also checks
  its net changes (`spec/support/net_changes_check.rb`): with every row
  kept, each record's `before` and `after` must be its state where the step
  of its first row starts and where the timeline ends, and the record must
  be listed exactly when the two differ. The unversioned-writes oracle also
  keeps only the rows of versions and checks that each article and comment
  ends at its last recorded save.

- `spec/association/report_sql_work_spec.rb` bounds how a report's SQL grows
  with other records' history in its window, counted in the steps SQLite's
  virtual machine takes, which are the same on every run. A statement that
  reads the window again for each of the roots' versions fails it; one such
  statement, never released, took reports on SQLite from 6 to 44 ms an
  article (see [SQL work](docs/testing.md#sql-work)). The reporting benchmark
  has an `association_window` case: a `report` over articles with their
  comments read through PT-AT, with the README's indexes.

- `spec/oracle/shapes_history_spec.rb` compares rebuilt history with plain
  Active Record for shapes the other oracles leave out: polymorphic
  `belongs_to`, `has_many` and `has_one` with `as:`, children that use
  single-table inheritance and change type, an association to one subclass,
  a child's own `belongs_to`, scoped and ranked `has_many` and `has_one`, and
  a default scope. It checks every endpoint, timeline step, activity step,
  window and window split, through `spec/support/graph_oracle.rb`, which
  reads the expected states for any model. It found the first three bugs
  above; a longer run of the replay differential found the fourth.
  `ORACLE_SHOW` prints more than the first five mismatches.

- The SQL Server 2022 CI job's database allows snapshot isolation and the
  2019 job's does not, so both ways of reading a call run on CI.

- The oracles' transactions take turns between authors, and every window
  split is also read with a `version_scope:` that keeps one author's versions.
  It must report exactly the unfiltered steps of the transactions that author
  saved a version in.

- Mutation testing in CI runs in four parallel jobs, each mutating every
  fourth method in scope (`script/mutant_shard.rb`). A pull request that
  changed 84 methods took 33 minutes on one runner, close to the job's
  45-minute limit.

- `PAPER_TRAIL_DIFF_SERIALIZER=json` runs the suites with PaperTrail's JSON
  serializer, and a new CI job runs them that way. Before, about 40 of some
  1,800 examples wrote JSON history, and none on the PaperTrail 16 or SQL
  Server jobs. Run with JSON, the suites found no fault in the gem: the specs
  that failed wrote YAML fixtures by hand, were about YAML itself, or read
  times more finely than JSON keeps them (milliseconds), which the gem
  refuses or rounds as documented. Those specs now write fixtures with the
  configured serializer, keep YAML where YAML is the subject, and compare
  times as JSON history holds them.

## [0.16.0] - 2026-11-01

### Changed

- `include_deleted:` reads the deleted records' `destroy` versions 500
  records per query, as `unreachable`'s test below does, instead of in one
  query for all of them.

- The reference says what `from_snapshot` holds at the start of a window,
  under `version_scope:`, and for a record created inside the range, and how
  to read a record at one version from an analysis rather than by decoding
  `version.object`, which skips the casting the gem applies.

- `analyze_scope` and `report` with `version_scope:` select a record by its
  own versions only when the filter keeps one of them in the window. A record
  whose versions there it all dropped was selected anyway, with an empty
  analysis, and counted toward `limit:`. A change on a requested association
  still selects a record, as before.

- `report` and `analyze_scope` list in `unreachable` only the deleted records
  whose state when destroyed meets the relation's conditions, also without
  `include_deleted:`, whenever those conditions can be read. A report on
  `Article.where(account_id: account.id)` listed every account's deleted
  articles there, and one on `Article.none` listed some too. A relation whose
  conditions cannot be read, such as one with SQL text, lists every deleted
  record of the model as before.

### Added

- `report` accepts `version_scope:`, as `analyze_scope` does, to report only
  some changes, such as those made by people rather than by background jobs.

- `Analysis#window` is the time window an analysis covers: the `within:` or
  `since:` range, or that range with an edge moved back to where a crossing
  transaction began. Check steps against it rather than against the range you
  passed, which the first step of a moved window starts before. It is `nil`
  without a window.

- A `moved_window.paper_trail_diff` notification reports each window edge that
  moved, with the requested and the moved window. A move far longer than a
  transaction takes means the versions' times were changed after saving, as in
  a test that rewrote some versions' `created_at` and not the others saved in
  the same transaction. The reference shows how to give versions fixed times
  in tests.

- Association scopes and `include_deleted:` relations read ranges, such as
  `where(position: 2..)` or `where(created_at: 1.day.ago..)`, and Arel's `gt`,
  `gteq`, `lt`, and `lteq`, on integer, integer enum, date, and datetime
  columns. Such a scope was read through PT-AT, which needs
  `allow_approximate: true`, and such a relation raised `ConfigurationError`
  under `include_deleted: true`.

- `include_deleted: true` accepts `Article.none`, which keeps no deleted
  record, instead of raising `ConfigurationError`. Authorization scopes often
  return `none`.

### Fixed

- Batch methods with `within:` or `since:` look for transactions that cross
  the window's edges in one statement per 250 records. 0.15.0 wrote a
  separate lookup for each record into the statement, which SQL Server took
  about a second to compile per 200 records, so a report on 10,800 records
  spent nearly two minutes there. On 1.4 million versions, 0.15.0 failed for
  10,800 records on SQL Server, whose query processor ran out of internal
  resources, and took 13.6 and 10.2 seconds on PostgreSQL and MySQL. Those
  edges now take about 6 seconds on SQL Server and about 1.5 on PostgreSQL
  and MySQL.

- On PostgreSQL and MySQL (through mysql2 or trilogy), and adapters built on
  them such as PostGIS, each call reads its history and live rows in one
  REPEATABLE READ transaction on the database of the model and its versions.
  A comment that
  committed between two statements of an activity read could make it raise an
  internal `KeyError`, and one statement could see a row that another did not.
  A call now reflects the database as of its first statement, so a commit
  during the call appears in the next call. Each call adds two or three
  transaction statements on those databases. A call made inside a transaction
  of your own keeps that transaction's isolation level. SQLite and SQL Server
  are unchanged.

- Activity reports a change to a root's `belongs_to` key in the step of the
  root version that made it, also when `object_changes` leaves the key out:
  under `has_paper_trail only:` or `ignore:` that do not list it, or when
  `update_columns`, `update_all`, or a save with versioning off wrote it. The
  root kept its old target until a later event read the branch again, so the
  change was credited to whoever saved that, two windows that met between
  the two reported it in neither, and `analyze(activity: true).timeline`
  differed from `timeline`.

- Activity reads a child or a `belongs_to` target whose key changed without a
  version, such as a comment moved by `update_columns`, or by any save under
  `has_paper_trail only:` or `ignore:` that leave the key out. In a past
  window or a range that ends at a version, the record had no events: it
  joined at an arbitrary later step, or was left out of the window's diff,
  and a reviewer set this way kept its later renames out of activity.

- `analyze_many`, and the `deleted` analyses of `analyze_scope`, give a record
  with nothing in the window an `activity_timeline` of `nil` unless
  `activity: true` was passed, as `analyze` does, so its `change_rows` raises
  `ConfigurationError` as for any other record. It was `[]`, so code that read
  `change_rows` without asking for activity passed while nothing changed.

- An STI root that changes class names its new class in the activity
  snapshots after the change, not its old one, and a subclass root's
  snapshot is carried from one of its versions to the next instead of being
  rebuilt at each one.

- Activity reports a change to a key that a child's own `belongs_to`
  follows, such as a comment's `reviewer_id` under `comments.reviewer`, in
  the step of the child's update. The child kept its old target until its
  next edit, or a root version, read the branch again, so the change showed
  up in a later step, credited to whoever saved that, and a window that
  held only the change reported nothing.

- Activity removes a `has_many :through` member when its join record moves
  to another owner or points at another record, also when a path below the
  through reads that join model again, as `contributors.authorships` does.
  The update changed only the copy under that path, so the through kept the
  member until another event read the branch again.

- A HABTM member created in a checkpoint's transaction appears in activity
  from its creation on, as in 0.14.0. Since 0.15.0, which counts such a
  member at the checkpoint, it appeared in every step back to the previous
  root version, before it existed and before members attached earlier. A
  range that ends at the checkpoint still ends with it, as `compare` does.

### Development

- `spec/oracle/replay_differential_spec.rb` replays generated histories
  with activity's incremental snapshots and with a full snapshot at every
  event, under `has_paper_trail only:` and `ignore:` and with keys written
  without a version, and fails on any difference. It found the first two
  bugs above.

- The through oracle renames a team at most once per transaction. A second
  rename made it expect a version to read the state before its transaction,
  which made `ORACLE_SEEDS=40..49` fail on seed 45 without a bug. The scoped
  membership oracle covers range scopes.

- Two oracle generators compare rebuilt history with plain Active Record:
  `spec/oracle/through_history_spec.rb` for every kind of `has_many :through`,
  and `spec/oracle/habtm_history_spec.rb` for HABTM membership between
  checkpoints. They found the three activity bugs above.

- Specs check that a range orders versions by time when their ids run the
  other way, and that an STI subclass's selection names only its own
  destroyed rows. A stub of the versions association these specs relied on
  stopped reaching the gem when it began reading versions from the version
  class, which left six mutations alive in a full mutation run.

## [0.15.0] - 2026-10-31

### Breaking changes

- A `within:` or `since:` window, and a range that starts at a version, can
  begin earlier than asked: an edge inside a transaction moves back to where
  the transaction began, as the two entries under Fixed describe. The first
  step of such a range has a `from_boundary` before the time or version you
  passed, so code that drops steps outside the range it asked for loses that
  step. (This entry was added after release; 0.15.0 listed the change only
  under Fixed.)

- An association whose model keeps its versions, or its PT-AT version
  associations, in different tables than its owner's raises
  `UnsupportedAssociationError` in every method, and `association_paths`
  leaves it out. History read through it was wrong: PT-AT records a child's
  membership with the child's versions but reads it from the owner's tables,
  so a child that moved to another owner was never reported as removed, and a
  root with its own version table raised `ActiveRecord::StatementInvalid`.

- An association keyed on a column other than a primary key
  (`primary_key: :legacy_id`), or a `has_many :through` with such a part,
  raises `UnsupportedAssociationError` up front in every method, and
  `association_paths` leaves it out. PT-AT records which record a child
  pointed at by that record's ID, and history matched children by ID, so an
  article's history showed another article's comments, and a comment's past
  article was the wrong one. Comparisons against the current record were
  right, so the same range disagreed with itself.
- An association path history cannot read, such as one with a scope written
  as SQL text, a scope that takes the owner, or a condition on a string
  column on MySQL or SQL Server, raises `UnsupportedAssociationError` in every
  method that reads history, unless you pass the new `allow_approximate: true`.
  The gem reads such a path with PT-AT, which rebuilds an association from its
  current members and never checks the scope against them: a record that
  entered the scope since was reported as a member it was not, so a comment
  moved into `-> { where("position > 2") }` showed as changed rather than
  added. Single-record methods did this without warning, and batch methods
  described it only as costly.
- `include_deleted: true` keeps only the deleted records that met the
  relation's conditions when they were destroyed, in both `deleted` and
  `unreachable`. It returned every deleted record of the model that changed in
  the window, so a report on one account's articles included other accounts'
  deleted articles with their contents. The relation's conditions must be
  plain conditions on the model's own columns; a join or SQL text raises
  `ConfigurationError`.

### Added

- `diagnose` reports every reason `compare` would refuse the same request as
  an error, with `compare`'s message, so `ok?` is false whenever `compare`
  would refuse. It said `ok?` for a path `compare` reads only approximately,
  such as a scope written as SQL text, raised on an unknown or unsupported
  association instead of reporting it, and checked only the join model a
  `has_many :through` goes through first, not every model it reads. It
  takes `allow_approximate:`, and with `true` reports such a path as an
  `:approximate_association` warning. The new error codes are
  `:unknown_association`, `:unsupported_association`, and
  `:approximate_association`; an unversioned target's message now matches
  `compare`'s.

- `diagnose` takes the current record as either endpoint, as `compare` does,
  so `compare(version, record)` can be checked before it runs. Its version
  checks then run from the version to the latest one. An endpoint that is
  neither a version nor a saved record raises `InvalidEndpointError` naming
  that, rather than `VersionMismatchError`.

- Activity steps list the events whose changes they show as `step.sources`,
  oldest first. A step from `group: :transaction` lists every event in the
  transaction, each with its own author, record, and version ID, where
  `source_boundary` names only the first. `to_h(metadata: true)` adds a
  `sources` list.
- `recorded_changes: true` on `activity_timeline`, on `analyze`, `analyze_many`,
  and `analyze_scope` with `activity: true`, and on `report` gives each
  boundary the changes its version recorded, as `recorded_changes(version)`
  returns them. The versions are already loaded, so it adds no queries, and it
  replaces the reference recipe that loaded every step's version again.
  Without the option, `boundary.recorded_changes` raises `ConfigurationError`
  rather than returning `nil`. Names in `ignore:` or `ignore: { all: }` are
  left out, and so are names on the root path, `"$"`, for the root's own
  versions. Names on an association path are not, because a child's version
  does not say which path reached it.
- `change_rows` on an activity step, on an `Analysis` built with
  `activity: true`, and on a `report` or `analyze_scope` result flattens
  activity into `ChangeRow` objects: one per edited field, and one per record
  that appeared or disappeared followed by its fields. Each names its record,
  association path, and source version, and `to_h` gives a flat hash. It
  replaces the README recipe for turning a report into rows, which had no rows
  for whole records, so a record added or removed with only blank fields left
  no trace.

- `associations:` takes what `includes` takes: a single name
  (`associations: :comments`) or hashes of names to what to include below them
  (`associations: [:author, { comments: :replies }]`), as well as the arrays of
  names and dotted paths it took before.

- `nested_changes` compares two top-level arrays, as a `json` column can hold,
  and reports one `ArrayChange` at the empty path, `[]`. It returned `{}`,
  although arrays nested in an object were compared.

### Changed

- The reference describes how PT-AT records HABTM membership and how the gem
  credits it. A change made between two root versions is credited to the
  step after the earlier one, so a checkpoint's capture is credited to whoever
  saved the version before it; a checkpoint just before the change as well
  credits it to its author. Only the first version an instance saves after
  changing a HABTM is right; PT-AT never forgets the instance's changes, not
  even on `reload`. A later save from it records the old membership, and the
  gem reports members removed and added again that never left.

- The performance guide describes current behavior instead of logging each
  past change: what the batch methods cost, what still grows with a report,
  the version indexes, what costs a query per record, historical filters,
  large reports, and how to measure. Its measurements were taken again. The
  earlier ones remain in `benchmark/results/` and in the changelog.

- `historical_filter:` reads the history of the relation's records only, and
  of deleted records, which a relation cannot test. It read every record of
  the model that changed in the window, so a report on one account's articles
  raised `BatchLimitExceededError` when another account had more matching
  articles than `limit:`, and spent `max_filter_versions:` on their versions.
  Matching deleted records no longer count toward `limit:` unless
  `include_deleted: true` is given, as without a filter.

- The reference says how a record created without a version, such as one
  imported with `insert_all`, and history pruned with `has_paper_trail
  limit:` read.

- `IncompleteTimeRangeError` no longer advises the deprecated
  `close_on: :current`. The quickstart and performance guide no longer say
  that `has_many :through` or limited associations need the opt-ins, and the
  reference says that `association_paths` lists paths that need
  `allow_approximate: true`.

- The quickstart sets PaperTrail's `yaml_column_permitted_classes`. In a new
  Rails 8.1 app, versions hold timestamps as `ActiveSupport::TimeWithZone`,
  and the quickstart's first `reify` raised `Psych::DisallowedClass` without
  it. Its documentation spec now reads a version in that form.

- The README and architecture guide recommend a second version index,
  `(item_type, created_at, item_id)`. Batch methods with `since:` or
  `within:` find changed records by type and time, which the one index they
  recommended cannot narrow, so each report read every version of the model:
  about 230 ms instead of 2 ms on PostgreSQL with 5 million versions.
- The gemspec requires Active Record 7.1 to 8.1. CI tests 7.2 through 8.1,
  and the suite passes on 7.1. It named only PaperTrail, so Bundler could
  install the gem with Active Record 6.1 or 7.0, whose relations and Arel
  nodes the gem reads differently.
- `close_on:` is deprecated and warns through the new
  `PaperTrailDiff.deprecator`. It has had no effect since a window began
  closing on the current record by default; remove it. In a Rails app,
  register the deprecator with
  `Rails.application.deprecators[:paper_trail_diff] = PaperTrailDiff.deprecator`.
- `allow_expensive:` is deprecated and has no effect. It refused exactly the
  paths `allow_approximate:` refuses, so batch methods needed both or
  neither; `allow_approximate: true` alone now accepts such a path in every
  method, and `UnsupportedBatchPathError` is no longer raised. Batch methods
  refuse such a path before their first query, as before, now with
  `UnsupportedAssociationError`.
- `reload_live_endpoints:` is deprecated and warns. It still works until it
  is removed. Skipping the reload saves a query for the records and one per
  association level in each call, 2 for 500 articles with their comments,
  and reads values from objects that may be stale; it also needs every
  requested association loaded, and reads limited ones again anyway. It was
  on `compare`, `compare_many`, and `activity_timeline` only. Remove it.

### Fixed

- A HABTM member created in the same transaction as the checkpoint that
  records it is a member at that checkpoint, as a member attached there
  already was. It was left out, because it had no state before the
  transaction, so the checkpoint missed it and a comparison from the
  checkpoint to now reported it added.

- `association_paths` leaves out an association whose target, or a model its
  `has_many :through` goes through, has no `has_paper_trail`, such as the
  `file_attachment` and `file_blob` that `has_one_attached` defines. Every
  request that reads history refused them with `UnversionedAssociationError`,
  so a settings screen built from the list offered paths that always failed.

- `diagnose` reports `:tied_version_timestamps`, and `compare` emits
  `ambiguous_association_boundary.paper_trail_diff`, only when the request can
  read a path with PT-AT: one history reads only approximately, a composite
  foreign key, or a polymorphic `belongs_to`. PT-AT places association changes
  by timestamp alone. For every other path, since 0.14.0, versions that share a
  timestamp are ordered by ID, so a change between them is reported, yet both
  warned that it could not be detected. A request refused for a path PT-AT
  would read now raises before the notification.

- `timeline`, `activity_timeline`, and `analyze` read every version of a
  model whose versions association has a scope
  (`has_paper_trail versions: { scope: }`), as the other methods already did.
  They read only the versions the scope kept, so a change saved in a version
  it left out was credited to the next one kept: with a bot's edits hidden,
  an editor's step showed the bot's later edit too, and the same record and
  window gave different steps in `analyze` and `analyze_many`. A version the
  scope leaves out is also accepted as an endpoint. To report only some
  changes, pass `version_scope:`.

- Activity steps leave out the versions a record saved while it was outside
  the root's tree. A comment edited on another article, then moved to this
  one, brought that edit into the article's timeline as a step, and a
  transaction group's `sources` listed it. Saved together with a comment added
  to the article, the edit took the credit for the addition. The same went for
  a comment edited after it moved away or left a scope, and for an author
  renamed after the article changed authors. A version now counts when its
  record is in the tree before or after its transaction. The versions of a
  `has_many :through`'s join rows are all still kept.

- `timeline`, `activity_timeline`, `analyze`, and `analyze_many` raise
  `InvalidEndpointError` naming what they were given when it is not a record
  of a versioned model, such as `nil`, a model class, a relation, or a
  version. They raised a bare `NoMethodError`, or said to provide `from` and
  `to`. `report` names `since` when it is `nil` or a range.

- A scope ordered by a datetime, such as
  `-> { order(created_at: :desc, id: :desc).limit(3) }`, is read from history
  under Rails' default time-zone-aware attributes. Rails wraps those
  attributes' types, which hid the datetime, so every method raised
  `UnsupportedAssociationError` for the documented recipe.

- A `Date` bound of `within:` or `since:` is a whole day in `Time.zone`, and
  a string a time in `Time.zone`, or in UTC without one. They were read in
  the server's own zone, so the same window covered different hours on
  different servers, and a same-day `Date..Date` window covered one instant
  and found nothing.

- A `has_many :through` whose join model is not versioned raises
  `UnversionedAssociationError` naming the join model when its history is
  read, and `diagnose` reports it as an error, so `ok?` is false. A
  comparison raised a bare `KeyError` while `diagnose` reported only a
  warning.

- `reload_live_endpoints: false` reads an association with a `limit` or
  `offset`, directly or in a part it goes through, or a scope that takes the
  owner, again for each record. Active Record's `preload` applies the limit across all the records
  it loads, so with three articles preloaded, two kept one comment each and
  the third none, and their unchanged comments were reported as removed.

- A root and its associations that share one version table other than
  PaperTrail's `versions` can be compared. Association lookups joined PT-AT's
  version associations to the `versions` table whatever table the versions
  were in, so every method raised `ActiveRecord::StatementInvalid`.

- A `within:` or `since:` window whose edge falls inside a transaction that
  saved a version of the root record reports the whole transaction in the
  later window. A window starting between a comment edit and the `touch: true`
  article version saved with it showed the edit at the article's next change,
  credited to that change's author, and the window ending there left it out;
  when the article saved first, its version was in one window and the comment
  edit in the other. Each root's edges move back to the transaction's start,
  read in a fixed number of queries per 200 records.

- `activity_timeline`, and `analyze` with `activity: true`, no longer report a
  child version saved in the same transaction as the root version that ends
  the range. A `touch: true` parent version is saved this way after every
  child save. PT-AT rebuilds the parent's associations at that version as they
  were before the transaction, so the child's step was always empty and its
  change was reported nowhere. The range now ends before that transaction, as
  `compare` and `timeline` already did. End at a later version or at the
  current record to include the change, with `group: :transaction` to credit it
  to the child's version.
- A range that starts at a version now starts before that version's
  transaction, as one that ends there already ended. A child version saved
  earlier in the same transaction, such as the update behind a `touch: true`
  parent version, was read after its change, so `compare`, `analyze`,
  `timeline`, and `activity_timeline` from that version left the change out.
  It was also missing from the range ending there, so a history split at that
  version reported it nowhere. It is now inside the range that starts there.
- A past `within:` window in `activity_timeline`, and in `analyze`,
  `analyze_many`, `analyze_scope`, and `report` with `activity: true`, no
  longer includes association changes made after it. When the root had no
  version after the window, the window closed on current state, so a comment
  edited in August appeared in a July window, in its last step, `to_snapshot`,
  and `diff`; with a later root version the same window was right. It now
  closes on current state only when nothing on a requested path was recorded
  after it. The reasoning in 0.8.0, that nothing had been recorded since,
  checked only the root's own versions. `timeline`, and `analyze` without
  `activity:`, still run their last step to the root's next version or the
  current record; the reference now says so.
- Association scopes read from history now cover `IS NULL` and `IS NOT NULL`
  on a column of any type, such as a soft-delete scope's
  `where(deleted_at: nil)`, and `NOT` with SQL's rules for NULL, such as
  `where.not(position: [1, nil])`. These were read with PT-AT before, so a
  record restored from a soft delete showed as changed rather than added, and
  batch methods refused them without `allow_expensive: true`. A condition on a
  PostgreSQL `citext` column, which compares without regard to case, is no
  longer read as exact text.
- A `historical_filter:` hash casts its values, and the recorded ones, to each
  attribute's type before comparing them, as `where` does. An enum given as a
  symbol (`{ status: :published }`), and a date or time read from a `json` or
  `jsonb` version column, which PaperTrail returns as a string, never matched,
  so the report silently selected nothing.
- Versions from two version tables saved in the same instant raise
  `AmbiguousVersionOrderError`, as the reference promises, instead of being
  ordered by their ids. Each table counts its ids separately, so their order
  said nothing about which change came first, and an activity timeline built
  from them could credit a change to the wrong step.
- `compare_many`, `analyze_many`, `analyze_scope`, and `report` load a
  `has_one` of every current record in one query again, as before 0.14.0.
  0.14.0 meant to load only a `has_one` with a declared limit or offset per
  record, but checked the association's scope, to which Active Record adds
  `limit(1)` for every `has_one`, so every `has_one` cost one query per
  record.
- `report`, `analyze_scope`, and `analyze_many` with `activity: true` no
  longer read a root's current row once more for activity through a
  `has_many :through` after its last version. The batch has already loaded
  it, so the query count no longer grows with the number of roots.
- A snapshot's collections list their records by type, then ID, as the
  reference says, wherever the snapshot was read from. Snapshots rebuilt from
  history or carried through an activity timeline listed them in the order
  they were found, and a ranked association in its query's order, so `to_h` of
  the same state differed between methods. Diffs were already ordered.
- With a `json` or `jsonb` `object` column, an activity step no longer
  reports an unchanged timestamp as changed. PaperTrail returns such a
  column's times as strings, and a step after a child's update carried them
  into the snapshot as they were, so the next step that read the child again
  reported `created_at` changing from a string to the same time. Activity now
  casts them as it does every other recorded state. The specs had covered the
  JSON serializer on a text column only, which PaperTrail casts.

### Development

- A new oracle suite, `rake spec_oracle`, checks rebuilt history against the
  truth rather than against other gem methods. It makes seeded random edits to
  an article graph one transaction at a time, records the live state after
  each, and compares every endpoint, timeline step, activity step, window, and
  batch result with those states. It also checks that two windows meeting
  between transactions or inside one report each step once, scoped membership
  against Active Record, and a tree of one model whose children have
  encrypted, serialized, enum, custom-type, decimal, and JSON attributes.
  `rake spec` runs it, so CI runs it on every database. `ORACLE_SEEDS` and
  `ORACLE_STEPS` widen a run. See `docs/testing.md`.
- `PTD_PROBE_ALLOW_APPROXIMATE=1` makes the reconstruction probe pass
  `allow_approximate: true`, so its PT-AT-read scenario runs rather than
  raising, and neither benchmark passes the deprecated `close_on:` any more.
- On SQL Server the association specs keep their versions 5 ms apart. Specs
  that compare the gem with PT-AT failed at random there: PT-AT compares
  version times through SQL text, which the SQL Server adapter writes as
  `datetime` values up to 1/300 s off, and after the host clock stepped back
  the test clock packed versions microseconds apart until it caught up.
- The reporting benchmark loads the monotonic test clock, so its results no
  longer depend on the host clock. A clock that stepped backwards, as WSL2's
  does, could date a root's destroy before its last update, and
  `deleted_roots` then raised `IncompleteTimeRangeError`. The seeded history
  and query counts are unchanged. Allocations rise by under 1% in
  `many_roots` and `retained_activity`, where the gem reads the clock once
  per root. The investigation scripts that seed through the same workload
  load the clock too; `scalar_cost.rb` freezes time in front of it, so its
  parity check still sees one instant.

## [0.14.0] - 2026-10-29

### Breaking changes

- A `has_and_belongs_to_many` with a scope, or whose target has a default
  scope, raises `UnsupportedAssociationError` up front in every method, and
  `association_paths` leaves it out. PT-AT records a HABTM's members through
  its scope when the owner saves, so a target that entered the scope between
  saves was missing from history, and `activity_timeline` raised `KeyError`.
  Replace it with a `has_many :through` a versioned join model.
- `report`, and `analyze_scope` with `activity: true`, also select a record
  when only a record on one of its requested `associations:` changed in the
  window: editing a comment selects its article. They used to skip it, although
  `analyze_many` reports that activity. A report can therefore return more
  records and reach `limit:` sooner. Nested paths count at every level,
  `has_many :through` counts its join rows, and a child that moved selects its
  old and new owner. Selection adds one query per association level, not per
  record. Checkpoint analyses (`activity: false`) are unchanged: they compare a
  record's own versions, so only those select it. To keep only records that
  changed themselves, drop analyses whose `timeline` is empty. A record
  selected through a HABTM path in a window that ends at the current record
  raises `UnsupportedLiveActivityError`, as one that changed itself already
  does.
- A path that continues past a polymorphic `belongs_to`, such as
  `"notable.comments"`, raises `UnsupportedAssociationError`. The part after
  it used to be ignored without a word.
- A HABTM below the root, such as `"tags.articles"`, `"author.articles.tags"`,
  or `"comments.article.tags"`, raises `UnsupportedAssociationError` up front
  in every method, naming the path and the HABTM. `association_paths` leaves
  such a path out. PT-AT records HABTM membership only when its owner saves a
  version, in rows that do not name the owner, so a root checkpoint holds the
  root's membership alone. These paths read the root's rows instead and
  returned a wrong diff. An article that joined a tag went unreported, and
  against the current record every member read as added. A sibling article
  reached through its author was given the root's tags. `activity_timeline`
  raised `KeyError`. Only a path that led back to the root, like
  `"comments.article.tags"`, read correctly; request `"tags"` instead.
- A root HABTM read at a version saved in the same transaction as a version of
  another record with a HABTM of that name raises
  `IncompleteAssociationHistoryError`, naming the association and the
  transaction, when PT-AT recorded members there. Those rows do not say which
  record they belong to, so the root used to read every such record's members
  as its own: two articles updated in one transaction each gained the other's
  tags, and an unchanged article reported them removed. It happened in every
  method, with no error. A transaction where only one record with that
  association saved a version, or where none recorded a member, reads as
  before, and `diagnose` reports the shared case as `habtm_transaction_shared`.
  Save HABTM owners' versions in separate transactions, as a
  [checkpoint](docs/reference.md#saving-a-checkpoint) does.

### Added

- `recorded_changes(version)` returns what PaperTrail stored with one version
  in `object_changes`, as a frozen hash of `ValueChange` objects, typed by the
  version's model. Unlike PaperTrail's `version.changeset`, it never loads the
  record, so it costs no query per version and still types a deleted record's
  values. It returns `nil` when nothing was recorded, and takes an `ignore:`
  array that defaults to `updated_at`.

### Changed

- Batch reads of a `has_many :through` and of a polymorphic `belongs_to` no
  longer call `reify` on each root version. They are read from stored
  attributes like other associations. In the reconstruction probe, `report`
  over a through went from 7 `reify` calls per root to none and builds about
  half as many model instances. Results are unchanged. A type that names no
  class, an unversioned target, and a scope that cannot be read as conditions
  still take the record path.
- Batch methods read an association scope, or a target's default scope, made
  of plain conditions on the target's columns (equality, `IN`, `nil`, their
  `where.not` forms, combined with `and` and `or`) from prepared history, so
  they no longer need `allow_expensive: true` for it and its query count no
  longer grows with the records. String conditions are read this way only on
  SQLite and PostgreSQL. Scopes that take the owner and other conditions are
  still rejected without the opt-in. A default-scoped model whose scope assigns
  no attributes is read without `reify`.
- Batch methods also read a `limit` or `offset`, and the order of a `has_one`,
  from prepared history when the order is total, reaching the primary key, and
  sorts only by integer, boolean, or integer enum columns of the target. NULL
  sorts as each adapter puts it by default. In the reconstruction probe,
  `report` over `order(:id).limit(1)` went from 252 queries and 160 `reify`
  calls at 20 roots, with the opt-in, to 32 queries and none without it. A
  string order, an order with ties, and a `has_one :through` over a ranked
  part are still rejected without the opt-in.
- Batch methods also rank by date columns, and by datetime columns when the
  column declares a precision that history keeps and times are stored in UTC,
  such as `order(created_at: :desc).limit(5)` with YAML history. JSON history
  keeps milliseconds by default, so with it only a `datetime(3)` column is
  read. A time-of-day column, and a datetime without a precision, are still
  rejected without the opt-in.
- Batch methods read a `has_many :through` over a part with a `limit`,
  `offset`, or `has_one` order, and one with its own `limit` or `offset`, from
  prepared history without the opt-in.
- The README recipe for deleted records also reads each record as it was just
  before deletion, which a record created inside the window has no other
  snapshot of.
- The documentation now says where a change saved without a version, such as
  with `update_columns`, appears: in the step for that record's previous
  recorded change, credited to its author, anywhere in a range. It used to say
  only that the last step of a range ending at the current record shows them,
  and that a step's diff is exactly what its event changed. Ending a range at a
  version leaves out only the writes after it. Specs pin this behavior, which
  is unchanged.
- The README has a recipe that turns a report into one row per changed field,
  with the record, whether it changed, appeared, or disappeared, and the step's
  author, event, and time.
- Batch methods no longer need `allow_expensive: true` for a
  `has_many :through` whose source is a `has_many`, such as an author's
  comments through articles. It is read from prepared history like the other
  associations, so its queries no longer grow with the records: the five-record
  probe in `docs/performance.md` went from 200 queries to 20.

### Fixed

- A `limit` or `offset` scope, or an ordered `has_one`, read at a version
  returns the records its query returned then, when the order is total and
  sorts by columns batch methods can rank. It used to start from
  the association's current rows, so a range whose records later changed
  reported the wrong ones: with comments `first` and `second` under
  `order(:id).limit(1)`, destroying `first` and adding `third` reported
  `third` added instead of `second`. Other ranked scopes still read the
  current rows.
- A `has_many :through` reads its parts as its own query does, keeping their
  conditions but not their `limit`, `offset`, or `has_one` cut. History used
  to apply them, and read with the opt-in it could raise PT-AT's
  `FoundMoreThanOne`; batched history kept only one record through a `has_one`
  part. A through's own `limit` or `offset` counts a record reached through
  two join records twice, as the query does.
- Batch comparisons with a current endpoint load a `has_many :through` over a
  part with a `limit`, `offset`, or `has_one` per record. Active Record's
  preloader applied the part's limit across every record in the batch, so a
  record could show another's members or none.
- A record reached through two join records is one member of a current
  association, as it already was of a historical one, so a through loaded per
  record no longer raises a duplicate identity error.
- In a batch, a `has_one` with an `offset` is loaded per record at the current
  end. The preloader applied the offset across all records at once, so a
  record could show another record's member.
- Activity reports a change to a `belongs_to` target that is an STI subclass.
  When the target was destroyed, or its `type` changed between a subclass and
  another class, activity reported nothing while checkpoint analysis reported
  it, because a target's version names only the base class. This includes the
  same target further down a path, such as `"note.badge"`.
- An association that only an STI subclass declares can be requested on a
  root of that subclass in every method. Without an `item_subtype` column on
  versions, each version resolved to the base class, so every method raised
  `UnknownAssociationError`. The subclass is now read from the type the
  version stored, or for a `create`, from its recorded changes. A stored type
  that names no class raises `InvalidEndpointError`.
- A `has_many :through` with `source_type:` holds only the records reached
  through join records of that type, in every method. History used to ignore
  the option, so a join record pointing at another type made its target a
  member: a holder whose links named a tag reported the tag among its authors,
  and the tag's changes opened activity steps and selected the holder in
  `report`. The current record was read correctly, so a comparison with it
  reported the tag as removed. A join record whose type changes now adds or
  removes its target in the step of that version.
- A scoped or default-scoped association read from history now holds the
  records that met the scope at each point. It used to ignore the scope's
  conditions for history: a record that left the scope was reported as
  changed instead of removed, one that entered it as changed instead of
  added, and a record outside the scope could be reported as removed when it
  was destroyed or moved. Activity reports entering or leaving the scope as
  an addition or removal at the version that did it.
- `compare` and `compare_many` between two versions report a `has_many` child
  that moved to another owner afterwards. They reported no change: the
  comparison read associations through PT-AT, which finds children by the keys
  their versions recorded after each change, so the child was not found at the
  earlier version. Version pairs now read the same prepared history as a
  comparison with the current record, including for a record that was deleted.
- Historical analysis through a polymorphic `belongs_to` works in every method.
  Only comparisons between two versions used to work: timelines, analyses,
  reports, and comparisons with the current record raised `ArgumentError`.
  Batches load the targets with one query per target class. A target class
  without `has_paper_trail` raises `UnversionedAssociationError` when a record
  names it, rather than a `NoMethodError` from PT-AT, and a default-scoped
  target class is read as its association returns it. A type that names no
  class, such as one a renamed model left in its versions, raises
  `IncompleteAssociationHistoryError` naming the record and the type, rather
  than a `NameError` that names neither.
- Activity leaves out the `belongs_to` target a record moves to in the
  version that closes the window. Its changes inside the window used to add
  empty steps, attributed to a record the root never pointed at there.
- Activity reports a change to a `belongs_to` target, or to the source of a
  `has_many :through`, when the record pointing at it did not change in the
  window: an author renamed under an article nobody edited. It used to report
  nothing. A record that changed its target in the window also reports
  changes to the target it pointed at before.
- `include_deleted: true` with `activity: true` reports the association
  activity of a deleted record that did not change itself in the window. Its
  analysis used to be empty.
- History of an association to an STI subclass, such as
  `has_many :pinned_badges, class_name: 'PinnedBadge'`, holds only that class
  and its subclasses, as the live association does. It used to hold the
  sibling classes' records too, so a range ending at the current record
  reported them as removed. Activity used to report a sibling's changes under
  the association too, and to open a step for each version of a sibling or of
  its children.
- Activity reports a record whose STI type changed in the step of the version
  that changed it, as a removal of the old type and an addition of the new,
  and adds it to or removes it from an association to an STI subclass there.
  It used to add the new type alongside the old one and leave the old one in
  place until a later step, or to the end of a range ending at a version.
- `activity_timeline`, and `analyze` with `activity: true`, return no steps for
  a range that ends at a version when `version_scope:` keeps none of its
  versions, as a checkpoint timeline does. They used to raise `NoMethodError`.
- `analyze_scope` and `report` list `unreachable` in the same sorted order
  whatever the type of `versions.item_id`. With a string `item_id` it used to
  follow the database's order.
- On SQL Server, activity places a version saved within two milliseconds of a
  window's start or end on the side it was saved. The window's bounds used to
  be rounded to 1/300 second, so such a version could be read as outside the
  window, or one just past its end as inside it.
- A `has_many :through` that goes through a `has_and_belongs_to_many`, as its
  `through:`, its `source:`, or further down its chain, raises
  `UnsupportedAssociationError` up front in every method, naming the path and
  the HABTM. Comparing two versions used to raise `NoMethodError` from inside
  PT-AT, and analyses `ActiveRecord::StatementInvalid`. A `has_many :through`
  Active Record cannot follow at all, such as one through a polymorphic
  `belongs_to`, likewise raises Active Record's own error in every method,
  where historical work used to fail partway with `ArgumentError` or
  `NoMethodError`.
- `association_paths` leaves out a `has_many :through` that goes through a
  `has_and_belongs_to_many`, so every path it lists can be requested. It
  decides with the same check a request makes. It used to list such a path,
  and a settings screen built from it offered one that failed when picked. A
  model it reaches with a `has_many :through` Active Record cannot follow,
  such as one through a polymorphic `belongs_to`, raises Active Record's own
  error, where discovery used to raise `ArgumentError`, `NameError`, or
  `NoMethodError` from inside the reflection, or list a path that raised when
  requested.
- A `has_many :through` whose source is a `has_many` follows records that
  move. A comment moved to another article leaves the first article's author
  and joins the other's, and an article that moves to another author takes its
  comments with it. Analyses, timelines, and comparisons with the current
  record used to report no change for such a move, and could report a record
  that left and came back as changed. They read these associations through
  PT-AT, which finds a record by the keys its later versions recorded.
- A `has_many :through` whose `through:` is itself a `has_many :through`, such
  as `has_many :comment_reviewers, through: :comments, source: :reviewer` with
  `comments` through `articles`, reports its changes in analyses, timelines,
  and batches. It used to read as empty at every point, so it never reported a
  change.

### Development

- Mutation testing also covers `ScopeCondition`, which decides the records an
  association scope admits. The reconstruction probe has a `scoped` scenario.
- The consistency specs also check that activity selection includes every
  record whose analysis reports a change.
- Mutation testing also covers `TimeRange`, `VersionRange`,
  `TimeVersionRange`, `BatchedRootVersions`, and `DeletedAnalysisBatch`, each
  with a unit spec of its own; all 5,485 mutations across the fourteen classes
  are caught.
- Mutation testing also covers `RecordedChanges`; all 257 of its mutations are
  caught.
- Mutation testing also covers the association code: `ScopedRootSelection`,
  `AssociationActivitySelection`, `AssociationActivityEdge`,
  `ActivityTargetCandidateLoader`, `PreparedHistoryLoader`,
  `PreparedEdgeLoader`, `ActivityTimelineBuilder`,
  `ActivityTransactionGrouper`, and `BatchSafety`, each with a spec of its
  own. All 10,732 mutations across the 24 classes are caught.
- Mutation testing also covers `AssociationTraversal`, which decides which
  association paths a request accepts, with a spec of its own; all 764 of its
  mutations are caught.
- Mutation testing also covers range and boundary handling:
  `ActivityRange`, `VersionAssociationCandidateScope`, and
  `PreparedActivityIndex`, each with a spec of its own; all 1,507 of their
  mutations are caught.
- Mutation testing also covers `HabtmTransactionOwners`, which decides whether
  a transaction's HABTM members can be read as one record's, with a spec of
  its own.
- `benchmark/investigation/reconstruction.rb` runs again: the association
  fixtures load the monotonic test clock they use. Its `prepared-through`
  experiment and `benchmark/investigation/prepared_through_override.rb` are
  removed, since the gem now reads those throughs that way.
- `spec/association/through_membership_spec.rb` writes out the expected
  membership of a `has_many :through` with a `has_many` source over moves,
  deletions, transactions, and changes saved without a version, alone and in
  a batch.
- `ActivityEventRouteFinder` no longer checks for a polymorphic `belongs_to`
  before following a path below it. Validation already rejects such a path,
  so the check could not be reached.
- The `PreparedHistoryLoader` spec checks that an edge into a versioned model
  with records stays prepared. A full mutation run of the 29 classes now
  catches all 13,284 mutations.

## [0.13.1] - 2026-10-28

### Fixed

- A collection transition whose before and after records have different
  identities reports the before record as removed and the after record as
  added. It used to report nothing. No current caller builds one, but
  `AssociationSnapshot#transition_to` accepts it.
- A record with a composite primary key, read from prepared history, gets the
  same id as when it is read live: the key's values. It was `nil`.

### Changed

- `RecordSnapshot.new` requires `type:` to be a String and raises
  `ArgumentError` otherwise. It used to convert any value with `to_s`.

### Development

- Mutation testing gives each mutation 60 seconds instead of mutant's 5-second
  default. Mutant counts a timeout as a kill, so mutations no spec caught were
  reported as caught. With the longer limit, 123 surfaced in
  `CollectionComparator` and `CollectionIdentityIndex`; each class now has a
  unit spec, and all of them are caught.
- Mutation testing also covers `SnapshotNormalizer`, `SnapshotPool`,
  `TimelineRange`, `RootVersionPlan`, and `HistoricalFilter`, each with a unit
  spec of its own; all 4,040 mutations across the nine classes are caught.
  Versions are ordered by time and then id through one shared helper.
- The full mutation run moves to a nightly workflow that runs only when `main`
  has an untested commit, so a later push no longer cancels it. Pull requests
  still mutate the methods they change.

## [0.13.0] - 2026-10-28

### Breaking changes

- `:last` is no longer accepted as an endpoint. It named the last version, whose
  recorded state is the one *before* the latest change, so ranges ending there
  silently left that change out. Omit `to:` to end at current state, or pass a
  version. Passing `:last` raises with that advice.
- `analyze_many` without `within:` now ends each record's history at its current
  state, so the latest change is included. It previously stopped at the last
  version.
- Batch methods reject scoped associations, default-scoped targets, and
  `has_many :through` associations whose source is not a `belongs_to`, because
  they need queries per record. The error names the association. Pass
  `allow_expensive: true` to accept that cost.
- `Step#to_h` returns `{ from:, to:, diff: }`, the same shape as
  `ActivityStep#to_h`, with boundary hashes on both sides. Read the version ids
  from `from[:version_id]` and `to[:version_id]` instead of `from_version_id`
  and `to_version_id`; `metadata: true` adds details to both boundaries.
- `analyze_many` takes only an array of records. Use `analyze_scope` with a
  model or relation; `analyze_many(scope:, limit:)` and the scoped options it
  accepted have been removed.

### Added

- `report(scope, since:, limit:)` for recent activity through current state.
- `historical_filter:` on `analyze_scope` and `report`, selecting records by
  values they had at any point in the window: their state when it started and
  after each change inside it. Pass an attribute hash, which reads stored values
  without reifying, or a callable. `max_filter_versions:` (default 10,000) caps
  the versions it loads and raises `FilterLimitExceededError` beyond that.
- `include_deleted: true` on `analyze_scope` and `report`, returning analyses of
  deleted records in `deleted` (`nil` when no destroy version was recorded).
  Existing and deleted records together count toward `limit:`.
- `ScopedAnalysis#roots`, the selected records in relation order.
- `timeline`, `activity_timeline`, and `analyze` default to `from: :first` and
  `to: record`, so `timeline(article)` covers the whole history through the
  current saved record.
- `source_boundary` on both step types names the event whose change a step
  reports. For a transaction group it is the first event.
- `metadata: true` on `to_h` for boundaries, steps, and analyses adds author,
  event, transaction ID, and record. `ActivityStep#to_h(snapshots: true)` and
  `Analysis#to_h(snapshots: true)` include retained states.
- `group:` and `snapshots:` on `analyze_many` and `analyze_scope` with
  `activity: true`.
- Explicit current-record `to:` endpoints on `timeline` and `analyze`.

### Changed

- A `within:` window with no version after its last change closes on the current
  record instead of raising `IncompleteTimeRangeError`. Nothing has been
  recorded since that change, so the current record holds what it produced.
  This also applies to windows in which only chosen associations changed.
  `close_on: :current` is no longer needed and is still accepted.
- Live-ended HABTM activity is rejected only when a range actually ends at the
  current record, including in batches.
- `compare` with `associations:` reads association state from the prepared
  history `compare_many` uses, instead of PT-AT's timestamp-only reifier.
- Plain recorded attributes of root and direct-child records are read without
  building a model instance per historical state. Models with initialization
  callbacks, custom types or defaults, default scopes, or encrypted attributes
  still use PaperTrail's `reify`.
- Batch activity reports share association discovery and prepared history
  across records, and each analysis reuses its checkpoint snapshots, so standard
  reports no longer add queries per record.
- Activity without changesets uses prepared successor states instead of a query
  per event.
- `has_many :through` reconstruction visits only the requested source
  association.
- Scope selection keeps candidate records in a database subquery when
  `versions.item_id` and the primary key share a column type, reads joined rows
  in pages of 250, and sorts `unreachable`.
- `snapshots: true` without `activity: true` raises `ConfigurationError`, as
  `group:` already did, instead of being ignored.
- The README is now a set of recipes; the full API reference and architecture
  notes are separate pages.

### Fixed

- Association timelines no longer raise `duplicate record identity` when
  `versions.item_id` is a string column (PaperTrail's setup for UUID keys) and
  associated models use integer keys.
- Columns listed in `has_paper_trail skip:` are left out of snapshots. PaperTrail
  never stores them, so comparing history with the current record reported them
  as changed from their default.
- `analyze_many(..., activity: true)` reports association activity for a record
  with no version of its own in the window, matching `analyze`. It previously
  returned an empty analysis.
- Histories stored with PaperTrail's JSON serializer or a `json`/`jsonb` object
  column no longer report every timestamp as changed when compared with the
  current record.
- Association changes at versions sharing a timestamp are placed by version id,
  so `compare`, `compare_many`, and `timeline` no longer put them on the wrong
  side of a boundary. Ties that ids cannot order raise
  `AmbiguousVersionOrderError`.
- A window that closes on the record's deletion ends its `diff` and
  `to_snapshot` at "no record". A record created and deleted inside the window
  previously read as added.
- `compare_many` resolves `:first` to each record's earliest version by time,
  not the lowest id, which differs for UUID version ids.
- `version_scope:` is honored on activity timelines that end at the current
  record.
- Batch, single-record, and scoped activity results agree on the reporting
  window and closing state.
- A lone creation or update in an activity window that ends at the current
  record is reported.
- Joined relations count unique records against `limit:` without adding SQL
  `DISTINCT`, so ordering by joined columns works on PostgreSQL and SQL Server.
- Nested results are fully frozen, including nested paths and empty results.
- Nested object diffs match string and symbol keys consistently and raise
  `AmbiguousNestedKeyError` on collisions instead of losing a change.

### Development

- CI runs both suites on PostgreSQL 17, MySQL 8.4, and SQL Server 2022 alongside
  the SQLite Ruby/PaperTrail matrix. Database adapters are optional development
  dependencies.
- The type-check gate fails on Steep internal errors and checks public API call
  examples.
- RuboCop runs with the rubocop-performance and rubocop-rspec plugins.
- Consistency specs check that every method agrees on seeded, generated
  histories across schema and serializer variants.
- Mutation testing with mutant covers the comparison code, in CI and through
  `rake mutant`. New specs close the gaps it found: attributes present on only
  one side, a record removed, singular relationships added or removed, and
  JSON values held in Hash, Array, or String subclasses.

## [0.12.0] - 2026-08-19

### Changed

- Report an array inside a JSON column by membership rather than as one opaque
  value. `nested_changes` now returns a `PaperTrailDiff::ArrayChange` for a pair
  of arrays, carrying `added`, `removed` and `reordered?` alongside the whole
  `from` and `to` it already had. Position is deliberately not reported:
  elements carry no identity, so an insertion at the front makes every later
  index look changed and one insertion reads as several edits. Membership is
  answerable without claiming any pairing. Matching is by value and respects
  duplicates, so `["a", "a"]` to `["a"]` reports one removal. The one thing
  membership cannot see -- the same elements in a new order -- is named rather
  than passed over. An element that is itself an object is reported whole,
  since saying which of its fields changed would require pairing before- and
  after-elements that nothing in the value licenses.

## [0.11.0] - 2026-08-18

### Added

- Add `PaperTrailDiff.analyze_scope`, which selects the roots to analyze from an
  ActiveRecord relation or model class instead of an array the caller assembled,
  in a fixed number of queries. Also reachable as
  `PaperTrailDiff.analyze_many(scope: ..., limit: ...)`. Every other option
  behaves as it does for `analyze_many`.
- `analyze_scope` returns a `ScopedAnalysis`, which destructures into the usual
  analyses hash and the roots the relation could not reach. A relation's
  conditions are evaluated against the live table, so a root destroyed during
  the window cannot be tested against them at all, even though its history is
  intact and the state it held at destruction may have matched. Those roots are
  named rather than dropped, so a page auditing deletions is told where to look
  instead of coming up short without saying so.
- Add `PaperTrailDiff.nested_changes`, which reports the keys that changed
  inside an attribute the database stores whole, such as a JSON or jsonb column
  or one holding JSON as text. An attribute diff could only say the blob
  changed, leaving the caller to diff it again by hand. Paths are arrays rather
  than dotted strings, because a JSON key may itself contain a dot. Arrays are
  reported whole rather than by index, since their elements carry no identity
  and a list that merely shifted would otherwise look changed throughout. A key
  that was absent reads as `NestedComparator::ABSENT` rather than nil, because
  `{"a": null}` and `{}` mean different things in JSON and an audit trail that
  showed them alike would be lying about one of them. Additive: the existing
  attribute diff is unchanged, and a pair that is not two readable structures
  reports nothing.
- Raise `PaperTrailDiff::BatchLimitExceededError` when a relation selects more
  roots than `limit:` allows. `limit:` is required for `analyze_scope`: root
  selection moves into the gem, so the bound on how much work one page can ask
  for moves with it. It refuses rather than truncating, because a report that is
  quietly short is worse than one that fails.
- Accept `group: :transaction` on `activity_timeline` and `analyze(activity:
  true)`, reporting one saved transaction as one step. A parent and its
  children saved together produce a version each, so one deliberate action
  arrived as several steps, and some of them read as empty even though a change
  was made at that boundary: a version records the state before its own event,
  so a child's new value is revealed only by a later version of that child, its
  destroy version, or the live row, none of which exists yet inside the
  transaction. The change therefore surfaced a step or more later, folded in
  with whatever that step carried. A step belongs to the transaction of the
  event that opens it, since that is the event whose change it reports; a step
  therefore belongs to its `from_boundary`'s transaction, and consecutive steps
  sharing one are the parts of a single save. Merging compares the group's
  outer states rather than combining the diffs between them, so a field set and
  restored inside one transaction correctly reports as unchanged. Off by
  default.
- Expose `ActivityBoundary#transaction_id`.
- A boundary that records no transaction groups with nothing. PaperTrail leaves
  the column nil outside a transaction and a custom version class need not
  carry it at all, so treating those as one shared transaction would merge
  unrelated history into a single step.

### Changed

- Check that the generated Appraisal gemfiles match the `Gemfile`, in CI and in
  `rake release:preflight`. Every other job runs against a generated gemfile, so
  a dependency changed only in the `Gemfile` was one CI never installed: the
  jobs passed having exercised the old version.

### Fixed

- Resolve "does this model record history" through one predicate,
  `Support.versioned?`. Three copies existed and one of them tested only
  `respond_to?(:paper_trail)`, which PaperTrail defines on every ActiveRecord
  model and which therefore answers true for models that never called
  `has_paper_trail`. Nothing reached that copy with an unversioned model, since
  the traversal preparer rejects those first, so no released behaviour changed --
  but the check looked right while being unable to fail, and reading history
  through it would have raised at the version class rather than at the question.

## [0.10.0] - 2026-08-15

### Added

- Add `rake release:preflight`, which runs the full gate and then checks
  everything that must hold before a tag: a clean working tree, a HEAD that
  matches its upstream, an unused tag, a dated changelog section for the
  version, and that the version is not already on RubyGems. It reports and
  never tags, pushes, or publishes. An unreachable RubyGems is reported as
  unknown rather than treated as "not published".
- Raise `PaperTrailDiff::UnversionedAssociationError` when a selected
  association's target is not versioned and history is being reconstructed.
  Such a comparison could only ever answer "nothing changed", which is a wrong
  answer rather than an empty one. Live-to-live comparison reads current state
  and is unaffected. `diagnose` now reports the same condition as an error
  rather than a warning, so `ok?` no longer stays true for a comparison that
  will raise.
- Document ActiveStorage attachments, which this reaches through:
  `has_one_attached` points at models Rails owns and PaperTrail never versions,
  so attachments are audited through a versioned model of your own that mirrors
  the metadata onto ordinary columns.

## [0.9.0] - 2026-08-14

### Added

- Report versions that share a timestamp, which hides any association change
  between them: PT-AT records membership per version but resolves it by
  timestamp, so such a pair is indistinguishable even when sequential ids order
  it correctly. `diagnose` reports `:tied_version_timestamps` as a warning when
  `associations:` are selected, and a comparison in that state emits
  `ambiguous_association_boundary.paper_trail_diff`. It warns rather than
  raising because the result may be perfectly correct — if nothing associated
  changed, nothing was lost — and the gem cannot distinguish the cases, since
  not seeing the change is the symptom.

### Changed

- Link the demo application from the README now that it is public.

## [0.8.0] - 2026-08-12

### Added

- Accept `snapshots: true` on `activity_timeline` and `analyze(activity: true)`,
  retaining the reconstructed states each step was compared between as
  `ActivityStep#from_snapshot` and `#to_snapshot`. A diff names what changed; a
  renderer that has to name an unchanged field of a changed record needed the
  whole state and had no way to reach it, so consumers were rebuilding it from
  the version table by hand — slower, and easy to get wrong in ways that stay
  quiet. The gem already builds these states to compute each diff and discarded
  them, so the option costs no extra queries. Off by default because each one
  holds the whole selected graph.
- Add `examples/demo.rb`, a self-contained tour that needs no application: it
  builds an in-memory database, writes a small multi-author history, and prints
  an endpoint diff, a checkpoint timeline, per-person attribution across a
  nested record, and one person's changes alone. It runs standalone, inside a
  project, or under `bundle exec`, fetching what it needs on first run.

- Raise `PaperTrailDiff::AmbiguousVersionOrderError` when versions sharing a
  timestamp have ids that cannot order them. Ordering falls back to the id when
  timestamps tie, which recovers the real sequence only while ids increase with
  insertion; a UUID version id does not, and a MySQL `datetime` column stores
  whole seconds, so the two together are ordinary rather than exotic. The gem
  previously returned a plausible-looking timeline with steps in the wrong
  order and others dropped. `diagnose` reports the same condition as an error
  so it can be caught before a run rather than after a wrong answer.
- Document the model and schema shapes the suite covers: single-table
  inheritance (results are keyed by the base class, so build keys with
  `Endpoint.identity`), non-integer primary keys, and a custom version class
  via `has_paper_trail versions: { class_name: }`.

### Changed

- Create the models it uses in the quickstart. It declared `has_paper_trail` on
  an `Article` and then used `Comment` without ever generating either, so
  following it in a new application failed on a missing table at the first
  console step.
- Run `diagnose`'s version-order check whether or not `associations:` are
  selected, so a report never answers `ok?` having inspected nothing. Document
  that `ok?` means no errors among the checks that ran.

### Fixed

- Cover `Analysis#to_h(snapshots: true)` with specs. It was shipped in 0.6.0
  with no test at all.

## [0.7.1] - 2026-08-11

### Fixed

- Load each current endpoint once per call instead of once per request for it,
  so `close_on: :current` no longer costs a live read per root and
  `analyze_many` keeps the flat query cost it exists for. A twenty-root batch
  closing on current state issued 43 queries against the 3 a closed window
  needs. Every root in one result now also reflects the same instant rather
  than whenever its turn came.

### Changed

- Name the way out in `IncompleteTimeRangeError`: the message now points at
  `close_on: :current` and at narrowing the window. Its previous advice — add a
  checkpoint after the window — cannot be followed by a report about the
  present, which is the case that raises it most.
- Correct the `reload_live_endpoints:` documentation, which claimed `timeline`
  and `analyze` never read live state. They do under `close_on: :current`, and
  they do not accept the option.

## [0.7.0] - 2026-08-11

### Added

- Accept `close_on: :current` on `timeline`, `activity_timeline`, `analyze`, and
  `analyze_many`, closing a wall-clock window on the live record when no later
  root version can reveal its final mutation. A window ending at the present
  otherwise raises `IncompleteTimeRangeError`, since a version records the state
  before its own event and nothing follows the last one. The closing step's
  `to_boundary.kind` is `:current` and its `to_version` is `nil`; `Step#to_h`
  now carries `to_boundary` so a serialized step still names its endpoint. Only
  valid alongside `within:`, because an explicit `from:`/`to:` range already
  says where it ends. Under `activity: true` the window runs to the instant
  state is captured rather than to the last root version, so a descendant that
  moved after that version is reported rather than dropped. A destroyed root has
  no current state to close on and keeps closing on its own destruction.

### Changed

- Document that `version_scope:` selects root versions only, and that "what did
  this person change?" is answered by an activity timeline filtered on
  `step.from_boundary.whodunnit` instead. A step's diff is exactly what the
  event at that boundary did, so the predicate covers descendant edits, which a
  root-version filter cannot see at all. Filtering in Ruby rather than selecting
  fewer versions is also what keeps the attribution correct: every boundary has
  to be reconstructed, or the snapshot carried into the next step is a state the
  record had already moved past.

## [0.6.0] - 2026-08-11

### Added

- Accept `version_scope:` on `timeline`, `activity_timeline`, `analyze`, and
  `analyze_many`, narrowing which root versions count as selected mutations.
  Excluded versions are still loaded, because a version records the state before
  its own event and the one following a selected change is what reveals it;
  their own changes are never attributed to a selected mutation. Each selected
  mutation is bounded by the version that immediately followed it rather than by
  the next selected one, so its diff is exactly what that mutation did however
  many excluded changes follow it. A selected mutation nothing follows yet is
  not reported, since no version records the state it produced; a selected
  destruction is the exception, because the absence it leaves is what it
  produced and `activity_timeline` closes on it. A root left with
  no selected mutation reports an empty `Analysis`. Under `activity: true` the
  filter decides the span; `activity_timeline` still lists every boundary inside
  it, because dropping one would fold its change into a neighbouring step.
- Expose `from_snapshot` and `to_snapshot` on `Analysis`, the reconstructed
  states its diff was taken between, so a report can render unchanged columns
  without selecting versions or reifying them itself. `Analysis#to_h` keeps its
  shape by default and takes `snapshots: true` to include them, because they
  carry the whole selected graph whether or not anything changed.

## [0.5.0] - 2026-08-11

### Added

- Add `analyze_many`, which analyzes many roots over one shared `within:` window,
  or over each root's whole history when the window is omitted, selecting their
  versions and preparing their history once for the batch. Query cost is flat in
  the number of roots for the endpoint diff and checkpoint timeline; descendant
  event discovery under `activity: true` remains per-root. A root with no
  versions in range returns an empty `Analysis`, and roots are supplied as live
  records so a root deleted inside the window cannot be included.
- Accept `:first` and `:last` as `compare_many` endpoints, resolved against the
  record the pair's other endpoint names, in two queries per model class rather
  than one lookup per root. A root with no recorded history compares as an empty
  `Diff`, and an unanchored `{ from: :first, to: :last }` raises.
- Accept `reload_live_endpoints:` on `activity_timeline`, which reads live state
  whenever `to:` is a current record but previously had no way to reuse an
  already-preloaded graph. `timeline` and `analyze` are bounded by versions and
  never read live state, so the option is deliberately absent there.

## [0.4.0] - 2026-08-11

### Added

- Close an activity timeline that ends at the root's own `destroy` version with
  a step into a new `kind: :destroyed` boundary, reporting the record's removal
  as a `record_presence_change` to `nil`. `ActivityBoundary` gains a
  `destroyed?` predicate, so consumers branching only on `version?` should
  handle the third kind. `compare`, `timeline`, and `analyze`'s endpoint diff
  are unchanged.
- Accept a `within:` window whose last selected mutation is the root's own
  destruction, which no later root version can follow, instead of raising
  `IncompleteTimeRangeError` for a range that could never be satisfied. A
  destruction outside the window remains reconstruction context only.
- Accept `:first` and `:last` as `from:` and `to:` boundaries on `timeline`,
  `activity_timeline`, and `analyze`, resolved without depending on the order
  the `versions` association happens to use. A record with no versions resolves
  to an empty timeline rather than raising, so listing pages need no special
  case.

### Removed

- Reject two version endpoints given in reverse chronological order with the
  new `PaperTrailDiff::ReversedEndpointsError`, in `compare` and
  `compare_many`. A transposed pair silently produced the inverse diff, and a
  result carries no direction that would reveal it. A current-record endpoint
  may still appear on either side.

### Fixed

- Rebuild prepared scalar state with direct attribute writes so a model that
  overrides an attribute writer reconstructs the state PaperTrail recorded
  instead of reapplying the override.

### Changed

- Order collection `added`, `removed`, and `changed` results naturally within
  one id type instead of by the printed form, so numeric ids sort `2` before
  `10`. Ordering remains deterministic and total for mixed id types.
- Resolve a boundary's prepared record state by chronological search and an
  indexed boundary transaction instead of scanning a record's versions, so
  timelines over long single-record histories stay linear in their step count.
- Bound prepared scalar history at the selected range plus one trailing version
  per identity, instead of every version recorded between the range and the
  present, so a short range early in a long history no longer pays for the
  history after it.
- Document that `timeline` and `analyze(activity: true)` produce the same
  root-checkpoint steps through different reconstruction strategies, and when
  each one is cheaper.
- Borrow a connection through `with_connection` where Active Record provides
  it, so applications that opt into deprecating permanent checkouts no longer
  see a deprecation warning from association candidate selection.
- Identify carried-forward collection snapshots and per-pass reification by
  an owned serial and by record identity, rather than by `object_id`, which
  Ruby only guarantees to be unique among live objects.
- Retain activity-event routes for every event type a timeline visits, rather
  than only the most recent one, so interleaved descendant types stop
  rediscovering the same routes.
- Resolve excluded attributes once per model class and selected path, and key
  historical child identities instead of rescanning them.

## [0.3.1] - 2026-08-10

### Fixed

- Preserve immutable activity snapshots for nested events that do not match a
  selected child record, instead of reporting a false change.

### Changed

- Split activity-event reconstruction, route discovery, relationship matching,
  collection mutation, and `belongs_to` target application into focused
  internal collaborators without changing result shapes.
- Reuse immutable activity-event routes and cached branch components across
  repeated event types to reduce timeline allocation overhead.

## [0.3.0] - 2026-08-10

### Added

- Add `within:` time-range selection to checkpoint timelines, activity
  timelines, and combined analysis, with inclusive/exclusive end handling and
  explicit errors when a final mutation cannot be reconstructed.
- Add `compare_many` for collection reports, with batched current-root loading,
  bounded live-association preloading, cross-root prepared history, immutable
  identity-keyed results, and scale-invariant query regression coverage.
- Add opt-in reuse of fully preloaded current endpoints and namespaced
  ActiveSupport runtime instrumentation without automatic logging, including
  end-to-end activity-timeline duration and step counts.

### Changed

- Teach timeline filtering through the shared `Step#empty?` protocol in the
  README and quickstart examples.
- Reuse the live graph loaded by `compare_many` while preparing historical
  association state, and defer root version loading until an edge needs it.
- Reuse collection identity positions and adjacent transition hints so activity
  steps compare only the changed member, and resolve direct nested collection
  owners by foreign key instead of scanning every parent snapshot.
- Reuse prepared predecessor and successor scalar states for isolated activity
  updates instead of reifying and deserializing each PaperTrail event again.
- Preserve both sides of nested collection membership moves by using the
  general comparator when one event changes multiple parent snapshots.
- Preserve per-owner `limit`, `offset`, and owner-dependent association scopes
  in `compare_many` while retaining batched preloading for safe branches.
- Replace lifetime association-identity materialization with an indexed start-state
  checkpoint plus post-boundary activity and current members.
- Bound historical activity-child candidates at the selected end so membership
  changes after the range cannot introduce unrelated empty timeline steps.
- Decode compatible prepared scalar version payloads without constructing an
  intermediate Active Record object, with reification fallback for unsafe schemas.
- Reuse internally owned frozen collection arrays instead of defensively copying
  them a second time during immutable activity reconstruction.
- Replace pre-existing versions-relation ordering when selecting a time range's
  immediate trailing reconstruction boundary.
- Limit automatic CI to pull requests and `main` pushes, and cancel superseded
  runs for the same pull request or ref.

### Fixed

- Supply TZInfo's timezone database to the test bundle so zoned-time coverage
  runs on Windows as well as systems with a native zoneinfo database.

## [0.2.0] - 2026-08-09

### Added

- Add deterministic `Diff#each_entry` and `Diff#each_change` traversal with
  immutable `TraversalEntry` values for renderers, counters, exports, and
  notifications.
- Add immutable version metadata and record references to activity boundaries.
- Give checkpoint `Step` objects `from_boundary` and `to_boundary` readers and
  give both timeline step types an `empty?` predicate.
- Add a Rails-focused quickstart with minimal endpoint, timeline, ignore, and
  association examples.
- Execute selected README and quickstart examples in isolated core and PT-AT
  test sessions so documented behavior cannot silently drift.

## [0.1.0] - 2026-08-09

### Added

- Add explicit, bounded nested association paths such as
  `comments.replies.author`.
- Add nested association changes to stable-record diffs and selected subtrees
  to added/removed record snapshots.
- Add path-aware ignore rules while preserving the existing global array form.
- Add root and nested `has_and_belongs_to_many` collection diffs, including
  historical membership, target updates, timelines, and bounded cyclic paths.
- Reload the configured PaperTrail versions association before resolving
  timeline boundaries.
- Rename the root `Diff#record` lifecycle field to the more explicit
  `Diff#record_presence_change`, including its `to_h` key.
- Add `activity_timeline` for adjacent root and selected-descendant version
  boundaries while preserving the root-only semantics of `timeline`.
- Add one-pass `analyze`, bounded association discovery, and structured history
  diagnostics.
- Bound version loads to the requested time range, stream timeline construction,
  and reuse immutable snapshot subtrees across adjacent boundaries.
- Apply event-local snapshot deltas for direct `has_many` membership changes at
  any selected depth and selected non-polymorphic `belongs_to` target events,
  with safe reconstruction fallbacks for other association shapes.
- Reconstruct post-create/update records from PaperTrail's serialized change
  pairs to avoid per-event successor and live-record lookups.
- Derive combined endpoint, root-timeline, and activity results from one
  snapshot pass; advance isolated root changes in place and selectively refresh
  only ambiguous association branches.
- Add `RecordReference`, consistent configuration error subclasses, traversal
  foreign-key suppression, and fail-loud HABTM endpoint validation.
- Fix selective `has_many :through` reconstruction by reifying the hidden
  through collection before resolving target records.
- Prepare timeline record states and association membership once per requested
  range, using indexed resolution for direct relationships, belongs-to-source
  through collections, and transaction-backed HABTM membership.
- Retain point-in-time PT-AT reconstruction as a per-reflection fallback for
  scoped, unversioned, composite-key, and unsupported through shapes.
- Keep multiple selected descendant events in one transaction atomic instead
  of applying an individual event delta before the transaction boundary.
