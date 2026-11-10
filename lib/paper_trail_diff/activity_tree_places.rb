# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Says whether an event on a record of some model can be applied to the
  # one place the record has in a snapshot.
  #
  # A path can lead to a record twice: an article read with `author.articles`
  # is the root and one of its author's articles, and under
  # `articles.comments.article` an article is a member of a collection and
  # the target of a `belongs_to` below it. An event is applied to a snapshot
  # in one way, as the root's, a collection member's, or a target's, so it
  # reaches the places of that one kind and would leave the others as they
  # were. Such an event has its branches, or for the root the whole snapshot,
  # read again instead.
  class ActivityTreePlaces
    #: (AssociationTraversal) -> void
    def initialize(traversal)
      @traversal = traversal
      @kinds = {} #: Hash[untyped, Hash[String, Array[Symbol]]]
      @polymorphic = {} #: Hash[untyped, bool]
    end

    # Whether every place the tree gives records of the type is of one kind.
    # A polymorphic `belongs_to` can point at a record of any model, so a
    # tree with one gives every model a place there too.
    #: (untyped, String) -> bool
    def one_kind?(root_class, type)
      kinds = kinds_for(root_class)
      !@polymorphic.fetch(root_class) && kinds.fetch(type) { [] }.length <= 1
    end

    private

    # @rbs @traversal: AssociationTraversal
    # @rbs @kinds: Hash[untyped, Hash[String, Array[Symbol]]]
    # @rbs @polymorphic: Hash[untyped, bool]

    # The kinds of place each model has under this root, by base class name.
    #: (untyped) -> Hash[String, Array[Symbol]]
    def kinds_for(root_class)
      @kinds.fetch(root_class) do
        kinds = { root_class.base_class.name => [:root] } #: Hash[String, Array[Symbol]]
        @polymorphic[root_class] = false
        collect(root_class, root_class, @traversal.tree, '', kinds)
        @kinds[root_class] = kinds
      end
    end

    #: (untyped, untyped, AssociationTree, String, Hash[String, Array[Symbol]]) -> void
    def collect(root_class, model_class, tree, path, kinds)
      @traversal.reflections_for(model_class, tree, path: path).each do |reflection|
        next @polymorphic[root_class] = true if reflection.polymorphic?

        place(reflection, kinds)
        subtree = tree.child(reflection.name) #: AssociationTree
        next if subtree.empty?

        collect(root_class, reflection.klass, subtree,
                Support.association_path(path, reflection.name), kinds)
      end
    end

    # A through holds its target, and the records it joins through decide
    # what it holds, so each of them has a place of its own kind there.
    #: (untyped, Hash[String, Array[Symbol]]) -> void
    def place(reflection, kinds)
      kind = reflection.through_reflection? ? :through : reflection.macro
      models = reflection.through_reflection? ? reflection.chain.map(&:klass) : [reflection.klass]
      models.each do |model|
        name = model.base_class.name
        kinds[name] = kinds.fetch(name) { [] } | [kind]
      end
    end
  end
end
