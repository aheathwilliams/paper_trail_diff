# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Finds records in a collection held in type, then ID, order, as an
  # association snapshot holds its records, by searching that order. A table
  # of every record's position would be built again for each event that
  # changed who is in the collection, which made a replay's time grow with
  # its events times the collection's size.
  class CollectionIdentityIndex
    # A search builds a sort key for each record it looks at, so a collection
    # of up to this many records is quicker to read through. Most nested
    # collections are that small, and a tree is looked through for each event.
    READ_THROUGH = 8

    #: (Array[RecordSnapshot]) -> void
    def initialize(records)
      @records = records
      freeze
    end

    # Ids match by their text: a version's item_id can arrive as a string
    # where the record's id is an integer. The first match in the order is
    # the one found, however it is looked for.
    #: (untyped, untyped) -> Integer?
    def position(type, id)
      type = type.to_s
      text = id.to_s
      if @records.length <= READ_THROUGH
        return @records.index { |record| match?(record, type, text) }
      end

      forms(id).each do |form|
        index = insertion(type, form)
        record = @records[index]
        return index if record && match?(record, type, text)
      end
      nil
    end

    # The position of the only record with this id, whatever its type.
    #: (untyped) -> Integer?
    def position_for_id(id)
      found = nil #: Integer?
      each_type do |type|
        index = position(type, id)
        next unless index
        return if found

        found = index
      end
      found
    end

    # Where a record of this type and id is, or would be put to keep the order.
    #: (untyped, untyped) -> Integer
    def insertion(type, id)
      key = Support.sortable_identity(type, id)
      @records.bsearch_index do |record|
        (Support.sortable_identity(record.type, record.id) <=> key).to_i >= 0
      end || @records.length
    end

    private

    # @rbs @records: Array[RecordSnapshot]

    #: (RecordSnapshot, String, String) -> bool
    def match?(record, type, text)
      record.type == type && record.id.to_s == text
    end

    # The values an id of this text may be held as, the number first, as
    # records sort a number before the string that prints like it.
    #: (untyped) -> Array[untyped]
    def forms(id)
      case id
      when Numeric then [id, id.to_s]
      when String, Symbol then [Integer(id.to_s, 10, exception: false), id].compact
      else [id]
      end
    end

    # Each type the collection holds, found by searching for where the next begins.
    #: () { (String) -> void } -> void
    def each_type
      index = 0
      while index < @records.length
        type = @records.fetch(index).type
        yield type
        index = @records.bsearch_index { |record| record.type > type } || @records.length
      end
    end
  end
end
