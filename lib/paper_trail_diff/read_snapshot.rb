# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Runs one read's statements inside one database snapshot. Without one, a row
  # that commits between two statements of the read can be seen by one of them
  # and missed by another: an activity read then found a comment whose versions
  # it had not read yet, and raised `KeyError`.
  #
  # PostgreSQL and MySQL (through mysql2 or trilogy) run the read at REPEATABLE
  # READ, which gives every statement of the transaction the same view. Other
  # adapters get no snapshot; docs/reference.md lists them under limitations.
  module ReadSnapshot
    # Keyed by the adapter name that `connection_db_config` reports.
    SNAPSHOT_ISOLATION = {
      'postgresql' => :repeatable_read,
      'mysql2' => :repeatable_read,
      'trilogy' => :repeatable_read
    }.freeze

    module_function

    # Yields once. Each connection the values read through gets a snapshot
    # transaction first, unless that connection already has a transaction open:
    # its isolation level belongs to the caller, and this gem cannot change it.
    # A value may be a model class, a relation, a record, or a version. Any
    # other value reads no table and is ignored.
    #: (Array[untyped]) { () -> untyped } -> untyped
    def call(values, &block)
      classes = connection_classes(values)
      classes.reverse_each.reduce(block) do |inner, klass|
        isolation = SNAPSHOT_ISOLATION[klass.connection_db_config.adapter]
        next inner if isolation.nil? || klass.connection.transaction_open?

        -> { klass.transaction(isolation: isolation) { inner.call } }
      end.call
    end

    # One class per connection: each read model and its version class, with the
    # repeats through a shared connection dropped.
    #: (Array[untyped]) -> Array[untyped]
    def connection_classes(values)
      values.filter_map { |value| model_for(value) }
            .flat_map { |model| [model, model.paper_trail.version_class] }
            .uniq(&:connection)
    end

    # The versioned model a value reads from, or nil.
    #: (untyped) -> untyped
    def model_for(value)
      active_record = Object.const_get(:ActiveRecord) #: untyped
      model = case value
              when active_record.const_get(:Relation) then value.klass
              when Class then value
              else endpoint_model(value)
              end
      model if model.is_a?(Class) && Support.versioned?(model)
    end

    # A version reads the model of its item; a record reads its own class.
    #: (untyped) -> untyped
    def endpoint_model(value)
      return Endpoint.model_class(value) if Endpoint.version?(value)

      value.class if Endpoint.record?(value)
    end

    private_class_method :model_for, :endpoint_model
  end
end
