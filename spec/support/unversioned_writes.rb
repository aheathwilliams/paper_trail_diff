# frozen_string_literal: true

require_relative 'oracle'

# Change rows against the writes that made them, for spec/oracle/
# unversioned_writes_spec.rb. A seeded history mixes saves, which write
# versions, with `update_columns` writes, which do not, several of them to a
# transaction, and records every write.
module UnversionedWrites
  Write = Struct.new(:key, :field, :before, :after, :version, :transaction, keyword_init: true)

  # The article, its comments and three authors, edited at random.
  class History
    OPERATIONS = %i[edit_root write_root create_comment edit_comment write_comment
                    destroy_comment edit_author write_author set_author].freeze
    AUTHORS = [nil, 'alice', 'bob'].freeze

    attr_reader :article, :writes

    def initialize(seed, steps:)
      @random = Random.new(seed)
      @steps = steps
      @writes = []
      @counter = 0
    end

    def build
      PaperTrail.request(whodunnit: 'setup') do
        @authors = Array.new(3) { created(TrackedAuthor.create!(name: next_value('name')), 'name') }
        @article = created(TrackedArticle.create!(title: 'start'), 'title')
        2.times { created(@article.comments.create!(body: next_value('body')), 'body') }
      end
      @steps.times { |index| transaction(index) }
      self
    end

    def self.key(record)
      [record.class.base_class.name, record.id.to_s]
    end

    private

    # Records are read afresh for each transaction and kept within it, so a
    # save reads what an earlier write in it left.
    def transaction(index)
      @transaction = index
      PaperTrail.request(whodunnit: AUTHORS.fetch(index % AUTHORS.length)) do
        ActiveRecord::Base.transaction do
          root = TrackedArticle.find(@article.id)
          comments = root.comments.order(:id).to_a
          (1 + @random.rand(3)).times { operate(root, comments) }
        end
      end
    end

    def operate(root, comments)
      operation = OPERATIONS.sample(random: @random)
      return edit_comments(operation, root, comments) if operation.to_s.end_with?('comment')

      author = TrackedAuthor.find(@authors.sample(random: @random).id)
      case operation
      when :edit_root then save(root, 'title', next_value('title'))
      when :write_root then write(root, *root_column)
      when :edit_author then save(author, 'name', next_value('name'))
      when :write_author then write(author, 'name', next_value('name'))
      else save(root, 'author_id', author.id)
      end
    end

    def edit_comments(operation, root, comments)
      comment = comments.sample(random: @random)
      case operation
      when :create_comment
        comments << created(root.comments.create!(body: next_value('body')), 'body')
      when :edit_comment then comment && save(comment, *comment_column)
      when :write_comment then comment && write(comment, *comment_column)
      else destroy(comment, comments)
      end
    end

    def root_column
      return ['title', next_value('title')] if @random.rand(2).zero?

      ['author_id', @authors.sample(random: @random).id]
    end

    def comment_column
      @random.rand(2).zero? ? ['body', next_value('body')] : ['reviewer_id', @random.rand(1..4)]
    end

    # A create records the field it sets; the others keep their defaults,
    # which no version records.
    def created(record, field)
      log(record, field, nil, record[field], record.versions.reorder(:created_at, :id).last.id)
      record
    end

    # A save that changes nothing writes no version, nor a write.
    def save(record, field, value)
      before = record[field]
      return if before == value

      record.update!(field => value)
      log(record, field, before, value, record.versions.reorder(:created_at, :id).last.id)
    end

    def write(record, field, value)
      log(record, field, record[field], value, nil)
      record.update_columns(field => value)
    end

    def destroy(comment, comments)
      return unless comment

      comment.destroy!
      comments.delete(comment)
      log(comment, nil, nil, nil, nil)
    end

    def log(record, field, before, after, version)
      @writes << Write.new(key: self.class.key(record), field: field, before: before, after: after,
                           version: version, transaction: @transaction)
    end

    def next_value(prefix)
      @counter += 1
      "#{prefix}-#{@counter}"
    end
  end

  # Checks a timeline's change rows against the history's writes:
  #
  # 1. A field's rows chain from the value the step's diff starts at to the
  #    one it ends at, so splitting a change loses none of it.
  # 2. A row credited to a version ends at a value that version recorded,
  #    unless `strict` is off.
  # 3. A row credited to no version ends at a value an `update_columns` wrote.
  # 4. A write without a version whose value is read again has a row of its
  #    own (see #read_writes).
  class RowCheck
    # `structural` names the columns the requested associations read as
    # relationships rather than fields, which have no rows.
    def initialize(history, failures, label, strict:, structural: [])
      @history = history
      @failures = failures
      @label = label
      @strict = strict
      @structural = structural
    end

    def call(steps)
      steps.each_with_index do |step, index|
        rows = step.change_rows
        whole = PaperTrailDiff::ChangeRows.call(step.diff, source: step.source_boundary)
        chained(index, rows, whole)
        rows.each { |row| credited(index, row) }
      end
    end

    def complete(rows)
      shown = rows.select(&:unversioned?).map { |row| [identity(row), row.attribute, row.to] }
      read_writes.each do |write|
        next if shown.include?([write.key, write.field, write.after])

        @failures.add("#{@label}: write without a version has no row", write.to_h)
      end
    end

    private

    def identity(row)
      record = row.record
      return History.key(@history.article) unless record

      [PaperTrailDiff::Support.constant(record.type).base_class.name, record.id.to_s]
    end

    def chained(index, rows, whole)
      split = rows.group_by { |row| field(row) }
      whole.select(&:attribute).each do |row|
        parts = split.fetch(field(row), [])
        next if chain?(row, parts)

        @failures.add("#{@label} step #{index}: rows do not chain into the change",
                      { whole: row.to_h, parts: parts.map(&:to_h) })
      end
    end

    def field(row)
      [row.association_path, row.record&.to_h, row.attribute]
    end

    # The first part keeps the change's kind, the rest edit what it left.
    def chain?(row, parts)
      kinds = parts.map(&:change)
      return false unless kinds == [row.change] + ([:changed] * (kinds.length - 1))

      ends = [parts.first.from, parts.last.to]
      ends == [row.from, row.to] && parts.each_cons(2).all? { |left, right| left.to == right.from }
    end

    def credited(index, row)
      return if row.attribute.nil? || row.change == :removed || default?(row) || joined?(row)

      if row.unversioned?
        unversioned(index, row)
      elsif @strict
        recorded(index, row)
      end
    end

    # A field its create left at the default holds a value no version
    # recorded, which may be the default or a later write: the row stays
    # credited to the create.
    def default?(row)
      source = row.source
      row.change == :added && source.event == 'create' &&
        !source.recorded_changes&.key?(row.attribute)
    end

    # The fields of a record that joined an association other than by its own
    # create are its state, credited to the step's source.
    def joined?(row)
      source = row.source
      row.change == :added && !row.unversioned? &&
        (source.event != 'create' || [source.item_type, source.item_id.to_s] != identity(row))
    end

    def unversioned(index, row)
      return if @history.writes.any? do |write|
        write.version.nil? && write.key == identity(row) && write.field == row.attribute &&
        write.after == row.to
      end

      @failures.add("#{@label} step #{index}: unversioned row matches no write", row.to_h)
    end

    def recorded(index, row)
      source = row.source
      change = source.recorded_changes&.fetch(row.attribute, nil)
      return if [source.item_type, source.item_id.to_s] == identity(row) && change&.to == row.to

      @failures.add("#{@label} step #{index}: row is not what its version recorded",
                    { row: row.to_h, recorded: change&.to_h })
    end

    # Writes without a version to the article and its comments whose value
    # the record's next save of the field reads, or the current row does,
    # with nothing written to the record in between. An author is in the tree
    # only while it is the article's, so its writes are not sure to be read.
    def read_writes
      writes = @history.writes
      writes.each_with_index.filter_map do |write, index|
        next unless candidate?(write) && !hidden(writes.first(index), write).include?(write.after)

        later = writes.drop(index + 1).find { |other| other.key == write.key }
        write if later.nil? ? exists?(write.key) : read?(write, later)
      end
    end

    def candidate?(write)
      write.version.nil? && !@structural.include?(write.field) &&
        %w[TrackedArticle TrackedComment].include?(write.key.first)
    end

    # The values a write back to shows nothing. Rows follow each step's
    # diff, and a step can start before every change its transaction
    # recorded of the field, so these are every value the field had in the
    # transaction that last recorded it. A field no version recorded is one
    # its create left at the default, which can read as the create's.
    def hidden(earlier, write)
      recorded = earlier.select { |other| recorded?(other, write) }
      last = recorded.last
      return [write.after] unless last

      recorded.select { |other| other.transaction == last.transaction }.map(&:before) << last.after
    end

    def recorded?(earlier, write)
      earlier.version && earlier.key == write.key && earlier.field == write.field
    end

    def read?(write, later)
      later.version && later.field == write.field && later.after != write.after
    end

    def exists?(key)
      @history.writes.none? { |write| write.key == key && write.field.nil? }
    end
  end

  # Checks the net changes of a timeline (see PaperTrailDiff::NetChanges):
  #
  # 1. With every row kept, they are the timeline's own states (see
  #    NetChangesCheck).
  # 2. With only the rows of versions kept, over the whole history, an
  #    article or comment still there ends at the value its last save with a
  #    version gave each field, where a row shows that save's change. A write
  #    without a version can undo the save within its step, which then shows
  #    no row (see RowCheck), and a field no save recorded holds what its
  #    create left, which can be a later write (see RowCheck#default?).
  class NetCheck
    CHECKED = %w[TrackedArticle TrackedComment].freeze

    def initialize(history, failures, label, strict:, structural: [])
      @history = history
      @failures = failures
      @label = label
      @strict = strict
      @structural = structural
    end

    def call(steps)
      NetChangesCheck.check(@failures, @label, steps)
      recorded(steps) if @strict
    end

    private

    def recorded(steps)
      listed = PaperTrailDiff::NetChanges.call(steps, ->(row) { !row.unversioned? })
                                         .to_h { |change| [identity(change), change] }
      shown = shown_saves(steps)
      live.each do |key|
        after = listed[key]&.after
        next @failures.add("#{@label}: a record still there has no state after", key) unless after

        fields(key).each { |field| recorded_field(key, field, after, shown) }
      end
    end

    # Each record, field, and version a row is credited to.
    def shown_saves(steps)
      steps.flat_map(&:change_rows).map do |row|
        [identity(row), row.attribute, row.source.version_id]
      end
    end

    def recorded_field(key, field, after, shown)
      last = @history.writes.reverse.find do |write|
        write.version && write.key == key && write.field == field
      end
      return unless last && shown.include?([key, field, last.version])
      return if after.attributes[field] == last.after

      @failures.add("#{@label}: a field does not end at its last recorded value",
                    { record: key, field: field, after: after.attributes[field],
                      recorded: last.after })
    end

    # The articles and comments the history created and did not destroy.
    def live
      keys = @history.writes.map(&:key).uniq.select { |key| CHECKED.include?(key.first) }
      keys.reject { |key| @history.writes.any? { |write| write.key == key && write.field.nil? } }
    end

    def fields(key)
      written = @history.writes.select { |write| write.key == key }.map(&:field)
      written.compact.uniq - @structural
    end

    # The history's key for the record a change or row is about.
    def identity(item)
      record = item.record
      return History.key(@history.article) unless record

      [PaperTrailDiff::Support.constant(record.type).base_class.name, record.id.to_s]
    end
  end
end
