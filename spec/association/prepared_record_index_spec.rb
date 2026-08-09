# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::PreparedRecordIndex do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedReply.delete_all
    TrackedComment.delete_all
    TrackedProfile.delete_all
    TrackedArticle.delete_all
    TrackedAuthor.delete_all
    TrackedTag.delete_all
  end

  def boundary_for(article)
    article.paper_trail.save_with_version
    article.versions.reload.last
  end

  it 'uses the first future pre-change state and then the live fallback' do
    article = TrackedArticle.create!(title: 'Temporal index')
    author = TrackedAuthor.create!(name: 'Before')
    before = boundary_for(article)
    author.update!(name: 'After')
    after = boundary_for(article)
    index = described_class.new(before)

    index.load(TrackedAuthor, [author.id])

    expect(index.record_before(TrackedAuthor, author.id, before).name).to eq('Before')
    expect(index.record_before(TrackedAuthor, author.id, before).name).to eq('Before')
    expect(index.record_before(TrackedAuthor, author.id, after).name).to eq('After')
  end

  it 'represents absence before creation and after destruction' do
    article = TrackedArticle.create!(title: 'Temporal absence')
    before = boundary_for(article)
    author = TrackedAuthor.create!(name: 'Brief')
    during = boundary_for(article)
    author.destroy!
    after = boundary_for(article)
    index = described_class.new(before)

    index.load(TrackedAuthor, [author.id])

    expect(index.record_before(TrackedAuthor, author.id, before)).to be_nil
    expect(index.record_before(TrackedAuthor, author.id, during).name).to eq('Brief')
    expect(index.record_before(TrackedAuthor, author.id, after)).to be_nil
    expect(index.records_for(TrackedAuthor, [author.id]).map(&:name)).to eq(['Brief'])
  end

  it 'loads multiple identities with one version query and one live query' do
    article = TrackedArticle.create!(title: 'Batched identities')
    authors = 3.times.map { |index| TrackedAuthor.create!(name: "Author #{index}") }
    before = boundary_for(article)
    authors.each { |author| author.update!(name: "#{author.name} updated") }
    queries = 0
    callback = proc do |_name, _start, _finish, _id, payload|
      queries += 1 unless payload[:name] == 'SCHEMA' || payload[:cached]
    end
    index = described_class.new(before)

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      index.load(TrackedAuthor, authors.map(&:id))
    end

    expect(queries).to eq(2)
    expect(index.records_for(TrackedAuthor, authors.map(&:id)).length).to eq(6)
    expect(index.loaded?(TrackedAuthor, authors.first.id)).to be(true)
    expect(index.loaded?(TrackedAuthor, -1)).to be(false)

    repeated_queries = 0
    callback = proc do |_name, _start, _finish, _id, payload|
      repeated_queries += 1 unless payload[:name] == 'SCHEMA' || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      index.load(TrackedAuthor, [authors.first.id, nil])
    end
    expect(repeated_queries).to be_zero
  end

  it 'treats versions from the boundary transaction as pre-change state' do
    article = TrackedArticle.create!(title: 'Transaction boundary')
    author = TrackedAuthor.create!(name: 'Before transaction')
    before = boundary_for(article)
    boundary = nil
    TrackedArticle.transaction do
      author.update!(name: 'After transaction')
      article.update!(title: 'Transaction changed')
      boundary = article.versions.last
    end
    index = described_class.new(before)

    index.load(TrackedAuthor, [author.id])

    expect(index.record_before(TrackedAuthor, author.id, boundary).name)
      .to eq('Before transaction')
  end

  it 'accepts a timestamp-only boundary and declines composite-key live loading' do
    author = TrackedAuthor.create!(name: 'Timestamp fallback')
    version = author.versions.last
    state = PaperTrailDiff::PreparedRecordState.new(author)
    series = PaperTrailDiff::PreparedRecordSeries.new(versions: [version], live: state)
    boundary = Struct.new(:created_at).new(version.created_at + 1)
    index = described_class.new(version)
    composite = double('composite model', primary_key: %i[tenant_id id])

    expect(series.record_before(boundary).name).to eq('Timestamp fallback')
    expect(index.send(:live_records_for, composite, [author.id])).to eq([])
  end
end
