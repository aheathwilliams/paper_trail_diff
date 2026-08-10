# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::PreparedRecordIndex do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedReply.delete_all
    TrackedComment.delete_all
    TrackedProfile.delete_all
    TrackedAuthorship.delete_all
    TrackedArticle.delete_all
    TrackedAuthor.delete_all
    TrackedTag.delete_all
    PreparedDocument.delete_all
  end

  def boundary_for(article)
    article.paper_trail.save_with_version ||
      raise('PaperTrail did not create the requested boundary version')
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

  it 'keeps one trailing version per identity instead of everything after the range' do
    article = TrackedArticle.create!(title: 'Bounded tail')
    comment = TrackedComment.create!(article: article, body: 'In range')
    start_boundary = boundary_for(article)
    end_boundary = boundary_for(article)
    20.times { |index| comment.update!(body: "after range #{index}") }
    index = described_class.new(start_boundary, end_at: end_boundary)

    index.load(TrackedComment, [comment.id])

    # The state at the closing boundary only exists in the pre-change snapshot
    # of the first version recorded after it, so that one must survive.
    expect(index.record_before(TrackedComment, comment.id, end_boundary).body).to eq('In range')
    # That trailing version plus the live record, not the whole tail.
    expect(index.records_for(TrackedComment, [comment.id]).length).to eq(2)
  end

  it 'prefers a boundary transaction sibling recorded before the boundary itself' do
    article = TrackedArticle.create!(title: 'Boundary transaction')
    author = TrackedAuthor.create!(name: 'Before')
    start = boundary_for(article)
    boundary = nil
    ActiveRecord::Base.transaction do
      author.update!(name: 'During')
      boundary = boundary_for(article)
    end
    author.update!(name: 'After')
    index = described_class.new(start)

    index.load(TrackedAuthor, [author.id])

    sibling = author.versions.order(:id).find do |version|
      version.transaction_id == boundary.transaction_id
    end
    expect(sibling.created_at).to be < boundary.created_at
    expect(index.record_before(TrackedAuthor, author.id, boundary).name).to eq('Before')
  end

  it 'reuses prepared predecessor, successor, and live attributes for transitions' do
    article = TrackedArticle.create!(title: 'Prepared transitions')
    author = TrackedAuthor.create!(name: 'Before')
    before = boundary_for(article)
    author.update!(name: 'Middle')
    first_update = author.versions.last
    author.update!(name: 'After')
    second_update = author.versions.last
    index = described_class.new(before)

    index.load(TrackedAuthor, [author.id])

    first = index.transition(TrackedAuthor, author.id, first_update)
    second = index.transition(TrackedAuthor, author.id, second_update)
    expect(first&.map { |attributes| attributes.fetch('name') }).to eq(%w[Before Middle])
    expect(second&.map { |attributes| attributes.fetch('name') }).to eq(%w[Middle After])
    missing_version = instance_double(PaperTrail::Version, id: -1)
    expect(index.transition(TrackedAuthor, author.id, missing_version)).to be_nil
    expect(index.transition(TrackedAuthor, -1, first_update)).to be_nil
  end

  it 'prepares ordinary and STI version state without constructing a disposable record' do
    document = PreparedSpecialDocument.create!(name: 'Before')
    document.update!(name: 'After')
    version = document.versions.last
    reified_attributes = version.reify(dup: true).attributes
    direct = PaperTrailDiff::PreparedVersionStateLoader.new.call(version)
    live = PaperTrailDiff::PreparedRecordState.new(document)
    series = PaperTrailDiff::PreparedRecordSeries.new(versions: [version], live: live)
    boundary = Struct.new(:created_at).new(version.created_at)
    allow(version).to receive(:reify).and_raise('unexpected reification')

    prepared = series.record_before(boundary)

    expect(direct&.attributes).to eq(reified_attributes)
    expect(prepared).to be_a(PreparedSpecialDocument)
    expect(prepared.name).to eq('Before')
  end

  it 'rebuilds prepared state without reapplying overridden attribute writers' do
    document = PreparedRewrittenDocument.create!(name: 'Before')
    document.update!(name: 'After')
    version = document.versions.last
    reified = version.reify(dup: true)
    state = PaperTrailDiff::PreparedVersionStateLoader.new.call(version)

    prepared = state&.instantiate

    expect(reified.name).to eq('Before!')
    expect(prepared&.name).to eq(reified.name)
    expect(prepared&.attributes).to eq(reified.attributes)
  end

  it 'falls back to PaperTrail reification for attributes absent from the current schema' do
    author = TrackedAuthor.create!(name: 'Before fallback')
    author.update!(name: 'After fallback')
    version = author.versions.last
    fallback = version.reify(dup: true)
    deserialized = version.object_deserialized.merge('retired_column' => 'legacy')
    allow(version).to receive(:object_deserialized).and_return(deserialized)
    expect(version).to receive(:reify).and_return(fallback)
    series = PaperTrailDiff::PreparedRecordSeries.new(
      versions: [version],
      live: PaperTrailDiff::PreparedRecordState.new(author)
    )
    boundary = Struct.new(:created_at).new(version.created_at)

    expect(series.record_before(boundary).name).to eq('Before fallback')
  end

  it 'declines direct preparation for encrypted model attributes' do
    encrypted_model = Class.new do
      def self.inheritance_column = 'type'
      def self.encrypted_attributes = ['secret']
      def self.attribute_names = ['secret']
    end
    stub_const('PreparedEncryptedRecord', encrypted_model)
    version = double(
      'encrypted version',
      object: 'payload',
      object_deserialized: { 'secret' => 'value' },
      item_type: 'PreparedEncryptedRecord'
    )

    expect(PaperTrailDiff::PreparedVersionStateLoader.new.call(version)).to be_nil
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

  it 'reuses seeded live records while querying any identities not supplied' do
    article = TrackedArticle.create!(title: 'Seeded live records')
    authors = 3.times.map { |index| TrackedAuthor.create!(name: "Author #{index}") }
    before = boundary_for(article)
    authors.each { |author| author.update!(name: "#{author.name} updated") }
    index = described_class.new(before, live_records: authors.first(2))
    statements = []
    callback = proc do |_name, _start, _finish, _id, payload|
      statements << payload[:name] unless payload[:name] == 'SCHEMA' || payload[:cached]
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      index.load(TrackedAuthor, authors.map(&:id))
    end

    expect(statements.count { |name| name == 'PaperTrail::Version Load' }).to eq(1)
    expect(statements.count { |name| name == 'TrackedAuthor Load' }).to eq(1)
    expect(index.record_before(TrackedAuthor, authors.first.id, before).name)
      .to eq('Author 0')
    expect(index.record_before(TrackedAuthor, authors.last.id, before).name)
      .to eq('Author 2')
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
    mismatched = PaperTrailDiff::PreparedRecordState.new(
      TrackedArticle.create!(title: 'Different transition type')
    )
    mismatched_series = PaperTrailDiff::PreparedRecordSeries.new(
      versions: [version],
      live: mismatched
    )
    expect(mismatched_series.transition(version)).to be_nil
    expect(index.send(:live_records_for, composite, [author.id])).to eq([])
  end
end
