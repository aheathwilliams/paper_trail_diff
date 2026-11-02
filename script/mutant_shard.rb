# frozen_string_literal: true

require 'open3'

# Splits a mutation run across parallel CI jobs. Mutant lists the subjects in
# scope, one method each, and each job mutates every `total`th of them. Methods
# cost about the same to mutate, while one class can hold most of a run's
# methods, so the split is by method rather than by the classes mutant.yml
# names. With a base revision, only the methods changed since it are in scope.
module MutantShard
  module_function

  def call(index, total, base = nil)
    subjects = select(subjects(base), index, total)
    if subjects.empty?
      # Without subjects, mutant would mutate everything mutant.yml names.
      puts('No subjects in this shard.')
      return true
    end

    system('bundle', 'exec', 'mutant', 'run', *since(base), *subjects)
  end

  def subjects(base)
    stdout, status = Open3.capture2('bundle', 'exec', 'mutant', 'environment', 'subject', 'list',
                                    *since(base))
    abort('Listing mutation subjects failed.') unless status.success?
    stdout.lines.map(&:strip).grep(/\A[A-Z]\w*(?:::\w+)*[#.]\S+\z/)
  end

  def select(subjects, index, total)
    subjects.select.with_index { |_, position| position % total == index }
  end

  def since(base)
    base ? ['--since', base] : []
  end
end

if $PROGRAM_NAME == __FILE__
  index, total, base = ARGV
  exit(MutantShard.call(Integer(index), Integer(total), base) ? 0 : 1)
end
