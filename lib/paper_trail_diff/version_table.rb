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
      if reflection.through_reflection?
        return [reflection.through_reflection, reflection.source_reflection].filter_map do |part|
          separate_part(part)
        end.first
      end
      return if reflection.polymorphic?

      owner = reflection.active_record
      target = reflection.klass
      return unless Support.versioned?(owner) && Support.versioned?(target)

      reflection unless tables(owner) == tables(target)
    end
    private_class_method :separate_part

    # PT-AT's version association rows joined to the versions they were saved
    # with. Its `belongs_to :version` names PaperTrail's default class whatever
    # table a model's versions are in, so the join names the table instead.
    #: (untyped, untyped) -> untyped
    def self.joined(associations, versions)
      rows = associations.arel_table
      table = versions.arel_table
      associations.joins(rows.join(table).on(table[:id].eq(rows[:version_id])).join_sources)
    end

    #: (untyped) -> String
    def self.tables(model)
      history = model.paper_trail
      "#{history.version_class.table_name} and #{history.version_association_class.table_name}"
    end
    private_class_method :tables
  end
end
