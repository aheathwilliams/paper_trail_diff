# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::RecordedClass do
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
    FilterEvent.delete_all
  end

  # The record's versions, created and then updated once.
  def versions(record)
    record.update!(record.is_a?(FilterEvent) ? { status: :published } : { title: 'Final' })
    FilterVersion.where(item_id: record.id, item_type: record.class.base_class.name).order(:id).to_a
  end

  # Rewrites the state a version stored before its change.
  def store(version, **attributes)
    state = version.object_deserialized.merge(attributes.transform_keys(&:to_s))
    version.update_columns(object: PaperTrail.serializer.dump(state))
    version
  end

  def recorded(version)
    described_class.for(version)
  end

  it 'reads a subclass from the type stored before the change, or created with' do
    created, updated = versions(FilterFeature.create!(title: 'Draft'))
    article_created, article_updated = versions(FilterArticle.create!(title: 'Draft'))

    expect([created, updated, article_created, article_updated].map { |version| recorded(version) })
      .to eq([FilterFeature, FilterFeature, FilterArticle, FilterArticle])
  end

  it 'reads the class before the change from an update that changed it' do
    article = FilterArticle.create!(title: 'Draft')
    article.update!(type: 'FilterFeature')
    _created, changed = FilterVersion.where(item_id: article.id).order(:id).to_a

    expect(recorded(changed)).to eq(FilterArticle)
  end

  # A column dropped after the versions were saved leaves its values in them.
  it 'reads a model without single-table inheritance as itself, whatever a version stored' do
    _created, updated = versions(FilterEvent.create!(status: :draft))

    expect(recorded(store(updated, type: 'FilterGone'))).to eq(FilterEvent)
  end

  it 'trusts a version that names a subclass rather than the base class' do
    _created, updated = versions(FilterFeature.create!(title: 'Draft'))
    updated.update_columns(item_type: 'FilterFeature')

    expect(recorded(store(updated, type: 'FilterArticle'))).to eq(FilterFeature)
  end

  it 'keeps the base class where a version stored no type it can read' do
    created, updated = versions(FilterFeature.create!(title: 'Draft'))
    created.update_columns(object_changes: nil)
    allow(updated).to receive(:object_deserialized).and_return('not a state')

    expect([recorded(created), recorded(updated)]).to eq([FilterArticle, FilterArticle])
  end

  # As a custom serializer may load it.
  it 'reads a stored type from any hash, under a string or symbol key' do
    _created, updated = versions(FilterArticle.create!(title: 'Draft'))
    states = [{ type: 'FilterFeature' },
              ActiveSupport::HashWithIndifferentAccess.new('type' => 'FilterFeature')]
    found = states.map do |state|
      allow(updated).to receive(:object_deserialized).and_return(state)
      recorded(updated)
    end

    expect(found).to eq([FilterFeature, FilterFeature])
  end

  it "reads a created record's type from the object changes adapter's changeset" do
    created, = versions(FilterArticle.create!(title: 'Draft'))
    changesets = [{ 'type' => [nil, 'FilterFeature'] }, { 'type' => 'FilterFeature' }, nil, []]
    found = changesets.map do |changeset|
      adapter = double(load_changeset: changeset)
      allow(PaperTrail.config).to receive(:object_changes_adapter).and_return(adapter)
      recorded(created)
    end

    expect(found).to eq([FilterFeature, FilterArticle, FilterArticle, FilterArticle])
  end

  it 'refuses a stored type that names no subclass, and passes on other errors' do
    _created, updated = versions(FilterArticle.create!(title: 'Draft'))
    gone = updated.dup.tap { |version| version.item_type = 'RemovedModel' }

    expect { recorded(store(updated, type: 'FilterMissing')) }
      .to raise_error(PaperTrailDiff::InvalidEndpointError,
                      'cannot resolve endpoint model: FilterMissing') { |error|
        expect(error.cause).to be_a(ActiveRecord::SubclassNotFound)
      }
    expect { recorded(gone) }
      .to raise_error(PaperTrailDiff::InvalidEndpointError,
                      'cannot resolve endpoint model: RemovedModel')
  end

  it "reads a version's recorded class, or a live record's own" do
    feature = FilterFeature.create!(title: 'Draft')
    created, = versions(feature)

    expect([described_class.of_endpoint(created), described_class.of_endpoint(feature)])
      .to eq([FilterFeature, FilterFeature])
  end
end
