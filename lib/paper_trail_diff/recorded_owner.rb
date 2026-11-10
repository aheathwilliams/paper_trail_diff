# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PT-AT records a child's owner on the child's own versions, once for each
  # belongs_to the child declares: the owner's id under the foreign key's
  # name, with the class that belongs_to names. A has_many or has_one is read
  # back from those rows.
  module RecordedOwner
    # The names a row may hold for an owner of this class. A polymorphic key
    # names the owner's base class. A plain belongs_to names the class it was
    # declared with, which under single-table inheritance may be any class of
    # the owner's table and not the owner's own. A row with no type is
    # anyone's.
    #: (untyped, untyped) -> Array[String?]
    def self.types(reflection, owner_class)
      [nil, '', owner_class.name, owner_class.base_class.name, *declared_types(reflection)].uniq
    end

    # The classes named by the belongs_to associations on the reflection's
    # foreign key, as its target declares them or a subclass of its target
    # does.
    #: (untyped) -> Array[String]
    def self.declared_types(reflection)
      [reflection.klass, *reflection.klass.descendants].flat_map do |model|
        model.reflect_on_all_associations(:belongs_to).filter_map do |inverse|
          next if inverse.polymorphic? || inverse.foreign_key != reflection.foreign_key

          inverse.klass.name
        end
      end
    end
    private_class_method :declared_types
  end
end
