# frozen_string_literal: true

require_relative '../support/snapshot_world'

# Properties of the fold from change rows to net changes, checked over
# generated histories (SnapshotCases::World) rather than chosen ones. Each
# step's rows name its own version, as spec/unit/net_changes_spec.rb builds
# them.
RSpec.describe 'Net change properties' do
  def version(id, author)
    PaperTrailDiff::ActivityBoundary.new(
      kind: :version, version_id: id, item_type: 'Article', item_id: 1,
      recorded_at: Time.utc(2026) + id, event: 'update', whodunnit: author
    )
  end

  # A step for each move from one state to the next, made by version i + 1.
  def steps_between(states, random)
    closing = version(999, nil)
    authors = %w[alice bob]
    states.each_cons(2).with_index.map do |(from, to), index|
      author = authors.sample(random: random)
      PaperTrailDiff::ActivityStep.between(from_boundary: version(index + 1, author),
                                           to_boundary: closing, from_snapshot: from,
                                           to_snapshot: to, retain: true)
    end
  end

  def each_history
    SnapshotCases.each do |random, size, label|
      states = SnapshotCases::World.new(random, size).history(3 + (3 * size))
      yield states, steps_between(states, random), random, label
    end
  end

  def key(change)
    [change.association_path, change.record&.type, change.record&.id]
  end

  # The records whose net change changes them, as their fields before and
  # after, as SnapshotCases::World.changes lists them.
  def table(changes)
    changes.reject { |change| change.diff.empty? }.to_h do |change|
      [key(change), [change.before&.attributes&.compact, change.after&.attributes&.compact]]
    end
  end

  # Each record a step moves in or out, as its fields where its first move
  # found it and where its moves left it, when they differ: there if the last
  # move's step closes with it there, with the fields it last came in with.
  # A record that leaves one holder for another, or one of two, is moved but
  # does not come in.
  def moved_records(states, steps)
    found = {}
    steps.each_with_index do |step, index|
      step.change_rows.reject(&:attribute).group_by { |row| row_key(row) }.each do |key, rows|
        move(found, key, rows, states.fetch(index), states.fetch(index + 1))
      end
    end
    found.filter_map { |key, entry| moved(key, entry) }.to_h
  end

  def moved(key, entry)
    after = entry[:fields] if entry[:present]
    [key, [entry[:before], after]] unless entry[:before] == after
  end

  # One step's moves of a record, from the state the step opens with to the
  # one it closes with.
  def move(found, key, rows, opening, closing)
    before = SnapshotCases::World.records(opening)[key]
    entry = found[key] ||= { before: before, fields: before }
    after = SnapshotCases::World.records(closing)[key]
    entry[:fields] = after if rows.any? { |row| row.change == :added }
    entry[:present] = !after.nil?
  end

  def row_key(row)
    [row.association_path, row.record&.type, row.record&.id]
  end

  # The rows of a random half of the versions.
  def some_versions(steps, random)
    kept = steps.map { |step| step.source_boundary.version_id }.select { random.rand < 0.5 }
    ->(row) { kept.include?(row.source.version_id) }
  end

  describe 'properties' do
    # Whether the run is passed alone or picked out of the whole history by
    # the rows kept, its rows lead from its first state to its last.
    it "folds a run of steps into each record's change from the run's first state to its last" do
      each_history do |states, steps, random, label|
        first, last = Array.new(2) { random.rand(0..steps.length) }.sort
        expected = SnapshotCases::World.changes(states.fetch(first), states.fetch(last))
        alone = PaperTrailDiff::NetChanges.call(steps[first...last], nil)
        in_run = ->(row) { row.source.version_id.between?(first + 1, last) }
        picked = PaperTrailDiff::NetChanges.call(steps, in_run)
        message = lambda do
          "#{label}\nsteps #{first}...#{last}\nexpected: #{expected}\nnet: #{table(alone)}"
        end

        expect(table(alone)).to eq(expected), message
        expect(table(picked)).to eq(expected), message
      end
    end

    it 'lists the root first, then each record by its first kept change, each source once' do
      each_history do |_states, steps, random, label|
        changes = PaperTrailDiff::NetChanges.call(steps, some_versions(steps, random))
        next if changes.empty?

        firsts = changes.drop(1).map { |change| change.sources.first.version_id }
        expect(changes.map(&:root?)).to eq([true, *Array.new(changes.length - 1, false)]), label
        expect(firsts).to eq(firsts.sort), label
        expect(changes.map { |change| change.sources.map(&:version_id) })
          .to all(satisfy { |ids| ids == ids.uniq.sort }), label
      end
    end

    # A record that comes in takes the fields it came with, whatever rows of
    # its fields were dropped, so kept alone, the rows that move records in
    # and out leave each as its last move found it.
    it 'leaves a record kept only by its moves as its last move left it' do
      each_history do |states, steps, _random, label|
        changes = PaperTrailDiff::NetChanges.call(steps, ->(row) { row.attribute.nil? })

        expect(table(changes)).to eq(moved_records(states, steps)), label
      end
    end

    # A record that came, went or came back takes its fields from where it
    # was found, so only one that stayed is held to its field rows alone.
    it 'makes only the kept changes' do
      each_history do |_states, steps, random, label|
        keep = some_versions(steps, random)
        rows = steps.flat_map(&:change_rows).select(&keep)
        PaperTrailDiff::NetChanges.call(steps, keep).each do |change|
          own = rows.select { |row| row_key(row) == key(change) }
          next if change.added? || change.removed? || own.any? { |row| row.attribute.nil? }

          expect(change.diff.attributes.keys - own.map(&:attribute)).to eq([]), label
        end
      end
    end
  end
end
