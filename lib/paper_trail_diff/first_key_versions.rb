# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The first versions of a model's records since a start, split by whether
  # they may have changed a key. PT-AT stores the key a version saved, so a
  # version that kept the key has a row naming the key its record held until
  # then, which SQL can match (`kept`). Only a version that may have changed
  # the key needs its stored state decoded to name the key held before it
  # (`stored`), and only where no earlier version has a row for it: the
  # first version ever saved for its record, such as a row from before
  # PaperTrail. Selection and activity read both through this, so neither
  # decodes the stored state of a version whose key a row already names.
  class FirstKeyVersions
    # `key_names` are the key's columns: a polymorphic or `as:` key has a
    # type column too.
    #: (untyped, Array[String], untyped) -> void
    def initialize(model, key_names, start_at)
      @model = model
      @key_names = key_names
      @start_at = start_at
      @versions = model.paper_trail.version_class
      @associations = model.paper_trail.version_association_class
    end

    # PT-AT's rows for `foreign_key_name` on the first version of each record
    # since the start that kept the key: the key the record held from the
    # start until that version, as an analysis reads its state there, even
    # where a write without a version gave it that key.
    #: (String) -> untyped
    def kept(foreign_key_name)
      table = @versions.arel_table
      VersionTable.joined(@associations, @versions)
                  .where(foreign_key_name: foreign_key_name)
                  .where(@versions.table_name => { item_type: @model.base_class.name })
                  .where(stored_state(table).and(first_since_start(table)))
                  .where(key_changes(table).not)
    end

    # The first versions ever saved for their records, since the start, that
    # may have changed the key: only their stored states name the key held
    # before them.
    #: () -> untyped
    def stored
      table = @versions.arel_table
      first = stored_state(table).and(VersionQuery.no_earlier_version(table))
      first = first.and(table[:created_at].gteq(@start_at)) if @start_at
      VersionQuery.for_model(@model).where(first).where(key_changes(table))
    end

    private

    # @rbs @model: untyped
    # @rbs @key_names: Array[String]
    # @rbs @start_at: untyped
    # @rbs @versions: untyped
    # @rbs @associations: untyped

    # A create stores no state and holds no earlier key.
    #: (untyped) -> untyped
    def stored_state(table)
      table[:object].not_eq(nil)
    end

    #: (untyped) -> untyped
    def first_since_start(table)
      start = @start_at
      return VersionQuery.no_earlier_version(table) unless start

      since = VersionQuery.no_earlier_version(table) { |other| other[:created_at].gteq(start) }
      table[:created_at].gteq(start).and(since)
    end

    # The versions that may have changed the key: any but a destroy whose
    # recorded changes name it, or that records none. Without PaperTrail's
    # own recorded changes for the key, any but a destroy may have.
    #: (untyped) -> untyped
    def key_changes(table)
      saved = table[:event].not_eq('destroy')
      return saved unless @key_names.all? { |name| recorded?(name) }

      saved.and(naming_key(table))
    end

    # Versions that recorded no changes, or whose recorded changes name the key.
    #: (untyped) -> untyped
    def naming_key(table)
      changes = recorded_text(table)
      @key_names.map { |name| changes.matches("%#{name}%") }
                .inject(table[:object_changes].eq(nil)) { |any, name| any.or(name) }
    end

    #: (String) -> bool
    def recorded?(name)
      adapter = Support.constant('PaperTrail').config.object_changes_adapter
      @versions.column_names.include?('object_changes') &&
        !adapter.respond_to?(:load_changeset) && RecordedColumns.recorded?(@model, name)
    end

    # PostgreSQL compares a json column with text only once it is cast.
    # Only a json column on PostgreSQL takes the cast, which the SQLite
    # database mutation testing runs on never has.
    # mutant:disable
    #: (untyped) -> untyped
    def recorded_text(table)
      column = table[:object_changes]
      json = StoredTimePrecision.json_column?(@versions, 'object_changes')
      return column unless json && @versions.connection.adapter_name.match?(/postg/i)

      Support.arel::Nodes::NamedFunction.new('CAST', [column.as(Support.arel.sql('text'))])
    end
  end
end
