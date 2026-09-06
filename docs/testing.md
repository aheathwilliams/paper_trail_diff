# Testing

The default suite uses an in-memory SQLite database:

```console
mise exec -- bundle install
mise exec -- bundle exec rake
```

CI keeps the Ruby 3.1–4.0 and PaperTrail 16/17 compatibility matrix on SQLite,
including Windows runs. Separate Linux jobs run both core and association suites
on PostgreSQL 17, MySQL 8.4, and SQL Server 2022 with Ruby 4.0 and PaperTrail 17.
The SQL jobs exercise the same regressions, including joined-column ordering,
duplicate roots, pagination, and historical association reconstruction.

## Other databases locally

Install the adapter's client development libraries first. On Debian/Ubuntu,
the packages are `libpq-dev` for PostgreSQL, `default-libmysqlclient-dev` for
MySQL, and `freetds-dev` for SQL Server. The optional development group includes
all three adapters:

```console
BUNDLE_WITH=database_adapters mise exec -- bundle install
```

Create a dedicated disposable database named `paper_trail_diff_test`. The suites
recreate their fixture tables. Set `PAPER_TRAIL_DIFF_DATABASE_URL` to its
connection URL and run both suites:

```console
BUNDLE_WITH=database_adapters PAPER_TRAIL_DIFF_DATABASE_URL=postgresql://paper_trail_diff:test@127.0.0.1:5432/paper_trail_diff_test mise exec -- bundle exec rake spec
BUNDLE_WITH=database_adapters PAPER_TRAIL_DIFF_DATABASE_URL=mysql2://paper_trail_diff:test@127.0.0.1:3306/paper_trail_diff_test mise exec -- bundle exec rake spec
BUNDLE_WITH=database_adapters PAPER_TRAIL_DIFF_DATABASE_URL=sqlserver://sa:PaperTrail_Test2026@127.0.0.1:1433/paper_trail_diff_test mise exec -- bundle exec rake spec
```

These credentials are examples for disposable local instances. SQL Server's
adapter version follows ActiveRecord's version; Bundler selects a compatible
adapter. No database driver is a runtime dependency of the gem.

SQL Server's adapter wraps datetime2 values during serialization. With
PaperTrail's default YAML serializer, the fixtures explicitly permit
`ActiveRecord::ConnectionAdapters::SQLServer::Type::Data` and
`ActiveRecord::ConnectionAdapters::SQLServer::Type::DateTime2`, in addition to
`Symbol` and `Time`. Applications using that serializer need the corresponding
`ActiveRecord.yaml_column_permitted_classes` configuration. The gem does not
change an application's YAML configuration.

The CI service configuration is in `.github/workflows/ci.yml`. PostgreSQL and
MySQL create the named database during container initialization. The SQL Server
job creates it explicitly after the service passes its health check.

## Generated signatures

Inline RBS comments in `lib/` are the source of truth:

```console
mise exec -- bundle exec rake rbs
mise exec -- bundle exec rake typecheck
```

The typecheck task regenerates signatures and compares them with Git's index
before running Steep. Unstaged generated changes therefore fail the gate even
when they are correct. Review and stage matching source/signature changes before
running the complete gate. The Steep wrapper also fails on internal errors even
if Steep returns exit status zero.
