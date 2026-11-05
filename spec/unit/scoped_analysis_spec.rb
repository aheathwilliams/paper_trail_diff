# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::ScopedAnalysis do
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  let(:article) { FilterArticle.create!(title: 'Article') }
  let(:feature) { FilterFeature.create!(title: 'Feature') }
  let(:boundary) do
    PaperTrailDiff::ActivityBoundary.new(kind: :version, version_id: 1, item_type: 'Article',
                                         item_id: 3, recorded_at: Time.utc(2026))
  end

  # An analysis whose activity steps from each title of an article to the
  # next, nil for none, keeping the steps' snapshots.
  def analysis(*titles)
    states = titles.map do |title|
      title && PaperTrailDiff::RecordSnapshot.new(type: 'Article', id: 3,
                                                  attributes: { 'title' => title })
    end
    steps = states.each_cons(2).map do |from, to|
      PaperTrailDiff::ActivityStep.between(from_boundary: boundary, to_boundary: boundary,
                                           from_snapshot: from, to_snapshot: to, retain: true)
    end
    PaperTrailDiff::Analysis.new(diff: PaperTrailDiff::Diff.new, timeline: [],
                                 activity_timeline: steps)
  end

  def key(record)
    ['FilterArticle', record.id.to_s]
  end

  describe '#analysis_for' do
    it "finds a root's analysis from the record, keyed by its base class" do
      found = analysis('A', 'B')
      scoped = described_class.new(analyses: { key(article) => analysis, key(feature) => found },
                                   unreachable: [], roots: [article, feature])

      expect(scoped.analysis_for(feature)).to equal(found)
      expect(scoped.analysis_for(FilterArticle.find(feature.id))).to equal(found)
    end

    it 'raises for a record the selection did not load, deleted roots included' do
      other = FilterArticle.create!(title: 'Other')
      scoped = described_class.new(analyses: { key(article) => analysis },
                                   unreachable: [key(feature)],
                                   deleted: { key(feature) => analysis })

      expect { scoped.analysis_for(other) }.to raise_error(KeyError, /#{other.id}/)
      expect { scoped.analysis_for(feature) }.to raise_error(KeyError)
    end

    it 'pairs each root analyze_scope loads with its analysis' do
      records = [article, feature]
      start = Time.now.utc
      records.each { |record| record.update!(title: "#{record.title}!") }
      scoped = PaperTrailDiff.analyze_scope(FilterArticle.all, within: start.., limit: 5)

      expect(scoped.roots).to contain_exactly(article, feature)
      expect(scoped.roots.map { |root| scoped.analysis_for(root).diff.attributes.keys })
        .to all(include('title'))
    end
  end

  it 'keys change rows and net changes as its analyses, deleted roots last' do
    missing = %w[FilterArticle 0]
    scoped = described_class.new(
      analyses: { key(article) => analysis('A', 'B') }, unreachable: [key(feature), missing],
      deleted: { key(feature) => analysis('C', nil), missing => nil }
    )

    rows = scoped.change_rows.transform_values do |list|
      list.map { |row| [row.change, row.attribute] }
    end
    changes = scoped.net_changes.transform_values do |list|
      list.map { |change| [change.added?, change.removed?] }
    end
    expect(rows).to eq(key(article) => [[:changed, 'title']],
                       key(feature) => [[:removed, nil], [:removed, 'title']])
    expect(changes).to eq(key(article) => [[false, false]], key(feature) => [[false, true]])
    expect(scoped.net_changes { false }.values).to all(eq([]))
    expect([scoped.change_rows, scoped.net_changes]).to all(be_frozen)
  end

  it 'keeps frozen copies of what it was given, but not of the roots themselves' do
    unreachable = [key(feature)]
    roots = [article]
    deleted = { key(feature) => nil }
    scoped = described_class.new(analyses: {}, unreachable: unreachable, roots: roots,
                                 deleted: deleted)
    unreachable << %w[FilterArticle 0]
    deleted[%w[FilterArticle 0]] = nil

    expect([scoped.unreachable, scoped.deleted.keys]).to all(eq([key(feature)]))
    expect([scoped, scoped.unreachable, scoped.roots, scoped.deleted]).to all(be_frozen)
    expect(roots).not_to be_frozen
    expect(scoped.roots.first).not_to be_frozen
  end

  it 'destructures into its analyses and unreachable identities, with no roots or deleted' do
    analyses = { key(article) => analysis }
    scoped = described_class.new(analyses: analyses, unreachable: [key(feature)])

    found, unreachable = scoped
    expect([found, unreachable]).to eq([analyses, [key(feature)]])
    expect([scoped.roots, scoped.deleted]).to eq([[], {}])
  end
end
