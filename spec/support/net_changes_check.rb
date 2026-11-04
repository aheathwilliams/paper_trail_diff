# frozen_string_literal: true

# With every change row kept, a timeline's net changes must be its own
# states (see PaperTrailDiff::NetChanges). Each record a row is about has, as
# `before`, its state where the step of its first row starts and, as `after`,
# its state where the timeline ends, and is listed exactly when the two
# differ. The root comes first whenever anything is listed, unchanged when it
# has no row of its own. Records are read here from the whole snapshot tree,
# apart from how the gem finds them.
#
# This holds for a timeline that reports every step between its ends: one a
# version filter thins out skips changes its rows never show.
module NetChangesCheck
  ROOT = [[], nil, nil].freeze

  module_function

  # Adds a failure unless the timeline's net changes hold.
  def check(failures, label, steps)
    problem = mismatch(steps)
    failures.add("#{label} net changes", problem) if problem
  end

  # nil when the net changes hold, else what was expected and shown.
  def mismatch(steps)
    listed = PaperTrailDiff::NetChanges.call(steps, nil)
    expected = expected_states(steps)
    shown = listed.to_h { |change| [key(change), states(change.before, change.after)] }
    return if shown.except(ROOT) == expected.except(ROOT) && root_first?(listed, expected, shown)

    { expected: expected, shown: shown }
  end

  # Each record a row is about, with its state where its first row's step
  # starts and where the timeline ends, when the two differ.
  def expected_states(steps)
    first = {}
    steps.each_with_index do |step, index|
      step.change_rows.each { |row| first[key(row)] ||= index }
    end
    first.filter_map do |key, index|
      before = find(steps.fetch(index).from_snapshot, key)
      pair = states(before, find(steps.last.to_snapshot, key))
      [key, pair] unless pair.first == pair.last
    end.to_h
  end

  # Without a row that changed it, the root is listed unchanged.
  def root_first?(listed, expected, shown)
    return listed.empty? if expected.empty?

    root = listed.first
    root.root? && (expected.key?(ROOT) ? shown[ROOT] == expected[ROOT] : root.diff.empty?)
  end

  def states(before, after)
    [before&.attributes, after&.attributes]
  end

  # The record a key names in a snapshot, under any record along its path.
  def find(snapshot, (path, type, id))
    return snapshot unless type

    held(snapshot, path).find { |record| record.type == type && record.id == id }
  end

  def held(snapshot, path)
    path.reduce([snapshot].compact) do |level, name|
      level.flat_map { |record| record.associations[name]&.records || [] }
    end
  end

  def key(item)
    record = item.record
    [item.association_path, record&.type, record&.id]
  end
end
