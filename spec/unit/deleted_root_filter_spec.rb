# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::DeletedRootFilter do
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
    FilterEvent.delete_all
  end

  def destroyed(model = FilterArticle, **attributes)
    record = model.create!(title: 'Article', **attributes)
    record.destroy!
    record
  end

  def identity(record)
    ['FilterArticle', record.id.to_s]
  end

  def kept(relation, records)
    described_class.new(relation).call(records.map { |record| identity(record) })
  end

  it "keeps the deleted roots whose state when destroyed met the relation's conditions" do
    one = destroyed(views: 1)
    two = destroyed(views: 2)

    expect(kept(FilterArticle.where(views: 1), [one, two])).to eq([identity(one)])
    expect(kept(FilterArticle.where.not(views: 1), [one, two])).to eq([identity(two)])
    expect(kept(FilterArticle.all, [one, two])).to eq([identity(one), identity(two)])
  end

  def record_destroy(item_type, id, object, created_at: Time.now)
    FilterVersion.create!(item_type: item_type, item_id: id, event: 'destroy',
                          created_at: created_at, object: object&.to_yaml)
  end

  it "reads the default scope too, and the latest destroy of the root's own type" do
    article = destroyed(views: 1)
    later = Time.now
    record_destroy('FilterArticle', article.id, { 'id' => article.id, 'views' => 2 })
    # Saved last but recorded first, so it is not the latest.
    record_destroy('FilterArticle', article.id, { 'id' => article.id, 'views' => 3 },
                   created_at: later - 3600)
    record_destroy('FilterEvent', article.id, { 'id' => article.id, 'views' => 4 })

    expect(kept(FilterArticle.where(views: 2), [article])).to eq([identity(article)])
    expect([1, 3, 4].map { |views| kept(FilterArticle.where(views: views), [article]) })
      .to eq([[], [], []])
    expect(kept(FilterArticle.unscoped.where(hidden: 1), [article])).to eq([])
  end

  it 'reads a destroy naming a removed column, and leaves out one with no state' do
    renamed = FilterArticle.create!(title: 'Renamed')
    record_destroy('FilterArticle', renamed.id,
                   { 'id' => renamed.id, 'title' => 'R', 'views' => 2, 'removed_column' => 1 })
    empty = FilterArticle.create!(title: 'Empty')
    record_destroy('FilterArticle', empty.id, nil)

    expect(kept(FilterArticle.where(views: 2), [renamed, empty])).to eq([identity(renamed)])
  end

  it "loads only the roots' own destroys" do
    article = destroyed(views: 1)
    destroyed(views: 1)
    loaded = []
    count = lambda do |*, payload|
      loaded << payload[:record_count] if payload[:class_name] == 'FilterVersion'
    end

    ActiveSupport::Notifications.subscribed(count, 'instantiation.active_record') do
      kept(FilterArticle.where(views: 1), [article])
    end

    expect(loaded).to eq([1])
  end

  # A report checks its ceiling after filtering, and before reifying anything.
  it 'reads each destroyed state of a plain model without reifying it' do
    events = %i[published draft].map { |status| FilterEvent.create!(status: status) }
    events.each(&:destroy!)
    expect_any_instance_of(FilterVersion).not_to receive(:reify)

    filtered = described_class.new(FilterEvent.where(status: :published))
                              .call(events.map { |event| ['FilterEvent', event.id.to_s] })
    expect(filtered).to eq([['FilterEvent', events.first.id.to_s]])
  end

  it 'keeps a root whose destroy was not recorded, which has no state to test' do
    article = FilterArticle.create!(title: 'Unrecorded', views: 3)
    FilterArticle.where(id: article.id).delete_all

    expect(kept(FilterArticle.where(views: 1), [article])).to eq([identity(article)])
  end

  it "keeps only a subclass's own records for a subclass relation" do
    article = destroyed(views: 1)
    feature = destroyed(FilterFeature, views: 1)

    expect(kept(FilterFeature.where(views: 1), [article, feature])).to eq([identity(feature)])
  end

  it 'leaves out the parts of a relation that choose a page or load rows' do
    article = destroyed(views: 1)
    relation = FilterArticle.where(views: 1).order(:id).limit(1).offset(0).select(:id).distinct

    expect(kept(relation, [article])).to eq([identity(article)])
  end

  it 'refuses a relation whose conditions it cannot read' do
    [FilterArticle.where('views > 1'), FilterArticle.joins('JOIN filter_versions ON 1 = 1'),
     FilterArticle.group(:views)].each do |relation|
      expect { described_class.new(relation) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /include_deleted: cannot test/)
    end
  end
end
