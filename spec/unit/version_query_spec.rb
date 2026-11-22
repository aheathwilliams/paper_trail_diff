# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::VersionQuery do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # Created, then updated twice, at the given minutes past the start.
  def history(model = FilterArticle, minutes: [0, 1, 2])
    record = model.create!(title: 'Draft')
    %w[Review Final].each { |title| record.update!(title: title) }
    versions = FilterVersion.where(item_id: record.id).order(:id).to_a
    versions.zip(minutes) do |version, minute|
      version.update_columns(created_at: start_time + (minute * 60))
    end
    [record, *versions]
  end

  # SQLite returns rows saved in one instant in id order anyway, so the
  # order asked for is read rather than only the rows it returns.
  it 'orders versions by time, then by id' do
    _record, created, reviewed, final = history(minutes: [2, 0, 0])
    relation = described_class.chronological(FilterVersion.order(:event))

    expect(relation.to_a).to eq([reviewed, final, created])
    expect(relation.order_values.map { |order| [order.expr.name.to_s, order.direction] })
      .to eq([['created_at', :asc], ['id', :asc]])
  end

  # The base class names the items of its subclasses too.
  it "reads every version of a model's items from its version class, by its base class" do
    _article, *article_versions = history
    _feature, *feature_versions = history(FilterFeature)
    FilterVersion.insert({ item_type: 'FilterNote', item_id: 1, event: 'create',
                           created_at: start_time })

    expect(described_class.for_model(FilterFeature))
      .to match_array(article_versions + feature_versions)
  end

  # Ids come back as strings, whatever the column's type, and only those of
  # the model's own items: a version of another type under the same id is
  # not one.
  it 'names the ids among those given that a version of the model names, in slices' do
    article, = history
    feature, = history(FilterFeature)
    FilterVersion.insert({ item_type: 'FilterNote', item_id: 900, event: 'create',
                           created_at: start_time })
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
    reads = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      reads << payload[:sql] if payload[:sql].include?('filter_versions')
    end

    named = described_class.named_ids(FilterFeature, [article.id, 900, feature.id])

    ActiveSupport::Notifications.unsubscribe(subscriber)
    expect(named).to eq([article.id.to_s, feature.id.to_s])
    expect(reads.length).to eq(2)
    expect(described_class.named_ids(FilterArticle, [])).to eq([])
  end

  it 'tells, in a statement over another table, whether a version of the model names an id' do
    article, = history
    feature, = history(FilterFeature)
    quiet = PaperTrail.request(enabled: false) { FilterArticle.create!(title: 'Quiet') }
    FilterVersion.insert({ item_type: 'FilterNote', item_id: quiet.id, event: 'create',
                           created_at: start_time })
    naming = described_class.naming(FilterFeature, FilterArticle.arel_table[:id])

    expect(FilterArticle.where(naming).ids).to contain_exactly(article.id, feature.id)
    expect(FilterArticle.where(naming.not).ids).to eq([quiet.id])
    # Over the version table itself, the versions it asks about are others.
    over_versions = described_class.naming(FilterFeature, FilterVersion.arel_table[:item_id])
    expect(FilterVersion.where(item_type: 'FilterNote').where(over_versions).count).to eq(0)
  end

  it 'reads the versions of the given items' do
    article, *versions = history
    history

    expect(described_class.for_items(FilterArticle, [article.id])).to match_array(versions)
  end

  # A version saved in the same instant comes after it when its id is
  # higher. Another item's versions, and another type's under the same id,
  # are not the item's own.
  it "reads the item's versions saved after a version" do
    article, created, reviewed, final = history(minutes: [1, 2, 2])
    _other, *other_versions = history(minutes: [3, 4, 5])
    FilterVersion.insert({ item_type: 'FilterNote', item_id: article.id, event: 'update',
                           created_at: start_time + 600 })
    earlier = FilterVersion.create!(item_type: 'FilterArticle', item_id: article.id,
                                    event: 'update', created_at: start_time)

    expect(described_class.after(FilterArticle, created)).to contain_exactly(reviewed, final)
    expect(described_class.after(FilterArticle, reviewed)).to eq([final])
    expect(described_class.after(FilterArticle, final)).to be_empty
    expect(described_class.after(FilterArticle, earlier))
      .to contain_exactly(created, reviewed, final)
    expect(other_versions).not_to be_empty
  end

  # Another item's versions, and another type's under the same id, are not
  # the item's own, earlier or not.
  it "keeps each item's earliest version, of those the block accepts" do
    article, created, reviewed, = history(minutes: [1, 2, 3])
    _other, other_created, other_reviewed, = history(minutes: [4, 5, 6])
    FilterVersion.insert({ item_type: 'FilterNote', item_id: article.id, event: 'update',
                           created_at: start_time })
    table = FilterVersion.arel_table
    updates = ->(earlier) { earlier[:event].eq('update') }

    articles = FilterVersion.where(item_type: 'FilterArticle')

    expect(articles.where(described_class.no_earlier_version(table)))
      .to contain_exactly(created, other_created)
    expect(articles.where(described_class.no_earlier_version(table, &updates)))
      .to contain_exactly(created, reviewed, other_created, other_reviewed)
  end

  # An item created after the time, by the first of its versions.
  it 'tells which items were created after a time, with no version before their create' do
    rows = [['FilterArticle', 1, 'create', 2], ['FilterArticle', 2, 'create', 1],
            ['FilterArticle', 3, 'update', 1], ['FilterArticle', 3, 'create', 2],
            ['FilterArticle', 4, 'update', 2], ['FilterNote', 2, 'create', 2]]
    FilterVersion.insert_all(rows.map do |type, id, event, minute|
      { item_type: type, item_id: id, event: event, created_at: start_time + (minute * 60) }
    end)
    table = FilterVersion.arel_table
    created = described_class.created_after(table, table[:item_type], table[:item_id],
                                            start_time + 90)

    expect(FilterVersion.where(created).distinct.pluck(:item_type, :item_id))
      .to contain_exactly(['FilterArticle', 1], ['FilterNote', 2])
  end
end
