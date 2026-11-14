# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Credits each change row to the version that made its change, which need
  # not be its step's source: a transaction group starts at one record's
  # event, and inside a transaction a record's change can surface at a later
  # event than its own (see ActivityTransactionGrouper).
  #
  # The versions a record saved in the step's transaction, up to the step's
  # last source, made its changes there. A field's change follows what they
  # recorded of it: each run of recorded changes is credited to the version
  # that ended it, or the whole change to the last of the record's versions
  # when what they recorded was not read. A record that appeared or
  # disappeared is credited to its own create or destroy, or else to the
  # last of its versions there, as a record that moved by its own update.
  # Any other row keeps the step's source: a record that joined a collection
  # or became a to-one target through another record's change, for one.
  #
  # With recorded changes read, the part of a field's change that those
  # versions did not record is split off and credited to an unversioned
  # source. It was saved without a version, as with `update_columns`, and
  # history reads it into the state the next version stores, or the current
  # row, so it shows up beside the change before it. Only what the versions
  # show is split off. The row stays whole where they cannot:
  #
  # - a version that recorded nothing, such as a `touch`, or a table without
  #   `object_changes`;
  # - a column PaperTrail is told not to record (see RecordedColumns);
  # - a field a create left out, which held its default when created.
  class ChangeAttribution
    # A transaction's boundaries, in the order the history kept them. Every
    # step the transaction opens shares the one list and reads the boundaries
    # before its own sources, so a long transaction costs one list rather
    # than one for each step. A record's boundaries are found through an
    # index, built when rows are first read, once the history is complete.
    # A step's own sources are kept the same way, so a transaction group's
    # rows name each source's record once rather than once for each record.
    class Transaction
      #: (?Array[ActivityBoundary]) -> void
      def initialize(boundaries = [])
        @boundaries = boundaries.dup
      end

      #: (ActivityBoundary) -> void
      def add(boundary)
        @boundaries << boundary
        @positions = nil
      end

      #: () -> Integer
      def length = @boundaries.length

      # Whether the boundary is one of these, not merely one like it.
      #: (ActivityBoundary) -> bool
      def holds?(boundary)
        @boundaries.any? { |held| held.equal?(boundary) }
      end

      # The record's boundaries among the first `count`, in order. The block
      # names a boundary's record. The index is built whole before it is
      # kept, so readers on two threads build the same one.
      #: (Array[String], Integer) { (ActivityBoundary) -> Array[String] } -> Array[ActivityBoundary]
      def of(key, count, &identify)
        positions = @positions ||= index(identify)
        positions.fetch(key, []).take_while { |position| position < count }
                 .map { |position| @boundaries.fetch(position) }
      end

      private

      # @rbs @boundaries: Array[ActivityBoundary]
      # @rbs @positions: Hash[Array[String], Array[Integer]]?

      #: (^(ActivityBoundary) -> Array[String]) -> Hash[Array[String], Array[Integer]]
      def index(identify)
        @boundaries.each_index.group_by { |position| identify.call(@boundaries.fetch(position)) }
      end
    end

    # `root` is the record the timeline is about, which rows name by leaving
    # `record` nil. `transaction` holds the boundaries of the step's
    # transaction, of which the first `preceding` came before its sources.
    #: (root: RecordReference, sources: Array[ActivityBoundary], transaction: Transaction, ?preceding: Integer) -> void
    def initialize(root:, sources:, transaction:, preceding: transaction.length)
      @root = root
      @sources = Transaction.new(sources)
      @transaction = transaction
      @preceding = preceding
      @versions = {} #: Hash[Array[String], Array[ActivityBoundary]]
      freeze
    end

    # The same transaction, read through a transaction group's sources.
    #: (Array[ActivityBoundary]) -> ChangeAttribution
    def with_sources(sources)
      self.class.new(root: @root, sources: sources, transaction: @transaction,
                     preceding: @preceding)
    end

    # The row as the rows it splits into, each credited to its change's
    # source: one row, unless part of its change was saved without a version.
    #: (ChangeRow) -> Array[ChangeRow]
    def call(row)
      versions = versions_of(row.record || @root)
      return [row] if versions.empty?

      case row.change
      when :changed then changed(row, versions)
      when :added then added(row, versions)
      else [removed(row, versions)]
      end
    end

    private

    # @rbs @root: RecordReference
    # @rbs @sources: Transaction
    # @rbs @transaction: Transaction
    # @rbs @preceding: Integer
    # @rbs @versions: Hash[Array[String], Array[ActivityBoundary]]

    # A field's change follows what the record's versions recorded of it,
    # from the value the row starts at (see #relevant): each run of recorded
    # changes is one row, credited to the version that ended it, and a value
    # that moved where they do not meet was saved without a version.
    #: (ChangeRow, Array[ActivityBoundary]) -> Array[ChangeRow]
    def changed(row, versions)
      touched = recorded_changes(versions, row.attribute)
      return [credit(row, versions.last)] if touched.nil?

      relevant = relevant(touched, row)
      return unrecorded(row, versions) if relevant.empty?

      rows_for(row, chain(row.from, row.to, relevant, true), :changed)
    end

    # The changes that make up the row's: from the last one that left the
    # row's starting value; or else those after the last that reached it,
    # which an earlier step reported; or else all of them, which for a root's
    # own field are only the ones its sources saved. A step starts from the
    # state before its source, and a root's fields are read at each of its
    # versions, so the root versions its transaction saved before the sources
    # are already in that state. A related record's fields are read as the
    # transaction began, so those versions still count.
    #: (Array[[ActivityBoundary, ValueChange]], ChangeRow) -> Array[[ActivityBoundary, ValueChange]]
    def relevant(touched, row)
      start = row.from
      leaving = touched.rindex { |_version, change| change.from == start }
      return touched.drop(leaving) if leaving

      reaching = touched.rindex { |_version, change| change.to == start }
      return touched.drop(reaching + 1) if reaching
      return touched if row.record

      touched.select { |version, _change| @sources.holds?(version) }
    end

    # A field none of the versions recorded changed without one, when they
    # record every change of it they make.
    #: (ChangeRow, Array[ActivityBoundary]) -> Array[ChangeRow]
    def unrecorded(row, versions)
      return [credit(row, versions.last)] unless recorded_column?(row)

      [credit(row, unversioned(row))]
    end

    # Only a record's own create says what it was created with. A field the
    # create left out held its default, which no version records, so a value
    # there can be the default or a later write: the row stays whole, or runs
    # from nothing to what the versions after the create recorded.
    #: (ChangeRow, Array[ActivityBoundary]) -> Array[ChangeRow]
    def added(row, versions)
      index = versions.index { |version| version.event == 'create' }
      return [credit(row, versions.last)] unless index

      created = versions.drop(index)
      touched = recorded_changes(created, row.attribute)
      return [credit(row, created.first)] if touched.nil? || touched.empty?

      rows_for(row, chain(nil, row.to, touched, false), :added)
    end

    # The value's path from `start` to `finish` as links of [from, to,
    # version], with nil for no version: each recorded change, and between
    # them whatever moved without one. A first change that does not start
    # where the row does joins the row's start unless `trusted`.
    #: (untyped, untyped, Array[[ActivityBoundary, ValueChange]], bool) -> Array[[untyped, untyped, ActivityBoundary?]]
    def chain(start, finish, touched, trusted)
      links = [] #: Array[[untyped, untyped, ActivityBoundary?]]
      value = start
      touched.each_with_index do |(version, change), index|
        value = bridge(links, value, change.from) if index.positive? || trusted
        links << link(value, change.to, version)
        value = change.to
      end
      bridge(links, value, finish)
      merge(merge(links).reject { |from, to, _version| from == to })
    end

    # A move from `value` to `to` that no version recorded, as a link; returns
    # where it ends.
    #: (Array[[untyped, untyped, ActivityBoundary?]], untyped, untyped) -> untyped
    def bridge(links, value, to)
      links << link(value, to, nil) unless to == value
      to
    end

    #: (untyped, untyped, ActivityBoundary?) -> [untyped, untyped, ActivityBoundary?]
    def link(from, to, version) = [from, to, version]

    # Consecutive links of the same kind as one: recorded ones credited to the
    # last of their versions.
    #: (Array[[untyped, untyped, ActivityBoundary?]]) -> Array[[untyped, untyped, ActivityBoundary?]]
    def merge(links)
      merged = [] #: Array[[untyped, untyped, ActivityBoundary?]]
      links.each do |from, to, version|
        previous = merged.last
        if previous && previous.last.nil? == version.nil?
          merged[-1] = [previous.first, to, version]
        else
          merged << [from, to, version]
        end
      end
      merged
    end

    # The first link keeps the row's own change, so an added field starts
    # from nothing; its later values are changes to it.
    #: (ChangeRow, Array[[untyped, untyped, ActivityBoundary?]], Symbol) -> Array[ChangeRow]
    def rows_for(row, links, first)
      links.each_with_index.map do |(from, to, version), index|
        copy(row, change: index.zero? ? first : :changed, from: from, to: to,
                  source: version || unversioned(row))
      end
    end

    #: (ChangeRow, Array[ActivityBoundary]) -> ChangeRow
    def removed(row, versions)
      destroy = versions.find { |version| version.event == 'destroy' }
      credit(row, destroy || versions.last)
    end

    # The changes the versions recorded of a field, each with its version:
    # nil when one of them recorded nothing, or their changes were not read.
    #: (Array[ActivityBoundary], String?) -> Array[[ActivityBoundary, ValueChange]]?
    def recorded_changes(versions, name)
      changes = recorded(versions)
      return unless changes

      touched = [] #: Array[[ActivityBoundary, ValueChange]]
      versions.each_with_index do |version, index|
        change = changes.fetch(index)[name]
        touched << [version, change] if change
      end
      touched
    end

    # A row about a whole record has no field name, which no version records.
    #: (Array[ActivityBoundary]) -> Array[Hash[untyped, ValueChange]]?
    def recorded(versions)
      return unless versions.all?(&:recorded_changes?)

      changes = versions.filter_map(&:recorded_changes)
      changes if changes.length == versions.length
    end

    #: (ChangeRow) -> bool
    def recorded_column?(row)
      RecordedColumns.recorded?(Support.constant((row.record || @root).type), row.attribute)
    rescue NameError
      false
    end

    # The record's boundaries in the step's transaction, up to its last
    # source, read once for each record.
    #: (RecordReference) -> Array[ActivityBoundary]
    def versions_of(reference)
      key = identity(reference)
      @versions.fetch(key) do
        identify = ->(boundary) { identity(boundary.record) }
        earlier = @transaction.of(key, @preceding, &identify)
        @versions[key] = earlier + @sources.of(key, @sources.length, &identify)
      end
    end

    # A record's base class and id, which name its row whichever subclass a
    # snapshot or a version gives.
    #: (RecordReference) -> Array[String]
    def identity(reference)
      [base_name(reference.type), reference.id.to_s]
    end

    #: (String) -> String
    def base_name(type)
      Support.constant(type).base_class.name
    rescue NameError
      type
    end

    #: (ChangeRow) -> ActivityBoundary
    def unversioned(row)
      reference = row.record || @root
      ActivityBoundary.unversioned(item_type: base_name(reference.type), item_id: reference.id)
    end

    #: (ChangeRow, ActivityBoundary) -> ChangeRow
    def credit(row, source)
      copy(row, source: source)
    end

    #: (ChangeRow, source: ActivityBoundary, ?change: Symbol, ?from: untyped, ?to: untyped) -> ChangeRow
    def copy(row, source:, change: row.change, from: row.from, to: row.to)
      ChangeRow.new(
        change: change, association_path: row.association_path,
        association_kind: row.association_kind, record: row.record,
        attribute: row.attribute, from: from, to: to, source: source
      )
    end
  end
end
