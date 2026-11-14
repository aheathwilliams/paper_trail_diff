# frozen_string_literal: true

# Random snapshots for the comparison properties
# (spec/unit/engine_properties_spec.rb and the specs beside it). They are built
# directly, as the PaperTrail integration hands them to the engine, so no
# database is involved and a few hundred cases take well under a second.
module SnapshotCases
  SIZES = 6

  # Yields a Random and a size for each case, with a label that reproduces it.
  # Sizes grow from 0, so the first case that fails is about as small as a
  # failing case gets. PROPERTY_SEED and PROPERTY_CASES change the cases.
  def self.each
    seed = Integer(ENV.fetch('PROPERTY_SEED', 1))
    count = Integer(ENV.fetch('PROPERTY_CASES', 200))
    count.times do |index|
      size = index * SIZES / count
      yield Random.new((seed * 1_000_000) + index), size,
            "PROPERTY_SEED=#{seed} PROPERTY_CASES=#{count}: case #{index} (size #{size})"
    end
  end

  # Builds record snapshots and edited copies of them. A record holds a few of
  # ATTRIBUTES and, two levels deep, the associations SHAPES gives its type.
  class Generator
    SHAPES = {
      'Article' => {
        'author' => [:belongs_to, %w[Author]],
        'profile' => [:has_one, %w[Profile]],
        'comments' => [:has_many, %w[Comment]],
        'tags' => [:has_many, %w[Tag]],
        'items' => [:has_many, %w[Comment Note]]
      },
      'Comment' => {
        'reviewer' => [:belongs_to, %w[Author]],
        'replies' => [:has_many, %w[Reply]]
      }
    }.freeze
    # Tags and notes have string ids, so a collection can mix id types.
    STRING_IDS = %w[Tag Note].freeze
    ATTRIBUTES = %w[title body count flag meta list].freeze
    VALUES = [nil, true, false, 0, 1, 2, 1.5, 'a', 'b', '', { 'x' => 1 },
              { 'x' => { 'y' => nil } }, %w[a b], []].freeze
    DEPTH = 2

    def initialize(random, size)
      @random = random
      @size = size
    end

    def root
      record('Article', 1, 0)
    end

    # An edit of `snapshot` at every depth: attributes changed, added and
    # removed; to-one records edited, replaced and removed; collection
    # members edited, added and removed, sometimes as the one-record
    # transition activity carries forward. Untouched records are kept or
    # rebuilt equal. Now and then the record itself goes or comes.
    def edit(snapshot)
      return root if snapshot.nil? && chance?(0.5)
      return if snapshot.nil? || chance?(0.05)

      edit_record(snapshot, 0)
    end

    # An equal snapshot built afresh, with no object or transition shared and
    # its keys and records given in a random order.
    def copy(snapshot)
      return unless snapshot

      associations = shuffled(snapshot.associations).to_h do |name, association|
        records = association.records.map { |record| copy(record) }.shuffle(random: @random)
        [name, PaperTrailDiff::AssociationSnapshot.new(kind: association.kind, records: records)]
      end
      PaperTrailDiff::RecordSnapshot.new(type: snapshot.type, id: snapshot.id,
                                         attributes: shuffled(snapshot.attributes).to_h,
                                         associations: associations)
    end

    private

    def chance?(probability)
      @random.rand < probability
    end

    def shuffled(hash)
      hash.to_a.shuffle(random: @random)
    end

    def record(type, id, depth)
      PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: attributes,
                                         associations: associations(type, depth))
    end

    def attributes
      count = @random.rand(0..[@size, ATTRIBUTES.length].min)
      ATTRIBUTES.sample(count, random: @random).to_h { |name| [name, value] }
    end

    def value
      VALUES.sample(random: @random)
    end

    def associations(type, depth)
      return {} if depth >= DEPTH

      SHAPES.fetch(type, {}).each_with_object({}) do |(name, (kind, types)), associations|
        next if chance?(0.25)

        associations[name] = association(kind, members(kind, types, depth))
      end
    end

    def association(kind, records)
      PaperTrailDiff::AssociationSnapshot.new(kind: kind, records: records)
    end

    def members(kind, types, depth, taken: [])
      count = collection?(kind) ? @random.rand(0..@size) : @random.rand(0..1)
      identities(types, taken).sample(count, random: @random).map do |type, id|
        record(type, id, depth + 1)
      end
    end

    # Identities of the given types not among `taken`.
    def identities(types, taken)
      numbers = (1..(@size + 2)).to_a
      types.product(numbers).map { |type, number| [type, id(type, number)] } - taken
    end

    def id(type, number)
      STRING_IDS.include?(type) ? "#{type[0].downcase}#{number}" : number
    end

    def collection?(kind)
      PaperTrailDiff::AssociationSnapshot.collection_kind?(kind)
    end

    def edit_record(snapshot, depth)
      PaperTrailDiff::RecordSnapshot.new(type: snapshot.type, id: snapshot.id,
                                         attributes: edit_attributes(snapshot.attributes),
                                         associations: edit_associations(snapshot, depth))
    end

    def edit_attributes(attributes)
      ATTRIBUTES.each_with_object(attributes.dup) do |name, edited|
        next unless chance?(0.3)

        chance?(0.3) ? edited.delete(name) : edited[name] = value
      end
    end

    def edit_associations(snapshot, depth)
      return snapshot.associations if depth >= DEPTH

      SHAPES.fetch(snapshot.type, {}).each_with_object(snapshot.associations.dup) do |shape, edited|
        name, (kind, types) = shape
        next if chance?(0.4)
        next edited.delete(name) if chance?(0.1)

        from = edited[name] || association(kind, [])
        edited[name] = edit_association(from, kind, types, depth)
      end
    end

    def edit_association(from, kind, types, depth)
      return edit_to_one(from, types, depth) unless collection?(kind)
      return transition(from, types, depth) if chance?(0.3)

      kept = from.records.reject { chance?(0.25) }.map { |member| edit_member(member, depth) }
      taken = from.records.map(&:identity)
      association(kind, kept + members(kind, types, depth, taken: taken).first(2))
    end

    def edit_to_one(from, types, depth)
      current = from.records.first
      replacement = case @random.rand(4)
                    when 0 then nil
                    when 1 then current && edit_record(current, depth + 1)
                    when 2 then members(from.kind, types, depth, taken: [current&.identity]).first
                    else current
                    end
      association(from.kind, [replacement].compact)
    end

    def edit_member(member, depth)
      return edit_record(member, depth + 1) if chance?(0.4)

      chance?(0.5) ? member : copy(member)
    end

    # One record updated, added or removed, as activity carries a collection
    # forward from one event to the next.
    def transition(from, types, depth)
      records = from.records
      before = records.sample(random: @random)
      return add(from, types, depth) if before.nil? || chance?(0.3)

      return from.transition_to(records - [before], before: before, after: nil) if chance?(0.5)

      after = edit_record(before, depth + 1)
      from.transition_to(records.map { |record| record.equal?(before) ? after : record },
                         before: before, after: after)
    end

    def add(from, types, depth)
      after = members(:has_many, types, depth, taken: from.records.map(&:identity)).first
      return from unless after

      from.transition_to(in_order(from.records + [after]), before: nil, after: after)
    end

    # A transition's records come in the order a snapshot holds them in.
    def in_order(records)
      records.sort_by { |record| PaperTrailDiff::Support.sortable_identity(record.type, record.id) }
    end
  end

  # Values a json or jsonb column holds, with string keys as JSON gives them
  # back, and edited copies of them. Keys include a dotted one and an empty
  # one; array elements can repeat.
  class Json
    KEYS = ['a', 'b', 'c', 'a.b', ''].freeze
    SCALARS = [nil, true, false, 0, 1, -2, 2.5, 'a', 'b', ''].freeze
    ELEMENTS = [nil, true, 0, 1, 'a', 'b', { 'k' => 1 }, { 'k' => 'a' }, ['a']].freeze
    DEPTH = 3

    def initialize(random, size)
      @random = random
      @size = size
    end

    # A Hash, or now and then an Array, as a column's whole value.
    def column
      @random.rand < 0.2 ? array : object(0)
    end

    # The value with keys, elements and nested values changed, added and
    # removed. Its outermost Hash or Array stays one.
    def edit(value, depth = 0)
      case value
      when Hash then edit_object(value, depth)
      when Array then edit_array(value)
      else chance?(0.5) ? nested(depth) : value
      end
    end

    private

    def chance?(probability)
      @random.rand < probability
    end

    def object(depth)
      KEYS.sample(@random.rand(0..[@size, KEYS.length].min), random: @random)
          .to_h { |key| [key, nested(depth + 1)] }
    end

    def nested(depth)
      roll = @random.rand
      return object(depth) if roll < 0.25 && depth < DEPTH
      return array if roll < 0.45

      SCALARS.sample(random: @random)
    end

    def array
      Array.new(@random.rand(0..@size)) { ELEMENTS.sample(random: @random) }
    end

    def edit_object(value, depth)
      KEYS.each_with_object(value.dup) do |key, edited|
        next unless chance?(0.4)
        next edited.delete(key) if chance?(0.25)

        edited[key] = edited.key?(key) ? edit(edited[key], depth + 1) : nested(depth + 1)
      end
    end

    def edit_array(value)
      case @random.rand(4)
      when 0 then value.shuffle(random: @random)
      when 1 then value + [ELEMENTS.sample(random: @random)]
      when 2 then value.reject { chance?(0.4) }
      else value
      end
    end
  end
end
