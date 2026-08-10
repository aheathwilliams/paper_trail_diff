# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reloads current-record endpoints and their explicitly selected associations in batches.
  class LiveEndpointBatchLoader
    #: (tree: AssociationTree) -> void
    def initialize(tree:)
      @tree = tree
    end

    #: (Array[untyped]) -> Hash[identity, untyped]
    def call(records)
      loaded = {} #: Hash[identity, untyped]
      records.group_by(&:class).each do |model_class, grouped|
        load_group(model_class, grouped).each do |record|
          loaded[Endpoint.identity(record)] = record
        end
      end
      ensure_all_loaded!(records, loaded)
      loaded
    end

    private

    # @rbs @tree: AssociationTree

    #: (untyped, Array[untyped]) -> Array[untyped]
    def load_group(model_class, records)
      relation = model_class.unscoped.where(model_class.primary_key => records.map(&:id).uniq)
      loaded = relation.to_a
      preload_tree(loaded, @tree)
      loaded
    end

    #: (Array[untyped], AssociationTree) -> void
    def preload_tree(records, tree)
      return if records.empty? || tree.empty?

      records.group_by(&:class).each do |model_class, grouped_records|
        preload_model_tree(model_class, grouped_records, tree)
      end
    end

    #: (untyped, Array[untyped], AssociationTree) -> void
    def preload_model_tree(model_class, records, tree)
      batch, individual = selected_reflections(model_class, tree).partition do |reflection, _|
        batch_safe?(records.fetch(0), reflection)
      end
      preload_batch(records, batch.map { |reflection, _| reflection.name })
      preload_subtrees(records, batch, individually: false)
      preload_subtrees(records, individual, individually: true)
    end

    #: (untyped, AssociationTree) -> Array[[untyped, AssociationTree]]
    def selected_reflections(model_class, tree)
      tree.children.map do |name, subtree|
        reflection = model_class.reflect_on_association(name)
        raise ConfigurationError, "unknown association: #{name}" unless reflection

        [reflection, subtree]
      end
    end

    #: (Array[untyped], Array[[untyped, AssociationTree]], individually: bool) -> void
    def preload_subtrees(records, reflections, individually:)
      reflections.each do |reflection, subtree|
        children = if individually
                     load_individually(records, reflection)
                   else
                     targets(records, reflection)
                   end
        preload_tree(children, subtree)
      end
    end

    #: (Array[untyped], Array[Symbol]) -> void
    def preload_batch(records, associations)
      return if associations.empty?

      active_record_preloader.new(
        records: records,
        associations: associations
      ).call
    end

    #: () -> untyped
    def active_record_preloader
      active_record = Object.const_get(:ActiveRecord)
      active_record.const_get(:Associations).const_get(:Preloader)
    end

    #: (untyped, untyped) -> bool
    def batch_safe?(record, reflection)
      scope = reflection.scope
      return false if scope && !scope.arity.zero?
      return true unless reflection.collection?

      relation = record.association(reflection.name).scope
      relation.limit_value.nil? && relation.offset_value.nil?
    end

    #: (Array[untyped], untyped) -> Array[untyped]
    def load_individually(records, reflection)
      unique_records(records.flat_map do |record|
        Array(record.association(reflection.name).load_target)
      end)
    end

    #: (Array[untyped], untyped) -> Array[untyped]
    def targets(records, reflection)
      unique_records(records.flat_map do |record|
        Array(record.association(reflection.name).target)
      end)
    end

    #: (Array[untyped]) -> Array[untyped]
    def unique_records(records)
      records.compact.uniq do |record|
        [record.class.base_class.name.to_s, record.id.to_s]
      end
    end

    #: (Array[untyped], Hash[identity, untyped]) -> void
    def ensure_all_loaded!(records, loaded)
      missing = records.map { |record| Endpoint.identity(record) }.uniq - loaded.keys
      return if missing.empty?

      message = 'current record endpoint could not be reloaded from the database'
      raise InvalidEndpointError, message
    end
  end
end
