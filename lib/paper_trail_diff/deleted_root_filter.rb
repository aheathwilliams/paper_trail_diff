# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Keeps the deleted roots the relation would have selected, by the state
  # each held when it was destroyed. A relation's conditions read the live
  # table, where a destroyed root has no row, so without this a report on one
  # account's records would include every account's deletions.
  class DeletedRootFilter
    SLICE = 500
    private_constant :SLICE

    #: (untyped) -> void
    def initialize(relation)
      @relation = relation
      condition = ScopeCondition.for_relation(relation, model)
      unless condition
        raise ConfigurationError,
              'include_deleted: cannot test deleted records against this relation: its ' \
              "conditions must be equality, IN, NULL, or range tests on #{model.name}'s " \
              'own columns, and a range or a text comparison must be on a column whose ' \
              'values compare in Ruby as the database compares them, as for an ' \
              'association scope; select deleted records some other way'
      end

      @condition = condition
      @loader = DirectRecordStateLoader.new
    end

    # nil when the relation's conditions cannot be read.
    #: (untyped) -> DeletedRootFilter?
    def self.readable(relation)
      new(relation)
    rescue ConfigurationError
      nil
    end

    # A root whose destroy PaperTrail did not record has no state to test
    # and stays, as it has no state to report either, unless the relation
    # selects nothing. One whose destroy recorded no state is left out.
    #: (Array[Array[String]]) -> Array[Array[String]]
    def call(identities)
      return [] if @condition.none?

      states = destroyed_states(identities.map(&:last))
      identities.select do |identity|
        id = identity.last
        !states.key?(id) || selected?(states.fetch(id))
      end
    end

    private

    # @rbs @relation: untyped
    # @rbs @condition: ScopeCondition
    # @rbs @loader: DirectRecordStateLoader

    # A relation delegates class methods to its model, so every mutation here,
    # which drops `.model`, answers the same.
    # mutant:disable
    #: () -> untyped
    def model
      @relation.model
    end

    #: (Hash[String, untyped]?) -> bool
    def selected?(attributes)
      return false unless attributes

      AssociationTraversal.sti_member?(model, attributes) && @condition.matches?(attributes)
    end

    # The state each root held before its latest destroy, read in slices: a
    # report lists every deleted root it reached, and SQL Server cannot plan an
    # IN list of thousands.
    #: (Array[String]) -> Hash[String, Hash[String, untyped]?]
    def destroyed_states(ids)
      states = {} #: Hash[String, Hash[String, untyped]?]
      ids.each_slice(SLICE) do |slice|
        destroys = VersionQuery.for_items(model, slice).where(event: 'destroy')
        VersionQuery.chronological(destroys).each do |version|
          states[version.item_id.to_s] =
            @loader.call(version)&.attributes || reified_attributes(version)
        end
      end
      states
    end

    # Read directly, with a column `skip:` left out of history as its default,
    # so a report checks its ceiling before reifying anything. A version the
    # direct reader declines, such as one naming a column since removed, is
    # reified. Only the record's own attributes are read, so the association
    # options, which only spare queries, cannot change an answer.
    # mutant:disable
    #: (untyped) -> Hash[String, untyped]?
    def reified_attributes(version)
      version.reify(dup: true, has_many: false, has_one: false, belongs_to: false,
                    has_and_belongs_to_many: false)&.attributes
    end
  end
end
