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

    # Why history cannot say which records left a has_many or has_one, or a
    # part of a through: its target declares no belongs_to on the foreign
    # key, so no version of a target names an owner. Such a path would show
    # the records it holds now, and none that was destroyed or moved away.
    #: (untyped) -> String?
    def self.unsupported_reason(reflection)
      part = [reflection, *AssociationTraversal.through_parts(reflection)].find do |candidate|
        unrecorded?(candidate)
      end
      return unless part

      owner = part.active_record.name
      "#{part.klass.name} declares no belongs_to on #{part.foreign_key}, so its versions do not " \
        "record the #{owner} that held it, and one that left #{owner}##{part.name} cannot be found"
    end

    # A belongs_to and a HABTM are recorded on the owner's own versions, and
    # a through by its parts. PT-AT cannot record a composite key, which is
    # read another way (see FallbackPaths), and a target without versions is
    # refused for that.
    #: (untyped) -> bool
    def self.unrecorded?(part)
      return false unless %i[has_many has_one].include?(part.macro)
      return false if part.through_reflection? || part.foreign_key.is_a?(Array)

      Support.versioned?(part.klass) && inverses(part.klass, part).empty?
    end
    private_class_method :unrecorded?

    # The classes named by the belongs_to associations on the reflection's
    # foreign key, as its target declares them or a subclass of its target
    # does.
    #: (untyped) -> Array[String]
    def self.declared_types(reflection)
      [reflection.klass, *reflection.klass.descendants]
        .flat_map { |model| inverses(model, reflection) }
        .reject(&:polymorphic?).map { |inverse| inverse.klass.name }
    end
    private_class_method :declared_types

    # The model's belongs_to associations on the reflection's foreign key.
    #: (untyped, untyped) -> Array[untyped]
    def self.inverses(model, reflection)
      model.reflect_on_all_associations(:belongs_to).select do |inverse|
        inverse.foreign_key == reflection.foreign_key
      end
    end
    private_class_method :inverses
  end
end
