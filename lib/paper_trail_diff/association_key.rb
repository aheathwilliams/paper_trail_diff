# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PT-AT records which record a child pointed at by that record's id, and
  # history matches children to owners and targets by id. An association
  # keyed on another column (`primary_key:`) would read other records'
  # history, so it is refused.
  module AssociationKey
    # Why the association, or a part of a through, cannot be read by id.
    #: (untyped) -> String?
    def self.unsupported_reason(reflection)
      part = keyed_part(reflection)
      return unless part

      "#{part.active_record.name}##{part.name} matches records by " \
        "#{part.options[:primary_key]} rather than the primary key, and association " \
        'history is recorded by primary key'
    end

    # The reflection, or the first part of a through, keyed on a column other
    # than its owner's or target's primary key.
    #: (untyped) -> untyped
    def self.keyed_part(reflection)
      return reflection if other_key?(reflection)
      return unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].filter_map do |part|
        keyed_part(part)
      end.first
    end
    private_class_method :keyed_part

    # A belongs_to names a key of its target; any other macro, one of its
    # owner. A polymorphic target has no single primary key to compare with.
    #: (untyped) -> bool
    def self.other_key?(reflection)
      key = reflection.options[:primary_key]
      return false unless key
      return true if reflection.polymorphic?

      model = reflection.belongs_to? ? reflection.klass : reflection.active_record
      !same_column?(key, model.primary_key)
    end
    private_class_method :other_key?

    # Column names are strings once the key is, so the one mutation left,
    # `eql?` for `==`, answers the same.
    # mutant:disable
    #: (untyped, untyped) -> bool
    def self.same_column?(key, primary_key)
      key.to_s == primary_key
    end
    private_class_method :same_column?
  end
end
