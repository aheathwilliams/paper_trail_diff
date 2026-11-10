# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Where each transaction of a root's timeline takes effect: at the last
  # version it saved, of any record, as `recorded` holds it (see
  # RecordedTransactionEnds); among the timeline's own versions where that is
  # not known, as on a root read without its associations.
  #
  # Two transactions that save in one tree at the same time interleave their
  # versions, yet neither sees what the other has not committed, and one may
  # undo its own changes before it ends, such as a comment it created and
  # deleted again. Rows locked by a write keep two open transactions from
  # saving one record, so wherever the order of two transactions matters, the
  # one that saved its last version first also ended first. A timeline that
  # places every version of a transaction at its last one therefore reads the
  # transactions one after another, as if none had overlapped: a record reads
  # as it stood before every transaction that had not ended yet, and each
  # change is reported with its own transaction's.
  #
  # A version saved outside a transaction takes effect where it was saved.
  class TransactionEnds
    #: (Array[untyped], ?Hash[Array[untyped], untyped]) -> void
    def initialize(versions, recorded = {})
      @recorded = recorded
      @last = {} #: Hash[Array[untyped], untyped]
      @keys = {} #: Hash[Array[untyped], Array[untyped]]
      versions.each { |version| note(version) }
      @horizon = versions.map { |version| Support.chronological_version_key(version) }.max
      @reordered = reordered?(versions)
      freeze
    end

    # Whether placing the versions at their transactions' ends changes their
    # order: some transaction saved a version between two of another's.
    #: () -> bool
    def interleaved? = @reordered

    # The last version of the version's transaction, or the version itself.
    #: (untyped) -> untyped
    def last(version)
      key = ActivityTransactionGroups.transaction_key(version)
      (key && (@recorded[key] || @last[key])) || version
    end

    # Whether the version was saved after every version of the timeline. A
    # history can hold such a version, as the next one of a record after the
    # range it was read for, or as part of a batch's history that runs on for
    # another root. The timeline ends before it, so it takes effect after
    # everything the timeline holds, whenever its transaction ended.
    #: (untyped) -> bool
    def beyond?(version)
      horizon = @horizon
      !horizon.nil? && (Support.chronological_version_key(version) <=> horizon) == 1
    end

    # Orders versions by where their transactions end, then as they were
    # saved.
    #: (untyped) -> Array[untyped]
    def sort_key(version)
      [Support.chronological_version_key(last(version)),
       Support.chronological_version_key(version)]
    end

    private

    # @rbs @recorded: Hash[Array[untyped], untyped]
    # @rbs @last: Hash[Array[untyped], untyped]
    # @rbs @keys: Hash[Array[untyped], Array[untyped]]
    # @rbs @horizon: Array[untyped]?
    # @rbs @reordered: bool

    #: (untyped) -> void
    def note(version)
      key = ActivityTransactionGroups.transaction_key(version)
      return unless key

      own = Support.chronological_version_key(version)
      held = @keys[key]
      return if held && (held <=> own) != -1

      @keys[key] = own
      @last[key] = version
    end

    #: (Array[untyped]) -> bool
    def reordered?(versions)
      saved = versions.sort_by { |version| Support.chronological_version_key(version) }
      saved != saved.sort_by { |version| sort_key(version) }
    end
  end

  # Reads where transactions end from their version tables: the last version
  # each saved there, of any record.
  #
  # A transaction can go on to save a record a timeline does not hold, such
  # as one it moved out of the tree, and which records a timeline holds
  # depends on where it is read from. Were a transaction placed at the last
  # of the versions held, two windows could place it differently, and what it
  # did would be reported in neither or in both.
  #
  # The versions held are asked about together, a statement for 500
  # transactions, and one more for those whose last version is not held. Ids
  # that count up name the last version; otherwise the time it was saved
  # does. A number that transactions of two version tables took is not read
  # (see TransactionAnchors), and its versions are placed at the last held.
  class RecordedTransactionEnds
    #: () -> void
    def initialize
      @ends = {} #: Hash[Array[untyped], untyped]
      @asked = Set.new #: Set[Array[untyped]]
    end

    # The last version of each transaction asked about so far, by transaction
    # key, once those of `versions` are among them. They are asked about along
    # with every version the block returns, so that a history is read at once.
    #: (Array[untyped]) { () -> Array[untyped] } -> Hash[Array[untyped], untyped]
    def call(versions)
      ask(versions + yield) unless versions.all? { |version| asked?(version) }
      @ends
    end

    private

    # @rbs @ends: Hash[Array[untyped], untyped]
    # @rbs @asked: Set[Array[untyped]]

    #: (untyped) -> bool
    def asked?(version)
      key = ActivityTransactionGroups.transaction_key(version)
      key.nil? || @asked.include?(key)
    end

    #: (Array[untyped]) -> void
    def ask(versions)
      versions.reject { |version| asked?(version) }.group_by(&:class).each do |version_class, held|
        by_number = held.group_by { |version| VersionBoundary.transaction_id(version) }
        by_number.each_key { |number| @asked << [version_class.name, number] }
        by_number.keys.each_slice(Support::IDS_PER_STATEMENT) do |numbers|
          read(version_class, numbers - TransactionAnchors.shared(version_class, numbers),
               by_number)
        end
      end
    end

    # Notes the last version of each of these transactions: the one held
    # where it is, and the one read otherwise.
    #: (untyped, Array[untyped], Hash[untyped, Array[untyped]]) -> void
    def read(version_class, numbers, held)
      return if numbers.empty?

      column = last_column(version_class)
      last = version_class.where(transaction_id: numbers).group(:transaction_id).maximum(column)
      known = held.values_at(*last.keys).flatten + other(version_class, column, last, held)
      note(version_class, known.select { |each| each[column] == last[each.transaction_id] })
    end

    # Of the versions with the id or the time of their transaction's last,
    # the last of each transaction.
    #: (untyped, Array[untyped]) -> void
    def note(version_class, versions)
      versions.group_by(&:transaction_id).each do |number, last|
        @ends[[version_class.name, number]] =
          last.max_by { |version| Support.chronological_version_key(version) }
      end
    end

    # The versions not held that may be the last of their transactions:
    # those with the id or the time of the last of one that holds no such
    # version.
    #: (untyped, String, Hash[untyped, untyped], Hash[untyped, Array[untyped]]) -> Array[untyped]
    def other(version_class, column, last, held)
      missing = last.reject do |number, value|
        held.fetch(number).any? { |version| version[column] == value }
      end
      return [] if missing.empty?

      version_class.where(transaction_id: missing.keys, column => missing.values.uniq)
                   .select(version_class.primary_key, :created_at, :transaction_id,
                           :item_type, :item_id).to_a
    end

    # What names a transaction's last version: its id where ids count up,
    # and the time it was saved otherwise.
    #: (untyped) -> String
    def last_column(version_class)
      key = version_class.primary_key
      counts_up = key.is_a?(String) && version_class.type_for_attribute(key).type == :integer
      counts_up ? key : 'created_at'
    end
  end
end
