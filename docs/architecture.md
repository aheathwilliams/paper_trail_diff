# How results are built

[Back to the API reference](reference.md). This page explains how the gem
rebuilds history and what that costs. You do not need it to use the gem.

## Two ways to rebuild a timeline

`analyze` returns the same root-record steps for the same range with
`activity: true` or without, except where a transaction crosses a window's
edge: without it, each root version is reported where it was saved, and with
it, activity on associations reports a transaction in the window it ends in. They build them differently:

- Without `activity:`, `analyze` rebuilds the root record and every chosen association separately
  at each root version. Its cost grows with *root versions × size of the chosen
  associations*. It does not depend on how often the associations changed.
- `analyze(activity: true)` rebuilds the state once, then applies each recorded
  event in order. Its cost grows with *one rebuild + number of events*. It does
  not depend on how large the chosen associations are.

Neither is always faster. Choose by the output you need. If performance matters,
measure on real history with the [instrumentation events](reference.md#instrumentation).
As a rough guide, `analyze(activity: true)` suits wide associations with modest
activity, and `analyze` without it suits a few root versions with many child events
between them.

## Loading history

Single-record and batch methods load the history they need up front, walking
only the association paths you request:

1. The root record's versions in the range, plus one version after it, which
   holds the state the range's last change produced. When there is no later
   version, the current record is used instead.
2. For each requested association, the IDs of records that belonged to it at
   the start of the range or joined it later, found through PT-AT's
   `version_associations` table and the current rows.
3. Those records' versions in the range, plus one version after it.

From that, the gem builds each state without querying again. Plain recorded
attributes are read straight from the stored version, without creating a model
instance, including the members of a `has_many :through` and the target of a
polymorphic `belongs_to`. Models with initialization callbacks, custom
attribute types or defaults, default scopes that assign attributes, or
encrypted attributes are rebuilt with PaperTrail's `reify` instead, so their
behavior is kept.

An association scope or a target's default scope is read once into a
`ScopeCondition`: the `where` conditions of the relation it builds, kept only
when each is an equality, `IN`, or `nil` test, or a negation of one, on the
target's own column of a type Ruby compares as the database does. A record
belongs to the association at a point when its key matches and its state
there meets the condition. A `limit`, `offset`, or `has_one` order is read
into a `ScopeRanking` when its order is total and every key compares in Ruby
as the database sorts it, including where each adapter puts NULL; the records
that meet the condition are then sorted, offset, and limited as the
association's query would. A `has_many :through` reads its parts' conditions
only, at any depth, as its query joins them, and ranks by its own order the
rows the join yields, a record reached twice counting twice. Activity reads a scoped branch again at each event
on it rather than patching the previous snapshot, since any edit can move a
record into or out of the scope, and with a ranking, move another record too.

Each rebuilt state is an immutable snapshot. Activity timelines carry the
previous snapshot forward and replace only the parts an event changed, so an
edit to one comment does not copy the whole article again. Events in one
PT-AT transaction are applied together.

A transaction takes effect where it saved its last version, of any record.
`RecordedTransactionEnds` reads that version from the version table, for all
the versions a history holds at once, since which of a transaction's records
a timeline holds depends on where it is read from. `TransactionEnds` places
every version of a transaction at that last one, and a timeline replays its events in that order, so two
transactions that interleaved their versions in one tree are read one after
the other, in the order they ended. The record index reads a record at a
boundary as it stood before every transaction that ends at or after the
boundary's own. A transaction thus changes no snapshot while it is open, and
a change is reported with its own transaction's, under its own version. A
snapshot read for a timeline whose transactions interleaved is cached apart
from one read without.

A window reports the transactions that end inside it. Its history is first
read over the window itself. `CrossingTransactions` then says how far back
its transactions reach: where the earliest transaction open at its start
began, whatever records it saved. When one was open, the root's versions and
the history are read once more from there, the whole of it is replayed, and
the steps of the transactions that end inside the window are reported. A
window is not read past its end. A transaction that saves inside it and ends
later is left to the later window.

A range of versions, and a whole history read without a window, is read the
same way. It starts before its first version's transaction
(`TransactionCut.range_start`), and its history is read from where a
transaction open there began (`TransactionCut.crossing_start`): what another
transaction saved before the start is part of the starting state if that
transaction ended first, and is reported in its own step if it ended later.
It ends where its last version's transaction takes effect
(`TransactionCut.range_end`), so what another transaction committed before
then is read, and the steps of transactions that end after it are left out.
`compare` reads each version the same way, so one version reads alike as the
end of one range, the start of the next, and an endpoint of `compare`. A
destroyed root's tree is read up to where its destruction takes effect, and
nothing saved there by a transaction that ended later is the root's. Without
associations no other record is read, so each of the record's versions takes
effect where it was saved: row locks keep two transactions from interleaving
one record's versions.

## What history cannot read

Every association is read from the loaded history, or not at all. These
shapes are refused, since who was in one at a past point cannot be told from
stored versions:

- associations with a scope the gem cannot read as plain conditions and an
  exact ranking, including owner-dependent scopes and a `limit` without a
  total integer order;
- targets with such a default scope. A polymorphic `belongs_to` names its
  target's class only in each record, so one that points at such a class is
  refused when that record is read;
- composite foreign keys.

See [association scopes](reference.md#association-scopes).

A `has_and_belongs_to_many` is refused before any history is read: its join
rows have no versions. The reference shows how to
[replace one](reference.md#replacing-a-has_and_belongs_to_many) with a
`has_many :through` a versioned join model.

## Database indexes

For large histories, add two indexes to each version table, one for each way
the gem reads versions:

```ruby
add_index :versions, %i[item_type item_id created_at id],
          name: "index_versions_on_item_and_timeline"
add_index :versions, %i[item_type created_at item_id],
          name: "index_versions_on_type_and_time"
```

The first serves reading one record's history: it filters by `item_type` and
`item_id`, then by time, in time and ID order. It covers PaperTrail's own
`(item_type, item_id)` index, which you can then drop.

The second serves finding which records changed in a window, as `report`,
`analyze_scope`, and the other batch methods do with `since:` or `within:`.
They filter by `item_type` and `created_at` alone, which the first index cannot
narrow, so without the second the database reads every version of the model.
On PostgreSQL with 5 million article versions, a report on five articles
changed in the last hour took about 230 ms without it and 2 ms with it.
Ending the index with `item_id` lets the database answer from the index alone,
and SQLite, which keeps no table statistics unless you run `ANALYZE`, picks it
only then.

Keep PT-AT's own index on `version_associations` (`foreign_key_name`,
`foreign_key_id`, `foreign_type`).

## Remaining costs

- An activity timeline produces one step per event, so a very busy range is
  large no matter how it is built. Bound or paginate wide ranges in requests
  that must respond quickly.
- Repeated events in one very wide collection still copy that collection's
  list of records for each step. The comparison work stays small, but memory
  traffic grows with *events × collection size*.
- A read with associations asks its version table where each transaction
  it holds ends, and a `within:` or `since:` window asks which transactions
  were open at its start (see [time windows](reference.md#time-windows)).
  The first takes one statement per 500 transactions; the second reads the
  versions saved since the window began, which no index of the README
  serves. See [performance](performance.md#what-still-grows) for the cost on
  a large table.
