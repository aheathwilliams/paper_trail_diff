# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::DeletedAnalysisBatch do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }
  let(:analyzed) { [] }
  let(:prepared) { [] }
  let(:analyzer) do
    lambda do |record, plan|
      analyzed << [record, plan]
      "analysis of #{record.id}"
    end
  end
  let(:history_preparer) do
    ->(records, versions, **range) { prepared << [records, versions, range] }
  end

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  def at(minute)
    start_time + (minute * 60)
  end

  # Created, updated, then destroyed, at the given minutes past the start.
  def deleted(model = FilterArticle, minutes: [0, 1, 2])
    article = model.create!(title: 'Draft')
    article.update!(title: 'Final')
    article.destroy!
    versions = FilterVersion.where(item_id: article.id).order(:id).to_a
    versions.zip(minutes) { |version, minute| version.update_columns(created_at: at(minute)) }
    [article, *versions]
  end

  def key(record)
    ['FilterArticle', record.id.to_s]
  end

  def analyze(identities, model: FilterArticle, within: nil, version_scope: nil, context: false)
    described_class.new(
      model, identities: identities, time_range: within && PaperTrailDiff::TimeRange.new(within),
             analyzer: analyzer, history_preparer: history_preparer, version_scope: version_scope,
             context_required: context
    ).call
  end

  it 'analyzes nothing for no identities' do
    expect(analyze([])).to eq({}).and be_frozen
    expect(prepared).to eq([])
  end

  it 'analyzes each deleted root from its history, keyed by the identities asked for' do
    article, created, updated, destroyed = deleted
    deleted
    never_deleted = FilterArticle.create!(title: 'Live')

    result = analyze([key(article), key(never_deleted), %w[FilterArticle 0]])

    expect(result).to eq(key(article) => "analysis of #{article.id}",
                         key(never_deleted) => nil, %w[FilterArticle 0] => nil)
    expect(result).to be_frozen
    expect(result.keys).to all(be_frozen.and(all(be_frozen)))
    record, plan = analyzed.sole
    expect([record.class, record.id, record.new_record?]).to eq([FilterArticle, article.id, true])
    expect(plan.versions).to eq([created, updated, destroyed])
  end

  it 'reads only the deletions of the model asked for' do
    article, = deleted
    FilterVersion.where(item_id: article.id).update_all(item_type: 'FilterNote')

    expect(analyze([key(article)])).to eq(key(article) => nil)
  end

  it 'builds a subclass root as its own class, even when asked through the subclass' do
    feature, = deleted(FilterFeature)

    analyze([key(feature)], model: FilterFeature)

    expect(analyzed.sole.first).to be_an_instance_of(FilterFeature)
  end

  it 'builds the root from the version type when the destroy stored no object' do
    feature, *, destroyed = deleted(FilterFeature)
    destroyed.update_columns(object: nil)

    analyze([key(feature)])

    expect(analyzed.sole.first).to be_an_instance_of(FilterArticle)
  end

  # An id can be reused after a destroy. Here the later destroy has the lower
  # id, and stored the record as the base class.
  it 'builds the root from the latest destroy of a reused id' do
    feature, _created, updated, destroyed = deleted(FilterFeature)
    updated.update_columns(event: 'destroy', created_at: at(9),
                           object: destroyed.object.sub("type: FilterFeature\n", "type:\n"))

    analyze([key(feature)])

    expect(analyzed.sole.first).to be_an_instance_of(FilterArticle)
  end

  it 'gives a root with nothing in the window an empty analysis without analyzing it' do
    article, = deleted

    result = analyze([key(article)], within: at(5)..at(6))

    expect(result.fetch(key(article)).activity_timeline).to eq([])
    expect(analyzed).to eq([])
    expect(prepared).to eq([])
  end

  # An activity view reports association changes in such a window, so it
  # needs the root's state there: the version after the window holds it.
  it 'reads a root with nothing in the window from the version after it when asked' do
    article, _created, _updated, destroyed = deleted(minutes: [0, 1, 4])

    analyze([key(article)], within: at(2)..at(3), context: true)

    plan = analyzed.sole.last
    expect(plan.reconstruction_versions).to eq([destroyed])
    expect(plan.mutation?(destroyed)).to be(false)
  end

  it 'does not read a root destroyed before the window, even when asked' do
    article, = deleted
    early, = deleted(minutes: [0, 1, 2])
    late, _created, _updated, after = deleted(minutes: [0, 1, 9])

    result = analyze([key(article), key(early), key(late)], within: at(5)..at(6), context: true)

    expect(result.fetch(key(article)).activity_timeline).to eq([])
    expect(result.fetch(key(early)).activity_timeline).to eq([])
    expect(analyzed.map { |record, plan| [record.id, plan.reconstruction_versions] })
      .to eq([[late.id, [after]]])
  end

  it 'passes the version scope on to version selection' do
    article, _created, updated, = deleted

    analyze([key(article)], version_scope: ->(versions) { versions.where(id: updated.id) })

    expect(analyzed.sole.last.mutations).to eq([updated])
  end

  describe 'preparing history' do
    it 'skips a class with nothing in the window and still prepares the next' do
      article, = deleted
      feature, *feature_versions = deleted(FilterFeature, minutes: [5, 6, 7])

      analyze([key(article), key(feature)], within: at(5)..at(6))

      expect(prepared.map { |records, versions, _range| [records.map(&:class), versions] })
        .to eq([[[FilterFeature], feature_versions]])
    end

    # Each root ends at its destroy, but inside a window it ends at the version
    # after the window, so the last one prepared need not be the latest.
    it 'prepares through the latest version, wherever it falls in the batch' do
      early, = deleted(minutes: [0, 4, 5])
      late, = deleted(minutes: [1, 3, 10])

      analyze([key(early), key(late)], within: at(0)..at(2))

      expect(prepared.sole.last).to eq(start_at: at(0), end_at: at(4))
    end

    it 'prepares each class once, with its versions, through the last of them' do
      article, *article_versions = deleted
      other, *other_versions = deleted(minutes: [3, 4, 5])
      feature, *feature_versions = deleted(FilterFeature, minutes: [0, 1, 2])

      analyze([key(article), key(other), key(feature)])

      expect(prepared).to contain_exactly(
        [[an_object_having_attributes(id: article.id), an_object_having_attributes(id: other.id)],
         article_versions + other_versions, { start_at: nil, end_at: at(5) }],
        [[an_object_having_attributes(id: feature.id)], feature_versions,
         { start_at: nil, end_at: at(2) }]
      )
    end

    it 'prepares from the window start through its end or the last version, whichever is later' do
      article, = deleted

      analyze([key(article)], within: at(0)..at(1))
      analyze([key(article)], within: at(1)..at(7))

      expect(prepared.map(&:last)).to eq([{ start_at: at(0), end_at: at(2) },
                                          { start_at: at(1), end_at: at(7) }])
    end
  end
end
