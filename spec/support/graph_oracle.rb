# frozen_string_literal: true

require_relative 'oracle'

module Oracle
  # The state of each root under each set of paths, read with plain Active
  # Record by following the reflections. A record leaves out its primary key,
  # `updated_at`, the key (and type) a has_one or has_many child points back
  # with, and the keys of the belongs_to associations it is read through, as
  # snapshots do. A through reaches a record once per join row that leads to
  # it; it is one member.
  module GraphTruth
    module_function

    # Each root's state under each set of paths, and under `[id, paths,
    # :joins]` the join rows its throughs reached, which a snapshot does not
    # hold.
    def states(model, root_ids, path_sets)
      root_ids.product(path_sets).each_with_object({}) do |(id, paths), states|
        record = model.find_by(id: id)
        states[[id, paths]] = record && build(record, tree(paths), [])
        states[[id, paths, :joins]] = record ? joins(record, tree(paths)) : []
      end
    end

    # The join rows of every through in the tree, at any depth, as their
    # versions name them.
    def joins(record, tree)
      tree.flat_map do |name, subtree|
        reflection = record.class.reflect_on_association(name)
        rows = reflection.through_reflection? ? join_rows(record, reflection) : []
        members = Array(record.class.find(record.id).public_send(name))
        rows + members.flat_map { |member| joins(member, subtree) }
      end.uniq
    end

    def join_rows(record, reflection)
      through = reflection.through_reflection
      rows = Array(record.class.find(record.id).public_send(through.name))
      inner = through.through_reflection? ? join_rows(record, through) : []
      inner + rows.map { |row| [row.class.base_class.name, row.id.to_s] }
    end

    def build(record, tree, incoming)
      reflections = tree.keys.map { |name| record.class.reflect_on_association(name) }
      keys = reflections.select(&:belongs_to?).flat_map do |reflection|
        [reflection.foreign_key.to_s, *(reflection.foreign_type.to_s if reflection.polymorphic?)]
      end
      attributes = record.attributes.except(record.class.primary_key, 'updated_at', *incoming,
                                            *keys)
      associations = reflections.to_h do |reflection|
        [reflection.name.to_s, association(record, reflection, tree.fetch(reflection.name.to_s))]
      end
      PaperTrailDiff::RecordSnapshot.new(type: record.class.name, id: record.id,
                                         attributes: attributes, associations: associations)
    end

    def association(record, reflection, subtree)
      members = Array(record.class.find(record.id).public_send(reflection.name))
      members = members.uniq { |member| [member.class.name, member.id] }
      direct = !reflection.belongs_to? && !reflection.through_reflection?
      child_keys = direct ? [reflection.foreign_key.to_s, *reflection.type&.to_s] : []
      records = members.map { |member| build(member, subtree, child_keys) }
      PaperTrailDiff::AssociationSnapshot.new(kind: reflection.macro, records: records)
    end

    def tree(paths)
      paths.each_with_object({}) do |path, root|
        path.split('.').inject(root) { |branch, name| branch[name] ||= {} }
      end
    end

    # Every record in a snapshot's associations, at any depth, as its
    # versions name it: by base class and ID.
    def identities(snapshot)
      return [] unless snapshot

      snapshot.associations.each_value.flat_map do |association|
        association.records.flat_map do |record|
          [[record.type.constantize.base_class.name, record.id.to_s], *identities(record)]
        end
      end
    end
  end

  # What the graph checkers share: the roots, the state recorded for each
  # under its paths, and how a read is compared with it. The recorder's
  # snapshot is the GraphTruth states.
  module GraphStates
    GROUPS = [nil, :transaction].freeze

    def initialize(model, recorder, root_ids, path_sets, failures)
      @model = model
      @recorder = recorder
      @root_ids = root_ids
      @path_sets = path_sets
      @failures = failures
    end

    private

    def roots
      @model.where(id: @root_ids).order(:id).to_a
    end

    def versions(root)
      root.versions.reorder(:created_at, :id).to_a
    end

    def state(entry, root, paths)
      entry.snapshot&.fetch([root.id, paths], nil)
    end

    def diff(before, after)
      PaperTrailDiff::Engine.compare(before, after).to_h
    end

    # What separates a rebuilt snapshot from the recorded one, or nothing.
    def mismatch(expected, actual)
      change = PaperTrailDiff::Engine.compare(expected, actual)
      change.empty? ? {} : change.to_h
    end

    # Sources other than the root's own versions and those of records in its
    # tree, or joining a through in it, before or after the transaction that
    # wrote them.
    def strays(root, paths, step)
      step.sources.filter_map do |source|
        identity = [source.item_type, source.item_id.to_s]
        next if identity == [@model.base_class.name, root.id.to_s]
        next if @recorder.around(source.version_id).any? do |entry|
          held?(entry, root, paths, identity)
        end

        [*identity, source.version_id]
      end
    end

    def held?(entry, root, paths, identity)
      joins = entry.snapshot&.fetch([root.id, paths, :joins], nil) || []
      GraphTruth.identities(state(entry, root, paths)).include?(identity) ||
        joins.include?(identity)
    end

    def version_time(id)
      PaperTrail::Version.find(id).created_at
    end
  end

  # Compares every read of several roots' histories, under each set of paths,
  # with the states a Recorder kept.
  class GraphChecker
    include GraphStates

    def run(random)
      current
      roots.each do |root|
        @path_sets.each do |paths|
          endpoints(root, paths)
          timeline(root, paths)
          activity(root, paths, random)
        end
      end
      GraphWindowChecker.new(@model, @recorder, @root_ids, @path_sets, @failures).run(random)
    end

    # The truth itself must agree with the gem on the live rows, which it reads
    # without history; otherwise every other check would compare conventions.
    def current
      roots.each do |root|
        @path_sets.each do |paths|
          live = PaperTrailDiff.analyze(root, from: versions(root).first, to: root,
                                              associations: paths)
          @failures.check("current #{[root.id, paths].inspect}", {},
                          mismatch(state(@recorder.final, root, paths), live.to_snapshot))
        end
      end
    end

    # Each root version to the next one and to the current record.
    def endpoints(root, paths)
      list = versions(root)
      list.each_with_index do |from, index|
        [list[index + 1], root].compact.each { |to| endpoint(root, paths, from, to) }
      end
    end

    def timeline(root, paths)
      list = versions(root)
      steps = PaperTrailDiff.timeline(root, from: list.first, to: root, associations: paths)
      ends = [*list.drop(1).map { |version| @recorder.before(version.id) }, @recorder.final]
      label = "timeline #{[root.id, paths].inspect}"
      return @failures.add("#{label} step count", [steps.length, ends.length]) if
        steps.length != ends.length

      steps.zip(list, ends).each do |step, from, last|
        before = state(@recorder.before(from.id), root, paths)
        @failures.check("#{label} from #{from.id}", diff(before, state(last, root, paths)),
                        step.diff.to_h)
      end
    end

    # Activity from the first root version and from a later one, grouped and
    # not. A grouped step is one transaction's change; an ungrouped step in a
    # transaction that wrote several versions has no recorded state of its own.
    def activity(root, paths, random)
      list = versions(root)
      [list.first, list.drop(1).sample(random: random)].compact.uniq.each do |from|
        GROUPS.each do |group|
          steps = PaperTrailDiff.activity_timeline(root, from: from, to: root, associations: paths,
                                                         group: group, snapshots: true)
          label = "activity #{[root.id, paths].inspect} from #{from.id} group #{group.inspect}"
          if group
            @failures.check("#{label} changes", expected_changes(root, paths, from),
                            steps.reject(&:empty?).map { |step| step.diff.to_h })
          end
          steps.each_with_index do |step, index|
            step_states("#{label} step #{index}", root, paths, step, grouped: !group.nil?)
          end
        end
      end
    end

    private

    def endpoint(root, paths, from, to)
      current = to.is_a?(@model)
      label = "analyze #{[root.id, paths].inspect} #{from.id}->#{current ? 'current' : to.id}"
      before = state(@recorder.before(from.id), root, paths)
      after = state(current ? @recorder.final : @recorder.before(to.id), root, paths)
      analysis = PaperTrailDiff.analyze(root, from: from, to: to, associations: paths)
      @failures.check("#{label} from", {}, mismatch(before, analysis.from_snapshot))
      @failures.check("#{label} to", {}, mismatch(after, analysis.to_snapshot))
      @failures.check("#{label} diff", diff(before, after), analysis.diff.to_h)
      @failures.check("#{label} compare", diff(before, after),
                      PaperTrailDiff.compare(from, to, associations: paths).to_h)
    end

    # The change each transaction from the one that wrote `from` made, where
    # the paths can see it.
    def expected_changes(root, paths, from)
      first = @recorder.entries.index { |entry| entry.version_ids.include?(from.id) }
      @recorder.entries.each_cons(2).drop(first - 1).filter_map do |before, after|
        change = PaperTrailDiff::Engine.compare(state(before, root, paths),
                                                state(after, root, paths))
        change.to_h unless change.empty?
      end
    end

    def step_states(label, root, paths, step, grouped:)
      @failures.check("#{label} stray sources", [], strays(root, paths, step))
      @failures.check("#{label} diff", diff(step.from_snapshot, step.to_snapshot), step.diff.to_h)
      return if !grouped && shared?(step)

      before = state(@recorder.before(step.source_boundary.version_id), root, paths)
      after = state(@recorder.at(step.to_boundary), root, paths)
      @failures.check("#{label} from", {}, mismatch(before, step.from_snapshot))
      @failures.check("#{label} to", {}, mismatch(after, step.to_snapshot))
    end

    def shared?(step)
      shared = @recorder.shared_version_ids
      target = step.to_boundary
      shared.include?(step.source_boundary.version_id) ||
        (target.version? && shared.include?(target.version_id))
    end
  end

  # Windows between recorded transactions, through every method that takes
  # one, and windows that meet.
  class GraphWindowChecker
    include GraphStates

    def run(random)
      windows(random)
      splits(random)
    end

    # Windows between two recorded transactions.
    def windows(random, count: 4)
      entries = @recorder.entries
      count.times do
        first, last = (1...entries.length).to_a.sample(2, random: random).sort
        @path_sets.each { |paths| window(paths, entries.fetch(first), entries.fetch(last)) }
      end
    end

    # Two windows that meet between transactions, or inside one, read each
    # activity step exactly once, credited to the same transaction, as the
    # window spanning both does.
    def splits(random)
      pivots(random).each do |pivot|
        group = GROUPS.sample(random: random)
        roots.each { |root| @path_sets.each { |paths| split(root, paths, pivot, group) } }
      end
    end

    private

    # Where windows meet: at the start of a transaction or at a quiet moment
    # after one, and at versions inside transactions that wrote several.
    def pivots(random, count: 4)
      entries = @recorder.entries.reject { |entry| entry.version_ids.empty? }
      between = Array.new(count) do
        entry = entries.sample(random: random)
        random.rand < 0.5 ? version_time(entry.version_ids.min) : entry.after
      end
      inside = entries.flat_map { |entry| entry.version_ids.sort.drop(1) }.sample(2, random: random)
      between + inside.map { |id| version_time(id) }
    end

    def window(paths, first, last)
      within = first.after..last.after
      label = "#{paths.inspect} within #{first.after.iso8601(6)}..#{last.after.iso8601(6)}"
      options = { within: within, associations: paths, activity: true }
      many = PaperTrailDiff.analyze_many(roots, **options)
      scoped = PaperTrailDiff.analyze_scope(@model.where(id: @root_ids), **options, limit: 10)
      roots.each do |root|
        key = PaperTrailDiff::Endpoint.identity(root)
        expected = PaperTrailDiff::Engine.compare(state(first, root, paths),
                                                  state(last, root, paths))
        root_window("#{root.id} #{label}", root, paths, [first, last])
        @failures.check("analyze_many #{root.id} #{label}", expected.to_h,
                        many.fetch(key).diff.to_h)
        scoped_window("analyze_scope #{root.id} #{label}", expected, scoped.analyses[key])
      end
    end

    def scoped_window(label, expected, selected)
      return @failures.check(label, expected.to_h, selected.diff.to_h) if selected

      @failures.add("#{label} left out a changed root", expected.to_h) unless expected.empty?
    end

    # An analysis with nothing to report reads no state, so its snapshots are
    # nil; the window must then show no change.
    def root_window(label, root, paths, (first, last))
      analysis = PaperTrailDiff.analyze(root, within: first.after..last.after, associations: paths,
                                              activity: true, snapshots: true)
      before = state(first, root, paths)
      after = state(last, root, paths)
      @failures.check("analyze #{label} diff", diff(before, after), analysis.diff.to_h)
      steps = analysis.activity_timeline
      if steps.empty?
        return @failures.check("analyze #{label} has no step although the state changed", {},
                               mismatch(before, after))
      end

      @failures.check("analyze #{label} from", {}, mismatch(before, analysis.from_snapshot))
      @failures.check("analyze #{label} to", {}, mismatch(after, analysis.to_snapshot))
      window_steps("analyze #{label}", root, paths, after, steps)
    end

    def window_steps(label, root, paths, after, steps)
      @failures.check("#{label} last step to", {}, mismatch(after, steps.last.to_snapshot))
      steps.each_with_index do |step, index|
        @failures.check("#{label} step #{index} stray sources", [], strays(root, paths, step))
      end
    end

    # Through a single-record method and a batch, which move window edges apart.
    def split(root, paths, pivot, group)
      whole = PaperTrail::Version.minimum(:created_at)..@recorder.final.after
      SPLIT_READERS.each do |method, reader|
        options = { associations: paths, group: group }
        label = "#{method} #{[root.id, paths].inspect} windows split at " \
                "#{pivot.utc.iso8601(6)} (group: #{group.inspect})"
        Oracle.check_split(@failures, label, whole, pivot) do |within, scope|
          split_steps(reader.call(root, within: within, **options, **scope))
        end
      end
    end

    def split_steps(steps)
      steps.reject(&:empty?)
           .map { |step| [step.sources.map(&:transaction_id).uniq, step.diff.to_h] }
    end
  end
end
