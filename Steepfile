# frozen_string_literal: true

target :lib do
  signature 'sig/generated'
  check 'lib'
  check 'typecheck'

  # Reading inside a column that stores JSON needs the stdlib signatures for it.
  library 'json'
  # A temporary table's name (see CandidateTable).
  library 'securerandom'
  # The day a string names (see TimeRange#parse).
  library 'date'
  # A datetime filter value's text in a local-time database (see DatabaseTime).
  library 'time'
end
