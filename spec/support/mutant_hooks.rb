# frozen_string_literal: true

# Mutant runs each mutation's specs in forked worker processes. ActiveRecord
# drops its connections after a fork, and reconnecting to an in-memory SQLite
# database opens a new, empty one with none of the fixture tables. So under
# mutant the specs use a SQLite file (see mutant.yml), and each worker works on
# its own copy of it, made after the spec files have created the tables.
#
# Mutant evaluates this file with `hooks` bound to its hook builder.
require 'fileutils'

database_directory = File.expand_path('../../tmp/mutant', __dir__)

hooks.register(:setup_integration_pre) do
  FileUtils.rm_rf(database_directory)
  FileUtils.mkdir_p(database_directory)
end

worker_database = lambda do |index:|
  copy = File.join(database_directory, "worker-#{index}.sqlite3")
  FileUtils.rm_f(copy)
  # VACUUM INTO writes a consistent copy even while the source uses a WAL.
  ActiveRecord::Base.connection.execute("VACUUM INTO '#{copy}'")
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: copy)
end

hooks.register(:mutation_worker_process_start, &worker_database)
hooks.register(:test_worker_process_start, &worker_database)
