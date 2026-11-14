# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::BatchedRootAnalyses do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }
  let(:analyzed) { [] }
  let(:prepared) { [] }
  let(:analyzer) do
    analyze = lambda do |record, plan, window|
      analyzed << [record, plan, window]
      AnalysisStandIn.new(record.id)
    end
    analyze.tap { |call| call.define_singleton_method(:empty) { AnalysisStandIn.new(nil) } }
  end
  let(:history_preparer) do
    ->(records, versions, **range) { prepared << [records, versions, range] }
  end

  def reach(model, start)
    asked << [model, start]
    reaches.shift
  end

  # Where the earliest transaction open at a window's start began, in turn,
  # and the model and start each was asked for.
  def reaches = (@reaches ||= [])
  def asked = (@asked ||= [])
  def planned = (@planned ||= [])
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
    # Stands in for an Analysis, naming its root and the window it was given.
    stub_const('AnalysisStandIn', Struct.new(:root_id, :window) do
      def with_window(range)
        self.class.new(root_id, range&.to_range)
      end
    end)
  end

  def at(minute)
    start_time + (minute * 60)
  end

  # Created and updated at the given minutes past the start, with a plan
  # over both versions.
  def root(model = FilterArticle, minutes: [0, 1])
    record = model.create!(title: 'Draft')
    record.update!(title: 'Final')
    versions = FilterVersion.where(item_id: record.id).order(:id).to_a
    versions.zip(minutes) { |version, minute| version.update_columns(created_at: at(minute)) }
    [record, PaperTrailDiff::RootVersionPlan.contiguous(versions)]
  end

  def key(record)
    PaperTrailDiff::Endpoint.identity(record)
  end

  # A batch that has not loaded its roots passes no `loaded`.
  def analyze(roots, within: nil, loaded: nil, activity: true)
    plans = roots.to_h { |record, plan| [key(record), plan] }
    planner = lambda do |records, range|
      planned << range&.to_range
      plans.slice(*records.map { |record| key(record) })
    end
    analyses = described_class.new(
      time_range: within && PaperTrailDiff::TimeRange.new(within), planner: planner,
      history_preparer: history_preparer, analyzer: analyzer, activity: activity,
      reach: method(:reach)
    )
    records = roots.map(&:first)
    loaded ? analyses.call(records, loaded: loaded) : analyses.call(records)
  end

  it 'analyzes each root from its plan, keyed by its identity' do
    article, plan = root
    other, other_plan = root

    result = analyze([[article, plan], [other, other_plan]])

    expect(result).to eq(key(article) => AnalysisStandIn.new(article.id),
                         key(other) => AnalysisStandIn.new(other.id))
    expect(result.keys).to all(be_frozen.and(all(be_frozen)))
    expect(analyzed).to eq([[article, plan, nil], [other, other_plan, nil]])
  end

  it 'passes each root the window as asked, though its history is read further' do
    article, plan = root
    other, other_plan = root
    reaches << at(0.5)

    result = analyze([[article, plan], [other, other_plan]], within: at(1)..at(3))

    expect(analyzed.map { |_record, _plan, window| window.to_range })
      .to eq([at(1)..at(3), at(1)..at(3)])
    expect(result.values.map(&:window)).to eq([at(1)..at(3), at(1)..at(3)])
  end

  it 'gives a root with nothing to replay an empty analysis, without analyzing it' do
    article, = root

    result = analyze([[article, PaperTrailDiff::RootVersionPlan.empty]], within: at(5)..at(6),
                                                                         activity: false)

    expect(result.fetch(key(article))).to eq(AnalysisStandIn.new(nil, at(5)..at(6)))
    expect([analyzed, prepared]).to eq([[], []])
  end

  # A transaction open at the window's start may have destroyed the root
  # before it, and ended inside: the plan from its reach finds that.
  it 'plans roots from where a window reaches, before reading anything' do
    article, plan = root(minutes: [1, 2])
    reaches << at(4)

    analyze([[article, plan]], within: at(5)..at(6))

    expect([asked, planned]).to eq([[[FilterArticle, at(5)]], [at(4)..at(6)]])
    expect(prepared.map(&:last)).to eq([{ start_at: at(4), end_at: at(6) }])
    expect(analyzed.map { |record, given, _window| [record, given] }).to eq([[article, plan]])
  end

  it 'does not ask how far a range reaches without a window' do
    article, = root

    analyze([[article, PaperTrailDiff::RootVersionPlan.empty]])

    expect([asked, prepared]).to eq([[], []])
  end

  # Its descendants may have moved in the window, though the root did not.
  it 'analyzes a root that closes on its current state with nothing else to replay' do
    article, = root
    plan = PaperTrailDiff::RootVersionPlan.closing_on(article)

    analyze([[article, plan]], within: at(5)..at(6))

    expect(analyzed.map { |record, given, _window| [record, given] }).to eq([[article, plan]])
  end

  describe 'preparing history' do
    it 'prepares each class once, with its roots and every version they replay' do
      article, article_plan = root(minutes: [0, 1])
      other, other_plan = root(minutes: [3, 4])
      feature, feature_plan = root(FilterFeature, minutes: [0, 2])

      analyze([[article, article_plan], [feature, feature_plan], [other, other_plan]])

      expect(prepared).to eq(
        [[[article, other], article_plan.versions + other_plan.versions,
          { start_at: nil, end_at: at(4) }],
         [[feature], feature_plan.versions, { start_at: nil, end_at: at(2) }]]
      )
    end

    it 'skips a class with nothing to replay and still prepares the next' do
      article, = root
      feature, feature_plan = root(FilterFeature)

      analyze([[article, PaperTrailDiff::RootVersionPlan.empty], [feature, feature_plan]])

      expect(prepared.map { |records, versions, _range| [records, versions] })
        .to eq([[[feature], feature_plan.versions]])
    end

    it 'prepares through the latest version, wherever it falls in the batch' do
      late, late_plan = root(minutes: [3, 4])
      early, early_plan = root(minutes: [0, 1])

      analyze([[late, late_plan], [early, early_plan]])

      expect(prepared.sole.last).to eq(start_at: nil, end_at: at(4))
    end

    # A root's plan can replay a version past the window, which reveals the
    # state it closed on. No root here closes on its current state, so none
    # reads on to now.
    it 'prepares from the window start through its end or the last version, whichever is later' do
      early, early_plan = root(minutes: [0, 1])
      late, late_plan = root(minutes: [2, 9])
      allow(Time).to receive(:now).and_return(at(60))

      analyze([[early, early_plan]], within: at(0)..at(5))
      analyze([[late, late_plan]], within: at(0)..at(5))

      expect(prepared.map(&:last)).to eq([{ start_at: at(0), end_at: at(5) },
                                          { start_at: at(0), end_at: at(9) }])
    end

    it 'plans and prepares a window once, from where its open transactions began' do
      article, plan = root(minutes: [1, 2])
      reaches << at(0.5)

      analyze([[article, plan]], within: at(1)...at(3))

      expect(planned).to eq([at(0.5)...at(3)])
      expect(prepared.map(&:last)).to eq([{ start_at: at(0.5), end_at: at(3) }])
    end

    # Each root version is reported where it was saved, so the roots are
    # planned over the window; the records around them are read from where
    # the open transactions began.
    it 'plans a window as asked without activity, and prepares it from the reach' do
      article, plan = root(minutes: [1, 2])
      reaches << at(0.5)

      analyze([[article, plan]], within: at(1)...at(3), activity: false)

      expect(planned).to eq([at(1)...at(3)])
      expect(prepared.map(&:last)).to eq([{ start_at: at(0.5), end_at: at(3) }])
    end

    it 'reads a window as asked when no transaction reaches outside it' do
      article, plan = root(minutes: [1, 2])

      analyze([[article, plan]], within: at(1)...at(3))

      expect(planned).to eq([at(1)...at(3)])
      expect(prepared.map(&:last)).to eq([{ start_at: at(1), end_at: at(3) }])
    end

    it 'asks how far a window reaches once for each class' do
      article, article_plan = root
      feature, feature_plan = root(FilterFeature)

      analyze([[article, article_plan], [feature, feature_plan]], within: at(0)..at(5))

      expect(asked).to eq([[FilterArticle, at(0)], [FilterFeature, at(0)]])
    end

    it 'prepares a root that closes on its current state, though it replays no version' do
      article, = root
      allow(Time).to receive(:now).and_return(at(60))

      [true, false].each do |activity|
        analyze([[article, PaperTrailDiff::RootVersionPlan.closing_on(article)]],
                within: at(0)..at(1), activity: activity)
      end

      expect(prepared).to eq([[[article], [], { start_at: at(0), end_at: at(60) }]] * 2)
    end

    it 'prepares a class through now when one of its roots closes on its current state' do
      article, plan = root
      closing, = root
      now = Time.utc(2032, 1, 2)
      allow(Time).to receive(:now).and_return(now.getlocal('+05:00'))

      analyze([[article, plan], [closing, PaperTrailDiff::RootVersionPlan.closing_on(closing)]],
              within: at(0)..at(1))

      range = prepared.sole.last
      expect(range).to eq(start_at: at(0), end_at: now)
      expect(range.fetch(:end_at)).to be_utc
    end

    it 'prepares from the current state a batch already loaded for a root' do
      article, plan = root
      loaded = FilterArticle.find(article.id)

      analyze([[article, plan]], loaded: { key(article) => loaded })

      expect(prepared.sole.first.sole).to equal(loaded)
    end
  end
end
