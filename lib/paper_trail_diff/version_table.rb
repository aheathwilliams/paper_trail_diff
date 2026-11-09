# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PT-AT reads an association's history from its owner's version tables: it
  # looks for a child's versions in the owner's version table, and numbers a
  # transaction by the first version saved in it, in whichever table. A model
  # whose versions, or version associations, live in another table than its
  # owner's would read other records' versions or none, so it is refused.
  module VersionTable
    # Why the association, or a part of a through, cannot be read across
    # version tables.
    #: (untyped) -> String?
    def self.unsupported_reason(reflection)
      part = separate_part(reflection)
      return unless part

      "#{part.active_record.name}##{part.name} keeps versions in #{tables(part.active_record)} " \
        "but #{part.klass.name} in #{tables(part.klass)}, and association history is read " \
        'from one set of version tables'
    end

    # The reflection, or the first part of a through, whose ends keep versions
    # in different tables. A polymorphic belongs_to names no single target,
    # and an unversioned target has no history to compare.
    #: (untyped) -> untyped
    def self.separate_part(reflection)
      [reflection, *AssociationTraversal.through_parts(reflection)].find do |part|
        !part.through_reflection? && separate?(part)
      end
    end
    private_class_method :separate_part

    #: (untyped) -> bool
    def self.separate?(reflection)
      return false if reflection.polymorphic?

      owner = reflection.active_record
      target = reflection.klass
      return false unless Support.versioned?(owner) && Support.versioned?(target)
      return false if tables(owner) == tables(target)

      true
    end
    private_class_method :separate?

    # PT-AT's version association rows joined to the versions they were saved
    # with. Its `belongs_to :version` names PaperTrail's default class whatever
    # table a model's versions are in, so the join names the table instead.
    #: (untyped, untyped) -> untyped
    def self.joined(associations, versions)
      rows = associations.arel_table
      table = versions.arel_table
      associations.joins(rows.join(table).on(table[:id].eq(rows[:version_id])).join_sources)
    end

    # Without PT-AT loaded there are no version associations to name, and
    # TraversalPreparer refuses history for that reason first, so only the
    # versions' table is compared: a live comparison or association_paths
    # still works.
    #: (untyped) -> String
    def self.tables(model)
      history = model.paper_trail
      versions = history.version_class.table_name
      return versions unless history.respond_to?(:version_association_class)

      "#{versions} and #{history.version_association_class.table_name}"
    end
    private_class_method :tables
  end
end
