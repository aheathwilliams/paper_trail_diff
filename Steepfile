# frozen_string_literal: true

target :lib do
  signature 'sig/generated'
  check 'lib'
  check 'typecheck'

  # Reading inside a column that stores JSON needs the stdlib signatures for it.
  library 'json'
end
