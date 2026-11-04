# frozen_string_literal: true

# What a diff says, read back from its `to_h` alone, for the comparison
# properties. Snapshots are their `to_h` hashes here too. Nothing here calls
# the engine, so a property that holds is not the engine agreeing with itself.
module DiffAlgebra
  module_function

  # The snapshot the diff leads to from `from`.
  def apply(from, diff)
    presence = diff.fetch(:record_presence_change)
    return presence.fetch(:to) if presence
    return unless from

    apply_record(from, diff.fetch(:attributes), diff.fetch(:associations))
  end

  # The diff of the same snapshots compared the other way.
  def invert(diff)
    presence = diff.fetch(:record_presence_change)
    {
      record_presence_change: presence && swap(presence),
      attributes: invert_attributes(diff.fetch(:attributes)),
      associations: invert_associations(diff.fetch(:associations))
    }
  end

  # A snapshot without what the engine treats as no difference: an attribute
  # that is nil is one that is missing, and so is an association with no
  # records.
  def normalize(record)
    return unless record

    associations = record.fetch(:associations, {}).filter_map do |name, association|
      records = association.fetch(:records).map { |member| normalize(member) }
      [name, sort(records)] unless records.empty?
    end
    { type: record.fetch(:type), id: record.fetch(:id),
      attributes: record.fetch(:attributes).compact, associations: associations.sort.to_h }
  end

  # Record type, then ID: numerically for numbers, by text otherwise.
  def order_key(record)
    id = record.fetch(:id)
    [record.fetch(:type), id.is_a?(Numeric) ? [0, id] : [1, id.to_s]]
  end

  def sort(records)
    records.sort_by { |record| order_key(record) }
  end

  def identity(record)
    [record.fetch(:type), record.fetch(:id)]
  end

  def swap(change)
    { from: change.fetch(:to), to: change.fetch(:from) }
  end

  def apply_record(record, attributes, associations)
    edited = record.fetch(:attributes).dup
    attributes.each { |name, change| edited[name] = change.fetch(:to) }
    members = record.fetch(:associations, {}).dup
    associations.each do |name, change|
      members[name] = apply_association(members[name], change)
    end
    record.merge(attributes: edited, associations: members)
  end

  def apply_association(association, change)
    records = association ? association.fetch(:records) : []
    records = change.key?(:relationship) ? to_one(records, change) : collection(records, change)
    { kind: change.fetch(:kind), records: records }
  end

  def to_one(records, change)
    relationship = change.fetch(:relationship)
    return [relationship.fetch(:to)].compact if relationship

    [apply_change(records.fetch(0), change.fetch(:changed))]
  end

  def collection(records, change)
    removed = change.fetch(:removed).map { |record| identity(record) }
    changed = change.fetch(:changed).to_h do |record_change|
      [identity(record_change.fetch(:record)), record_change]
    end
    kept = records.reject { |record| removed.include?(identity(record)) }.map do |record|
      record_change = changed[identity(record)]
      record_change ? apply_change(record, record_change) : record
    end
    sort(kept + change.fetch(:added))
  end

  def apply_change(record, change)
    unless identity(record) == identity(change.fetch(:record))
      raise ArgumentError, "a change to #{change.fetch(:record)} was applied to #{identity(record)}"
    end

    apply_record(record, change.fetch(:attributes), change.fetch(:associations, {}))
  end

  def invert_attributes(attributes)
    attributes.transform_values { |change| swap(change) }
  end

  def invert_associations(associations)
    associations.transform_values do |change|
      next invert_collection(change) unless change.key?(:relationship)

      relationship = change.fetch(:relationship)
      changed = change.fetch(:changed)
      { kind: change.fetch(:kind), relationship: relationship && swap(relationship),
        changed: changed && invert_change(changed) }
    end
  end

  def invert_collection(change)
    { kind: change.fetch(:kind), added: change.fetch(:removed), removed: change.fetch(:added),
      changed: change.fetch(:changed).map { |record_change| invert_change(record_change) } }
  end

  def invert_change(change)
    inverted = { record: change.fetch(:record),
                 attributes: invert_attributes(change.fetch(:attributes)) }
    associations = change.fetch(:associations, nil)
    inverted[:associations] = invert_associations(associations) if associations
    inverted
  end

  # What a diff reports that is no change, or is out of order: an attribute
  # with the same value both sides, an empty change, a record added that was
  # there or removed that stayed, keys or records out of order.
  module Problems
    module_function

    def of(diff, from, to)
      return [] if diff.fetch(:record_presence_change)

      record(diff.fetch(:attributes), diff.fetch(:associations), from, to, 'record')
    end

    def record(attributes, associations, from, to, path)
      problems = attribute_problems(attributes, path)
      problems << "#{path} associations out of order" unless sorted?(associations.keys)
      associations.each do |name, change|
        members = [from, to].map { |side| side.dig(:associations, name, :records) || [] }
        problems.concat(association(change, *members, "#{path}.#{name}"))
      end
      problems
    end

    def attribute_problems(attributes, path)
      unchanged = attributes.select { |_name, change| change.fetch(:from) == change.fetch(:to) }
      problems = unchanged.keys.map { |name| "#{path}.#{name} did not change" }
      sorted?(attributes.keys) ? problems : ["#{path} attributes out of order", *problems]
    end

    def association(change, from, to, path)
      return to_one(change, from.first, to.first, path) if change.key?(:relationship)

      problems = []
      problems << "#{path} is an empty change" if %i[added removed changed].all? do |key|
        change.fetch(key).empty?
      end
      problems.concat(members(change, from, to, path))
      problems.concat(changes(change.fetch(:changed), from, to, path))
    end

    def members(change, from, to, path)
      held = [from, to].map { |side| side.map { |record| DiffAlgebra.identity(record) } }
      problems = %i[added removed changed].filter_map do |key|
        listed = change.fetch(key).map { |item| item.fetch(:record, item) }
        "#{path} #{key} out of order" unless listed == DiffAlgebra.sort(listed)
      end
      problems + misplaced(change, *held, path)
    end

    def misplaced(change, from, to, path)
      added = change.fetch(:added).map { |record| DiffAlgebra.identity(record) }
      removed = change.fetch(:removed).map { |record| DiffAlgebra.identity(record) }
      changed = change.fetch(:changed).map { |item| DiffAlgebra.identity(item.fetch(:record)) }
      [*(added & from).map { |identity| "#{path} added #{identity}, which was there" },
       *(removed & to).map { |identity| "#{path} removed #{identity}, which stayed" },
       *(changed - (from & to)).map { |identity| "#{path} changed #{identity}, not on both sides" }]
    end

    def changes(record_changes, from, to, path)
      record_changes.flat_map do |change|
        identity = DiffAlgebra.identity(change.fetch(:record))
        before = from.find { |record| DiffAlgebra.identity(record) == identity }
        after = to.find { |record| DiffAlgebra.identity(record) == identity }
        record_change(change, before, after, "#{path}[#{identity.join(' ')}]")
      end
    end

    def record_change(change, before, after, path)
      attributes = change.fetch(:attributes)
      associations = change.fetch(:associations, {})
      return ["#{path} is an empty change"] if attributes.empty? && associations.empty?
      return [] unless before && after

      record(attributes, associations, before, after, path)
    end

    def to_one(change, from, to, path)
      relationship = change.fetch(:relationship)
      changed = change.fetch(:changed)
      return ["#{path} is an empty change"] if relationship.nil? && changed.nil?
      return ["#{path} reports a replacement and an edit"] if relationship && changed
      return replaced(from, to, path) if relationship

      edited(changed, from, to, path)
    end

    def replaced(from, to, path)
      same_record?(from, to) ? ["#{path} replaced a record by itself"] : []
    end

    def edited(change, from, to, path)
      return ["#{path} changed records of different identities"] unless same_record?(from, to)

      record_change(change, from, to, path)
    end

    def same_record?(from, to)
      !from.nil? && !to.nil? && DiffAlgebra.identity(from) == DiffAlgebra.identity(to)
    end

    def sorted?(names)
      names == names.sort
    end
  end
end
