# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::TransactionCut do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  def at(minute)
    start_time + (minute * 60)
  end

  # A create and two updates at minutes 0, 1, and 2, each in its own
  # transaction unless `transactions` names one.
  def history(model = FilterArticle, transactions: {})
    article = model.create!(title: 'Draft')
    %w[Review Published].each { |title| article.update!(title: title) }
    versions = FilterVersion.where(item_id: article.id, item_type: 'FilterArticle').order(:id).to_a
    versions.each_with_index do |version, minute|
      version.update_columns(created_at: at(minute), transaction_id: transactions[minute])
    end
    [article, *versions]
  end

  # Another record's version saved in a transaction, as a child's would be.
  def other(minute, transaction, type: 'FilterNote')
    FilterVersion.insert({ item_type: type, item_id: 1, event: 'update',
                           created_at: at(minute), transaction_id: transaction })
  end

  # Requested paths that reach the records of `types` from `model`.
  def paths(model, types)
    instance_double(PaperTrailDiff::AssociationTraversal).tap do |traversal|
      allow(traversal).to receive(:path_types).with(model).and_return(types)
    end
  end

  # The requested paths reach the notes `other` saves, unless `types` says
  # which records they reach.
  def windows(records, within, types: ['FilterNote'])
    model = records.first.class
    moved = described_class.windows(model, records, PaperTrailDiff::TimeRange.new(within),
                                    traversal: paths(model, types))
    moved.transform_values { |range| [range.begin_time, range.end_time, range.exclude_end?] }
  end

  describe '.windows' do
    it 'moves nothing for no ids' do
      expect(described_class.windows(FilterArticle, [], PaperTrailDiff::TimeRange.new(at(0)..at(1))))
        .to eq({})
    end

    it 'moves nothing when versions have no transaction column' do
      version_class = class_double(FilterVersion, column_names: %w[id created_at])
      model = class_double(FilterArticle, paper_trail: double(version_class: version_class))

      expect(described_class.windows(model, [Object.new], PaperTrailDiff::TimeRange.new(at(0)..at(1))))
        .to eq({})
    end

    it 'moves nothing for versions saved outside transactions' do
      article, = history
      other(0.5, nil)

      expect(windows([article], at(0.75)..at(1.5))).to eq({})
    end

    it 'moves a start back to a transaction that saved a root version after it' do
      article, = history(transactions: { 1 => 7 })
      other(0.5, 7)

      expect(windows([article], at(0.75)..at(1.5)))
        .to eq(article.id.to_s => [at(0.5), at(1.5), false])
    end

    it 'moves a start back to a transaction that saved a root version before it' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(1.25)...at(2)))
        .to eq(article.id.to_s => [at(1), at(2), true])
    end

    # The root's change is then in the earlier window, where its version is.
    it 'leaves a start where a transaction saved the root before it and nothing on its paths' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7, type: 'FilterArticle')
      other(1.6, 7, type: 'FilterOther')
      within = at(1.25)...at(2)

      expect([windows([article], within), windows([article], within, types: [])]).to eq([{}, {}])
    end

    it 'moves a start back to where a transaction that saved the root before it began' do
      article, = history(transactions: { 1 => 7 })
      other(0.9, 7)
      other(1.5, 7)

      expect(windows([article], at(1.25)..at(3)))
        .to eq(article.id.to_s => [at(0.9), at(3), false])
    end

    it 'moves a start to the earlier of the transactions on either side of it' do
      article, _, review, published = history(transactions: { 1 => 7, 2 => 8 })
      published.update_columns(created_at: at(1.5))
      other(0.9, 7)
      other(1.6, 7)
      other(1.1, 8)

      expect(windows([article], at(1.25)..at(3)))
        .to eq(article.id.to_s => [at(0.9), at(3), false])
      expect(review.transaction_id).to eq(7)
    end

    it 'moves each root back to the start of its own transaction after the edge, in one batch' do
      article, = history(transactions: { 1 => 7 })
      later, = history(transactions: { 1 => 8 })
      other(0.5, 7)
      other(0.6, 8)

      expect(windows([article, later], at(0.75)..at(3)))
        .to eq(article.id.to_s => [at(0.5), at(3), false], later.id.to_s => [at(0.6), at(3), false])
    end

    it 'reads no transaction before an edge when the paths reach nothing' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)
      statements = []
      counter = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }

      moved = ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        windows([article], at(1.25)..at(3), types: [])
      end

      expect([moved, statements.length]).to eq([{}, 2])
    end

    it 'moves a start back to a transaction that saved the root after it, whatever the paths' do
      article, = history(transactions: { 1 => 7 })
      other(0.5, 7, type: 'FilterOther')

      expect(windows([article], at(0.75)..at(1.5), types: []))
        .to eq(article.id.to_s => [at(0.5), at(1.5), false])
    end

    it 'leaves a start where a transaction ended before it' do
      article, = history(transactions: { 1 => 7 })
      other(0.5, 7)

      expect(windows([article], at(1.25)..at(2))).to eq({})
    end

    it 'leaves a start where a transaction began at it' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(1)..at(2))).to eq({})
    end

    it 'moves a start at a later version of a transaction to its first' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(1.5)..at(2)))
        .to eq(article.id.to_s => [at(1), at(2), false])
    end

    it 'ends an inclusive end inside a transaction before it' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(0)..at(1.25)))
        .to eq(article.id.to_s => [at(0), at(1), true])
    end

    it 'keeps an inclusive end at the last version of a transaction' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(0)..at(1.5))).to eq({})
    end

    it 'ends an exclusive end at the last version of a transaction before it' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(0)...at(1.5)))
        .to eq(article.id.to_s => [at(0), at(1), true])
    end

    it 'moves an edge to the earlier of two transactions crossing it' do
      article, = history(transactions: { 1 => 7, 2 => 8 })
      other(2.5, 7)
      other(0.5, 8)

      expect(windows([article], at(1.5)..at(3)))
        .to eq(article.id.to_s => [at(0.5), at(3), false])
    end

    it 'moves an edge to the earlier of two transactions crossing it, whichever is read first' do
      article, = history(transactions: { 1 => 8, 2 => 7 })
      other(2.5, 8)
      other(0.5, 7)

      expect(windows([article], at(1.5)..at(3)))
        .to eq(article.id.to_s => [at(0.5), at(3), false])
    end

    it 'ends an inclusive end at a root version inside a transaction before it' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(0)..at(1)))
        .to eq(article.id.to_s => [at(0), at(1), true])
    end

    it 'ends a window before its start when another transaction crosses its end earlier' do
      article, = history(transactions: { 1 => 7, 2 => 8 })
      other(0.7, 7)
      other(0.5, 8)

      expect(windows([article], at(0.75)...at(1.5)))
        .to eq(article.id.to_s => [at(0.7), at(0.7), true])
    end

    it "decides by the root's nearest versions, not older ones" do
      article, = history(transactions: { 0 => 6 })
      other(1.5, 6)

      expect(windows([article], at(1.25)..at(3))).to eq({})
    end

    it 'matches transactions an adapter returns as text' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)
      connection = FilterVersion.connection
      allow(connection).to receive(:select_rows).and_wrap_original do |original, *args|
        original.call(*args).map { |row| row.map(&:to_s) }
      end

      expect(windows([article], at(1.25)..at(3)))
        .to eq(article.id.to_s => [at(1), at(3), false])
    end

    # SQLite reads a scalar subquery's first row where PostgreSQL refuses to,
    # so the SQL itself is checked.
    describe 'the lookups' do
      def lookups(model, records)
        sql = []
        connection = model.paper_trail.version_class.connection
        allow(connection).to receive(:select_rows).and_wrap_original do |original, query, *rest|
          sql << connection.to_sql(query)
          original.call(query, *rest)
        end
        described_class.windows(model, records, PaperTrailDiff::TimeRange.new(at(0)..at(1)))
        sql.first
      end

      it 'reads one instant on each side of an edge' do
        article, = history

        sql = lookups(FilterArticle, [article])

        expect([sql.scan('MAX(').length, sql.scan('MIN(').length]).to eq([1, 1])
      end

      # The ids are named twice in each lookup, so 250 to a statement keeps it
      # under 1,000 bound parameters for SQLite builds before 3.32.
      it 'reads 250 records to a statement' do
        queries = []
        connection = FilterArticle.paper_trail.version_class.connection
        allow(connection).to receive(:select_rows).and_wrap_original do |original, query, *rest|
          queries << query
          original.call(query, *rest)
        end

        described_class.windows(FilterArticle, (1..500).to_a, PaperTrailDiff::TimeRange.new(at(0)..))

        expect(queries.length).to eq(2)
      end
    end

    it "ignores another model's versions with the same id" do
      article, = history
      FilterVersion.insert({ item_type: 'FilterNote', item_id: article.id, event: 'update',
                             created_at: at(1), transaction_id: 7 })
      other(1.5, 7)

      expect(windows([article], at(1.25)..at(3))).to eq({})
    end

    it 'reads the roots together, and no transactions when no root version near an edge has one' do
      roots = Array.new(2) { history.first }
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        windows(roots, at(0.5)..at(1.5))
      end

      expect(queries.length).to eq(2)
    end

    it 'moves both edges' do
      article, = history(transactions: { 0 => 6, 2 => 8 })
      other(0.5, 6)
      other(2.5, 8)

      expect(windows([article], at(0.25)..at(2.25)))
        .to eq(article.id.to_s => [at(0), at(2), true])
    end

    # The transaction that crosses the start began at minute 1, the instant
    # another saved the root, having begun before it.
    it 'moves a start again when where it moved to is inside another transaction' do
      article, = history(transactions: { 1 => 7, 2 => 8 })
      other(0.5, 7)
      other(1, 8)

      expect(windows([article], at(1.5)..at(3)))
        .to eq(article.id.to_s => [at(0.5), at(3), false])
    end

    it 'moves an end again when where it moved to is inside another transaction' do
      article, = history(transactions: { 1 => 7, 2 => 8 })
      other(0.5, 7)
      other(1, 8)

      expect(windows([article], at(0)..at(1.5)))
        .to eq(article.id.to_s => [at(0), at(0.5), true])
    end

    # A start that moved is read once more, from where it moved to, which
    # finds it settled.
    it 'moves only the start of an endless window, and reads for no end' do
      article, = history(transactions: { 0 => 6, 2 => 8 })
      other(0.5, 6)
      other(2.5, 8)
      statements = []
      counter = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }

      moved = ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        windows([article], at(0.25)..)
      end

      expect([moved, statements.length]).to eq([{ article.id.to_s => [at(0), nil, false] }, 4])
    end

    it 'leaves a window inside a transaction empty' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)

      expect(windows([article], at(1.1)..at(1.25)))
        .to eq(article.id.to_s => [at(1), at(1), true])
    end

    it 'moves only the roots whose transactions cross an edge' do
      article, = history(transactions: { 1 => 7 })
      unmoved, = history
      other(1.5, 7)

      expect(windows([article, unmoved], at(1.25)..at(3)).keys).to eq([article.id.to_s])
    end

    it "reads each root's own nearest versions in one batch" do
      article, = history(transactions: { 1 => 7 })
      later, _, review = history(transactions: { 1 => 8 })
      review.update_columns(created_at: at(1.1))
      other(1.5, 7)
      other(1.6, 8)

      expect(windows([article, later], at(1.25)..at(3)))
        .to eq(article.id.to_s => [at(1), at(3), false], later.id.to_s => [at(1.1), at(3), false])
    end

    it "does not read a root's older version at another root's nearest instant" do
      article, = history(transactions: { 0 => 7 })
      neighbour, _, review = history
      review.update_columns(created_at: at(0))
      other(1.75, 7)

      expect(windows([article, neighbour], at(1.5)..at(3))).to eq({})
    end

    it 'leaves a start where a transaction ended before it while another runs past it' do
      article, = history(transactions: { 1 => 7 })
      other(0.5, 7)
      other(1.5, 9)

      expect(windows([article], at(1.25)..at(2))).to eq({})
    end

    it 'reports each moved window, and only those, under the stored type' do
      feature, = history(FilterFeature, transactions: { 1 => 7 })
      unmoved, = history(FilterFeature)
      other(1.5, 7)
      events = []
      subscriber = ->(*, payload) { events << payload }

      ActiveSupport::Notifications.subscribed(subscriber, 'moved_window.paper_trail_diff') do
        windows([feature, unmoved], at(1.25)..at(3))
      end

      expect(events).to eq([{ item_type: 'FilterArticle', item_id: feature.id.to_s,
                              requested: at(1.25)..at(3), window: at(1)..at(3) }])
    end

    it 'moves the same windows unreported when told not to report them' do
      feature, = history(FilterFeature, transactions: { 1 => 7 })
      other(1.5, 7)
      range = PaperTrailDiff::TimeRange.new(at(1.25)..at(3))
      events = []
      subscriber = ->(*, payload) { events << payload }
      name = 'moved_window.paper_trail_diff'

      moved = ActiveSupport::Notifications.subscribed(subscriber, name) do
        described_class.windows(FilterFeature, [feature], range,
                                traversal: paths(FilterFeature, ['FilterNote']), report: false)
      end

      expect([moved.transform_values(&:to_range), events])
        .to eq([{ feature.id.to_s => at(1)..at(3) }, []])
    end

    it "does not move a root for another root's transaction" do
      article, = history
      FilterVersion.insert({ item_type: 'FilterArticle', item_id: article.id + 1, event: 'update',
                             created_at: at(1), transaction_id: 7 })
      other(1.5, 7)

      expect(windows([article], at(1.25)..at(3))).to eq({})
    end
  end

  describe '.reader' do
    it 'reads the windows of ids for a range by the paths it was given, unreported' do
      article, = history(transactions: { 1 => 7 })
      other(1.5, 7)
      range = PaperTrailDiff::TimeRange.new(at(1.25)..at(3))
      events = []
      subscriber = ->(*, payload) { events << payload }
      read = lambda do |types|
        reader = described_class.reader(FilterArticle, paths(FilterArticle, types))
        reader.call([article.id.to_s], range)
      end
      name = 'moved_window.paper_trail_diff'

      moved = ActiveSupport::Notifications.subscribed(subscriber, name) do
        [read.call([]), read.call(['FilterNote']).transform_values(&:to_range)]
      end

      expect([moved, events]).to eq([[{}, { article.id.to_s => at(1)..at(3) }], []])
    end
  end

  describe '.window_versions' do
    # The root's versions at 0 and 1, and at 2 in transaction 7, which saved a
    # note at 1.5; the window starts at 1.75.
    def selected(types, notes: { 1.5 => 7 }, range: at(1.75)..at(3))
      _, created, review, published = history(transactions: { 2 => 7 })
      review.update_columns(transaction_id: 6)
      notes.each { |minute, transaction| other(minute, transaction) }
      window = range && PaperTrailDiff::TimeRange.new(range)
      ids = described_class.window_versions(FilterArticle, window, types).pluck(:id)
      [created, review, published].map { |version| ids.include?(version.id) }
    end

    it 'selects every version without a window' do
      expect(selected(['FilterNote'], range: nil)).to eq([true, true, true])
    end

    it 'selects the versions in a window' do
      expect(selected([])).to eq([false, false, true])
    end

    # Its transaction moves the root's window back to take it in.
    it 'selects a version before a window in a transaction that saved its paths in it' do
      expect(selected(['FilterNote'], notes: { 1.5 => 7, 2.5 => 6 })).to eq([false, true, true])
    end

    it 'selects no version before a window for a record off the paths' do
      expect(selected(['FilterOther'], notes: { 2.5 => 6 })).to eq([false, false, true])
    end

    it 'selects no version before a window for a record on the paths after it' do
      expect(selected(['FilterNote'], notes: { 3.5 => 6 })).to eq([false, false, true])
    end

    it 'selects no version after a window, whatever its transaction saved in it' do
      _, _, review = history(transactions: { 1 => 6 })
      review.update_columns(created_at: at(3.5))
      other(2.5, 6)
      window = PaperTrailDiff::TimeRange.new(at(1.75)..at(3))
      ids = described_class.window_versions(FilterArticle, window, ['FilterNote']).pluck(:id)

      expect(ids).not_to include(review.id)
    end

    it 'reads no transaction for a window without paths' do
      window = PaperTrailDiff::TimeRange.new(at(0)..at(1))
      sql = described_class.window_versions(FilterArticle, window, []).to_sql

      expect(sql).not_to include('transaction_id')
    end

    it 'selects a version in a window once, whatever its transaction saved' do
      expect(selected(['FilterNote'], notes: { 2.5 => 6 }, range: at(0.5)..at(3)))
        .to eq([false, true, true])
    end

    it 'selects only the versions in a window from a version table without transactions' do
      allow(FilterVersion).to receive(:column_names)
        .and_return(FilterVersion.column_names - ['transaction_id'])

      expect(selected(['FilterNote'], notes: { 2.5 => 6 })).to eq([false, false, true])
    end
  end

  describe PaperTrailDiff::TransactionCut::Edge do
    it 'is frozen' do
      expect(described_class.new(at(0), true)).to be_frozen
    end
  end

  describe '.batch_windows' do
    it 'moves nothing without a window' do
      article, = history

      expect(described_class.batch_windows([article], nil)).to eq({})
    end

    it 'keys the moved windows by identity, for each class in the batch' do
      article, = history(transactions: { 1 => 7 })
      feature, = history(FilterFeature, transactions: { 1 => 8 })
      other(1.5, 7)
      other(1.5, 8)
      range = PaperTrailDiff::TimeRange.new(at(1.25)..at(3))
      traversal = instance_double(PaperTrailDiff::AssociationTraversal, path_types: ['FilterNote'])

      moved = described_class.batch_windows([article, feature], range, traversal: traversal)

      expect(moved.keys)
        .to eq([['FilterArticle', article.id.to_s], ['FilterArticle', feature.id.to_s]])
      expect(moved.values.map(&:begin_time)).to eq([at(1), at(1)])
    end
  end

  describe '.earliest_start' do
    let(:range) { PaperTrailDiff::TimeRange.new(at(1)..at(3)) }

    it 'is nothing without a window' do
      expect(described_class.earliest_start(nil, {})).to be_nil
    end

    it "is the window's start when nothing moved earlier" do
      expect(described_class.earliest_start(range, {})).to eq(at(1))
    end

    it 'is the earliest moved start' do
      moved = { %w[A 1] => PaperTrailDiff::TimeRange.new(at(0.25)..at(3)),
                %w[A 2] => PaperTrailDiff::TimeRange.new(at(0.5)..at(3)) }

      expect(described_class.earliest_start(range, moved)).to eq(at(0.25))
    end
  end
end
