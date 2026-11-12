# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::VersionScopeFilter do
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # Created, then updated.
  def versions
    article = FilterArticle.create!(title: 'Draft')
    article.update!(title: 'Final')
    FilterVersion.where(item_id: article.id).order(:id).to_a
  end

  it 'keeps every version in range when there is no filter' do
    in_range = versions
    filter = described_class.new(nil)

    expect(filter.call(FilterVersion.all, in_range)).to equal(in_range)
    expect(filter.chosen_ids(FilterVersion.all)).to be_nil
  end

  it 'keeps the versions in range the filter keeps of the relation it is given' do
    created, updated = versions
    other_created, = versions
    filter = described_class.new(->(relation) { relation.where(event: 'create') })

    expect(filter.call(FilterVersion.where(id: [created.id, updated.id]), [created, updated]))
      .to eq([created])
    expect(filter.chosen_ids(FilterVersion.all)).to eq(Set[created.id, other_created.id])
  end

  # Active Support gives `pluck` to enumerables too.
  it 'reads a filter that returns an array of versions' do
    created, updated = versions
    filter = described_class.new(->(relation) { relation.to_a.select { |v| v.event == 'update' } })

    expect(filter.call(FilterVersion.all, [created, updated])).to eq([updated])
  end

  describe '.checked' do
    it 'takes no filter, or one that can be called with the relation, and refuses anything else' do
      expect(described_class.checked(nil)).to be_nil
      expect { described_class.checked(:updates) }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'version_scope: must respond to call')
      [-> {}, ->(_relation, _other) {}, Object.new.tap { |o| def o.call = nil }].each do |scope|
        expect { described_class.checked(scope) }
          .to raise_error(PaperTrailDiff::ConfigurationError,
                          'version_scope: must take the version relation as its one argument')
      end
      [proc { |relation| relation }, proc { nil }, ->(*relations) { relations },
       ->(relation, _ = 1) { relation }, Object.new.tap { |o| def o.call(relation) = relation }].each do |scope|
        expect(described_class.checked(scope)).to respond_to(:call)
      end
    end

    it 'refuses what the filter returns unless it is the relation narrowed or its versions' do
      created, = versions
      [nil, [created.id], [created, created.item]].each do |returned|
        checked = described_class.checked(->(_relation) { returned })

        expect { checked.call(FilterVersion.all) }.to raise_error(
          PaperTrailDiff::ConfigurationError,
          'version_scope: must return the relation it is given, narrowed, or an array of its ' \
          "versions; it returned #{returned.class}"
        )
      end
    end

    it 'passes on what the filter returns of the relation it is given' do
      created, = versions
      checked = described_class.checked(->(relation) { relation.where(event: 'create') })
      listed = described_class.checked(lambda(&:to_a))

      expect(checked.call(FilterVersion.where(id: created.id)).to_a).to eq([created])
      expect(listed.call(FilterVersion.where(id: created.id))).to eq([created])
    end

    it "refuses a relation on another table, whose ids are not versions'" do
      checked = described_class.checked(->(_relation) { FilterArticle.all })

      expect { checked.call(FilterVersion.all) }.to raise_error(
        PaperTrailDiff::ConfigurationError,
        'version_scope: must return the relation it is given, narrowed; it returned one on ' \
        'filter_articles, not filter_versions'
      )
    end
  end
end
