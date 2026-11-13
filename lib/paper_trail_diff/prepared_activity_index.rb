# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Shares association event discovery across every root in a prepared graph.
  #
  # The candidates are the records the prepared snapshots can hold: those
  # recorded under an owner from the start onward, and those under it now. A
  # key changed without a version is recorded only by the record's next
  # version, or by the current row, either of which can come after the range,
  # and the snapshots read it from there. ActivityTreeFilter leaves out the
  # events of a candidate that was outside the tree throughout.
  class PreparedActivityIndex
    # The children the history's owners had, which its edge loader reads
    # first for most of them.
    attr_reader :children #: PreparedChildCandidates

    #: (PreparedRecordIndex, Array[untyped], start_at: untyped) -> void
    def initialize(records, root_versions, start_at:)
      @records = records
      @start_at = start_at
      @children = PreparedChildCandidates.new(start_at, records.end_time)
      @roots = root_versions.group_by { |version| Endpoint.identity(version) }
      @nodes = {} #: Hash[String, Array[untyped]]
      # Rows are cached by reflection, which a subclass shares with its base.
      @targets = {} #: Hash[untyped, untyped]
      @rows = {} #: Hash[untyped, Hash[String, Array[untyped]]]
      @conditions = ScopeCondition::Cache.new
      @judge = JoinRunJudge.new(records, @conditions)
    end

    # See PreparedRecordIndex#transaction_ends.
    #: (Array[untyped]) -> TransactionEnds
    def transaction_ends(versions) = @records.transaction_ends(versions)

    #: (untyped, Array[untyped]) -> void
    def register(model, ids)
      name = model.base_class.name
      @nodes[name] = (@nodes.fetch(name, []) | ids)
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def versions(model, ids)
      ids.flat_map do |id|
        @roots[Support.record_identity(model, id)] || @records.versions_for_id(model, id)
      end
    end

    # Children are found by key across the whole table, so an association to
    # an STI subclass finds the rows of its siblings too. Only a row that was
    # of the class at some point belongs to it, and of that row only the
    # versions it had the class before or after.
    #: (untyped, Array[untyped]) -> Array[untyped]
    def member_ids(model, ids)
      return ids if model.descends_from_active_record?

      ids.select { |id| member_class?(model, @records.model_classes(model, id)) }
    end

    #: (untyped, Array[untyped], ActivityRange) -> Array[untyped]
    def member_versions(model, ids, range)
      all = versions(model, ids).select { |version| range.include?(version) }
      return all if model.descends_from_active_record?

      all.select do |version|
        member_class?(model, @records.model_classes(model, version.item_id, version))
      end
    end

    # The versions of a through's join rows that are on its path (see
    # ThroughPath). A row's versions in one transaction are judged together, by
    # its states before the transaction and after it, as ActivityTreeFilter
    # judges a record; a version saved outside a transaction is judged alone.
    # A row created under another owner and moved here later, one that left,
    # or one created and destroyed inside one transaction, saved versions that
    # change nothing these `owners` show. As events they would open steps of
    # their own, and inside a transaction, where a change surfaces one event
    # late, take the credit for another record's change.
    #
    # A row of a through that goes through another, such as a member under
    # the member's notes, shows nothing of its path in its own state: it is
    # on it where a row that leads to it does, before its transaction or
    # after it. The groups a through reaches by a `belongs_to` name those
    # rows as `leads`.
    #: (Hash[Symbol, untyped], Hash[Symbol, untyped], untyped) -> Array[untyped]
    def join_versions(owners, group, reflection)
      versions = group.fetch(:versions)
      judge = @judge.call(owners, group, reflection)
      return versions unless judge

      versions.select { |version| judge.call(version) }
    end

    # Only the children the history loaded. Snapshots read children only under
    # an owner the history prepared, and it loaded every child of those. An
    # owner reached another way, such as a belongs_to target loaded for a
    # different path, can have children the history never loaded, which no
    # snapshot holds.
    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[untyped]
    def child_ids(model, ids, reflection, range)
      # An owner the edges did not read is read with every other one this
      # history holds, so that the next needs nothing more.
      historical, live = @children.call(model, ids, reflection) { node_ids(model) }
      child = reflection.klass
      # An owner with no live children reads as nil, which names no record.
      current = ids.flat_map { |id| live[id.to_s] }.select { |id| loaded?(child, id) }
      historical_ids(child, ids, historical, range) | current
    end

    # The `belongs_to` targets each owner pointed at from the range's start
    # onward, plus the live row and those its recorded states name.
    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[ActivityTargetCandidateLoader::Row]
    def target_rows(model, ids, reflection, range)
      historical, live = @targets[reflection] ||= target_candidates(model, reflection)
      eligible_rows(model, rows_for(historical, ids), range) + rows_for(live, ids) +
        recorded_target_rows(model, ids, reflection)
    end

    #: (untyped, untyped) -> bool
    def loaded?(model, id)
      @records.loaded?(model, id)
    end

    # PT-AT records HABTM membership once per transaction, under the
    # association's name, so the rows are keyed by transaction id.
    #: (untyped, Array[untyped], untyped) -> Array[untyped]
    def habtm_rows(model, selected_versions, reflection)
      rows = @rows[reflection] ||= load_habtm_rows(model, reflection)
      transaction_ids(selected_versions).flat_map { |id| rows.fetch(id.to_s, []) }
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @start_at: untyped
    # @rbs @roots: Hash[Array[String], Array[untyped]]
    # @rbs @nodes: Hash[String, Array[untyped]]
    # @rbs @targets: Hash[untyped, untyped]
    # @rbs @rows: Hash[untyped, Hash[String, Array[untyped]]]
    # @rbs @conditions: ScopeCondition::Cache
    # @rbs @judge: JoinRunJudge

    # The targets the owners' recorded states point at. PT-AT names a target
    # only in the rows its owner's versions wrote, so a key changed without a
    # version, such as one `has_paper_trail only:` leaves out, names its target
    # only in the state the owner's next version recorded. Prepared history
    # reads that state, so its snapshots show the target, and the target's
    # versions are events too. A key of two columns is read per record instead.
    #: (untyped, Array[untyped], untyped) -> Array[ActivityTargetCandidateLoader::Row]
    def recorded_target_rows(model, ids, reflection)
      key = reflection.foreign_key
      return [] if key.is_a?(Array)

      ids.flat_map do |id|
        targets = @records.attribute_values_for(model, [id], key)
        types = (@records.attribute_values_for(model, [id], reflection.foreign_type) if
                   reflection.polymorphic?) || []
        targets.zip(types).filter_map do |target, type|
          ActivityTargetCandidateLoader::Row.new(id, target, type) unless target.nil?
        end
      end
    end

    #: (untyped, Array[untyped]) -> bool
    def member_class?(model, classes)
      classes.any? { |model_class| model_class <= model }
    end

    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[untyped]
    def historical_ids(model, ids, historical, range)
      empty = [] #: Array[untyped]
      ids.flat_map do |id|
        historical.fetch(id.to_s, empty).filter_map do |row|
          _owner, child_id, timestamp, event = row
          next unless loaded?(model, child_id)

          child_id if eligible_version?(model, child_id, timestamp, event, range)
        end
      end
    end

    # The records of a model the history holds. None is an answer too: a
    # path past a belongs_to that named no record, as `post.owner` under
    # notes without a post, reaches a model no record of which was loaded.
    #: (untyped) -> Array[untyped]
    def node_ids(model)
      @nodes.fetch(model.base_class.name) { [] }
    end

    #: (Hash[String, Array[ActivityTargetCandidateLoader::Row]], Array[untyped]) -> Array[ActivityTargetCandidateLoader::Row]
    def rows_for(grouped, ids)
      ids.flat_map { |id| grouped[id.to_s] || [] }
    end

    #: (untyped, Array[ActivityTargetCandidateLoader::Row], ActivityRange) -> Array[ActivityTargetCandidateLoader::Row]
    def eligible_rows(model, rows, range)
      rows.select do |row|
        eligible_version?(model, row.owner_id, row.created_at, row.event, range)
      end
    end

    #: (untyped, untyped) -> untyped
    def target_candidates(model, reflection)
      loader = ActivityTargetCandidateLoader.new(model, node_ids(model), reflection, @start_at)
      [loader.historical_rows.group_by { |row| row.owner_id.to_s },
       loader.current_rows.group_by { |row| row.owner_id.to_s }]
    end

    # Mirrors VersionAssociationCandidateScope's before-window rule. The loaded
    # series includes changes to other owners too, so an old membership cannot
    # survive a later pre-window reassignment just because that owner is absent.
    # A range starting at a version starts before that version's transaction,
    # as the scope's start does (see TransactionCut.range_start), so a
    # membership that ended earlier in that transaction still held there. So
    # did one that the record's own transaction across the start ended.
    #: (untyped, untyped, untyped, String?, ActivityRange) -> bool
    def eligible_version?(model, id, timestamp, event, range)
      start = range.start_time
      return true if timestamp >= start
      return false if event == 'destroy'

      versions = @records.versions_for_id(model, id)
      first = versions.bsearch_index { |version| version.created_at > timestamp }
      !first || replaced_after_start?(versions, first, range)
    end

    # Whether the record's next version, at `first`, replaced its state only
    # from the range's start onward.
    #: (Array[untyped], Integer, ActivityRange) -> bool
    def replaced_after_start?(versions, first, range)
      range.opening?(versions.fetch(first)) || crossed_start?(versions, first, range.start_time)
    end

    # Whether every version of a record from `first` up to the start is one
    # of a transaction that crossed the start: one the record saved a version
    # in from the start onward, or one the history found crossing it by
    # another record's versions. Such a transaction may have saved this
    # record only before the start, as when it moved a comment away there
    # and saved the comment's reply after it. The window before the start
    # leaves that move to this one, which finds the reply only under the
    # comment where it stood before the transaction.
    #: (Array[untyped], Integer, untyped) -> bool
    def crossed_start?(versions, first, start)
      after = versions.bsearch_index { |version| version.created_at >= start } || versions.length
      later = versions.drop(after).map do |version|
        ActivityTransactionGroups.transaction_key(version)
      end
      versions.take(after).drop(first).all? do |version|
        key = ActivityTransactionGroups.transaction_key(version)
        !key.nil? && later.include?(key)
      end
    end

    # Each statement reads the rows of 500 transactions.
    #: (untyped, untyped) -> Hash[String, Array[untyped]]
    def load_habtm_rows(model, reflection)
      rows = model.paper_trail.version_association_class.where(foreign_key_name: reflection.name)
      transaction_ids(versions(model, node_ids(model)))
        .each_slice(Support::IDS_PER_STATEMENT)
        .flat_map { |slice| rows.where(version_id: slice) }
        .group_by { |row| row.version_id.to_s }
    end

    # A version without a transaction id names no rows, so it can stay in.
    #: (Array[untyped]) -> Array[untyped]
    def transaction_ids(versions)
      versions.map { |version| VersionBoundary.transaction_id(version) }.uniq
    end
  end

  # Whether one state of a through's join row puts it on the through's path.
  # The row must join one of the owners as the join association reads it: by
  # its key, by the owner's type under `as:`, by its class when the
  # association is to a subclass, and by the association's scope when the
  # gem can read it, unranked, as a through reads its parts. A through that
  # goes through a belongs_to, or through another through, is joined by the
  # owner's key or by rows further down, which a row's own state cannot
  # show. Under `source_type:`, the row's type column must name that class;
  # a version saved before the column existed has no type to read.
  class ThroughPath
    #: (Hash[Symbol, untyped], untyped, ScopeCondition::Cache) -> void
    def initialize(owners, reflection, conditions)
      @reflection = reflection
      @through = reflection.through_reflection
      @keyed = keyed?
      @ids = owners.fetch(:ids).to_set(&:to_s)
      @owner_type = @through.type && AssociationTraversal.owner_type(@through)
      @conditions = conditions
    end

    # Whether every state of a row is on the path, so that none need be read.
    #: () -> bool
    def open?
      !@keyed && @reflection.options[:source_type].nil?
    end

    #: (Hash[untyped, untyped]) -> bool
    def include?(attributes)
      (!@keyed || joined?(attributes)) && typed?(attributes)
    end

    private

    # @rbs @reflection: untyped
    # @rbs @through: untyped
    # @rbs @keyed: bool
    # @rbs @ids: Set[String]
    # @rbs @owner_type: String?
    # @rbs @conditions: ScopeCondition::Cache

    #: () -> bool
    def keyed?
      !@through.through_reflection? && !@through.belongs_to? &&
        !@through.foreign_key.is_a?(Array)
    end

    #: (Hash[untyped, untyped]) -> bool
    def joined?(attributes)
      @ids.include?(attributes.fetch(@through.foreign_key).to_s) && owner_type?(attributes) &&
        AssociationTraversal.sti_member?(@through.klass, attributes) && in_scope?(attributes)
    end

    # An `as:` row's type column must hold its owner's polymorphic name.
    #: (Hash[untyped, untyped]) -> bool
    def owner_type?(attributes)
      type = @owner_type
      !type || type == attributes.fetch(@through.type)
    end

    #: (Hash[untyped, untyped]) -> bool
    def in_scope?(attributes)
      condition = @conditions.call(@through, ranked: false)
      !condition || condition.matches?(attributes)
    end

    # As the through's snapshots read a join row (see
    # PreparedStateAssociationReader#typed_join?).
    #: (Hash[untyped, untyped]) -> bool
    def typed?(attributes)
      AssociationTraversal.source_type_member?(@reflection, attributes[@reflection.foreign_type])
    end
  end

  # How the versions of a through's join row are judged (see
  # PreparedActivityIndex#join_versions): by the row's own states, or by the
  # rows that lead to it, or not at all. A version is judged by its whole
  # transaction, so the row's versions in one transaction are judged alike.
  class JoinRunJudge
    #: (PreparedRecordIndex, ScopeCondition::Cache) -> void
    def initialize(records, conditions)
      @records = records
      @conditions = conditions
    end

    #: (Hash[Symbol, untyped], Hash[Symbol, untyped], untyped) -> (^(untyped) -> bool)?
    def call(owners, group, reflection)
      model = group.fetch(:model)
      path = ThroughPath.new(owners, reflection, @conditions)
      return ->(version) { on_path?(model, version, path) } unless path.open?

      leads = group[:leads]
      return unless leads

      lead = ThroughLead.new(@records, owners, leads, @conditions)
      ->(version) { lead.include?(*transaction_span(model, version)) }
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @conditions: ScopeCondition::Cache

    #: (untyped, untyped, ThroughPath) -> bool
    def on_path?(model, version, path)
      first, last = transaction_span(model, version)
      @records.typed_states_across(model, first.item_id, first, last)
              .any? { |attributes| path.include?(attributes) }
    end

    # The first and last versions the row saved in the version's
    # transaction: a version is judged by the row's whole transaction, not
    # only the part inside the range. A window whose edge falls inside the transaction holds only
    # some of the row's versions in it. Judged by its destroy alone, a row
    # moved here and destroyed in one transaction was on the path, so the
    # window after the edge reported the transaction, which the window before
    # it, judging the row by both versions, reported too. The row's series
    # holds the whole transaction: history crossed by one is read from where
    # it began (see PreparedHistoryLoader#reload). A version saved outside a
    # transaction is judged alone.
    #: (untyped, untyped) -> [untyped, untyped]
    def transaction_span(model, version)
      key = ActivityTransactionGroups.transaction_key(version)
      return [version, version] unless key

      saved = @records.versions_for_id(model, version.item_id)
                      .select { |other| ActivityTransactionGroups.transaction_key(other) == key }
      [saved.fetch(0), saved.fetch(-1)]
    end
  end

  # Whether the rows that lead to a through's target, as a through over that
  # through reads it, named the target before a transaction of the target's
  # or after it, on their own path (see PreparedActivityIndex#join_versions).
  class ThroughLead
    #: (PreparedRecordIndex, Hash[Symbol, untyped], Hash[Symbol, untyped], ScopeCondition::Cache) -> void
    def initialize(records, owners, leads, conditions)
      @records = records
      @rows = leads.fetch(:group)
      reflection = leads.fetch(:reflection)
      @path = ThroughPath.new(owners, reflection, conditions)
      @key = reflection.foreign_key
    end

    # `first` and `last` are the target's versions that span its transaction.
    #: (untyped, untyped) -> bool
    def include?(first, last)
      id = first.item_id.to_s
      @rows.fetch(:ids).any? do |row|
        @records.typed_states_around(@rows.fetch(:model), row, first, last).any? do |attributes|
          attributes.fetch(@key).to_s == id && @path.include?(attributes)
        end
      end
    end

    # @rbs @records: PreparedRecordIndex
    # @rbs @rows: Hash[Symbol, untyped]
    # @rbs @path: ThroughPath
    # @rbs @key: untyped
  end
end
