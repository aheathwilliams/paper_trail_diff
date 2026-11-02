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

  it 'takes no filter or a callable one, and refuses anything else as it is built' do
    callable = ->(relation) { relation }

    expect(described_class.validated(nil)).to be_nil
    expect(described_class.validated(callable)).to equal(callable)
    expect { described_class.new(:updates) }
      .to raise_error(PaperTrailDiff::ConfigurationError, 'version_scope: must respond to call')
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
end
