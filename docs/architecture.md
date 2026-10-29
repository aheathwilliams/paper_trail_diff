# How results are built

[Back to the API reference](reference.md). This page explains how the gem
rebuilds history and what that costs. You do not need it to use the gem.

## Two ways to rebuild a timeline

`timeline` and `analyze(activity: true)` return the same root-record steps for
the same range. They build them differently:

- `timeline` rebuilds the root record and every chosen association separately
  at each root version. Its cost grows with *root versions × size of the chosen
  associations*. It does not depend on how often the associations changed.
- `analyze(activity: true)` rebuilds the state once, then applies each recorded
  event in order. Its cost grows with *one rebuild + number of events*. It does
  not depend on how large the chosen associations are.

Neither is always faster. Choose by the output you need. If performance matters,
measure on real history with the [instrumentation events](reference.md#instrumentation).
As a rough guide, `analyze(activity: true)` suits wide associations with modest
activity, and `timeline` suits a few root versions with many child events
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

## When the gem falls back to PT-AT

These association shapes cannot be read from the loaded history. The gem asks
PT-AT to rebuild them at each point instead, which costs queries per record and
resolves association membership by timestamp only:

- associations with a scope the gem cannot read as plain conditions and an
  exact ranking, including owner-dependent scopes and a `limit` without a
  total integer order;
- targets with such a default scope;
- targets that are not versioned;
- composite foreign keys.

Batch methods reject the scoped cases unless you pass
`allow_expensive: true`; see [costly associations](reference.md#costly-associations).

HABTM membership comes from the snapshots PT-AT records with each transaction,
so it is only known at root versions saved in a transaction. Those snapshots
name the transaction and the association but not the owner, so they give only
the root's own membership, and a HABTM below the root is rejected before any
history is read. Even at the root, a transaction in which another record with a
HABTM of the same name saved a version holds both records' members;
`HabtmTransactionOwners` finds those transactions, and reading one raises.

## Database indexes

For large histories, add a composite index that matches how the gem reads
versions:

```ruby
add_index :versions, %i[item_type item_id created_at id],
          name: "index_versions_on_item_and_timeline"
```

It helps most with repeated `within:` queries, which filter by `item_type`,
`item_id`, and `created_at`, then order by time and ID. Keep PT-AT's own index
on `version_associations` (`foreign_key_name`, `foreign_key_id`,
`foreign_type`).

## Remaining costs

- An activity timeline produces one step per event, so a very busy range is
  large no matter how it is built. Bound or paginate wide ranges in requests
  that must respond quickly.
- Repeated events in one very wide collection still copy that collection's
  list of records for each step. The comparison work stays small, but memory
  traffic grows with *events × collection size*.
