# frozen_string_literal: true

require_relative '../support/source_type_database'

# The reader builds snapshots from stored attributes. A reflection it declines
# sends the whole root to `reify` and PT-AT-shaped records instead, so every
# result here is compared with that path, which the reader once took for
# throughs and polymorphic `belongs_to`.
RSpec.describe PaperTrailDiff::PreparedStateAssociationReader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedAuthorship, TrackedArticle, TrackedAuthor, SourceTypeLink,
     SourceTypeHolder, SourceTypeAuthor, SourceTypeTag].each(&:delete_all)
  end

  # A current boundary records when each call read it.
  def scrub(value)
    case value
    when Hash then value.except(:recorded_at).transform_values { |item| scrub(item) }
    when Array then value.map { |item| scrub(item) }
    else value
    end
  end

  def results(roots, versions, window, associations)
    analyses = [false, true].map do |activity|
      PaperTrailDiff.analyze_many(roots, within: window, associations: associations,
                                         activity: activity, snapshots: activity)
                    .transform_values { |analysis| analysis.to_h(snapshots: activity) }
    end
    comparisons = versions.map do |from, to|
      PaperTrailDiff.compare_many([{ from: from, to: to }], associations: associations)
                    .transform_values(&:to_h)
    end
    scrub([analyses, comparisons])
  end

  # The same results with the reader declining throughs and polymorphic
  # `belongs_to`, as it did before it read them.
  def declined_results(*arguments)
    allow_any_instance_of(described_class).to receive(:call)
      .and_wrap_original do |original, owner, reflection, boundary|
        next [false, []] if reflection.options[:through] || reflection.polymorphic?

        original.call(owner, reflection, boundary)
      end
    results(*arguments)
  ensure
    RSpec::Mocks.space.reset_all
  end

  # `reify:` says whether the root itself is still read by the record path.
  def expect_same_results(roots, versions, window, associations, reify: false)
    reified = 0
    allow_any_instance_of(PaperTrail::Version).to receive(:reify)
      .and_wrap_original do |original, *arguments, **options|
        reified += 1
        original.call(*arguments, **options)
      end
    read = results(roots, versions, window, associations)
    expect(reified.positive?).to be(reify)
    RSpec::Mocks.space.reset_all

    expect(read).to eq(declined_results(roots, versions, window, associations))
    changed = read.first.first.values.map { |analysis| analysis.dig(:diff, :associations) }
    expect(changed.reject(&:empty?)).not_to be_empty
  end

  def checkpoint(record)
    record.class.transaction do
      fresh = record.class.find(record.id)
      fresh.paper_trail.save_with_version
      fresh.versions.reorder(:id).last
    end
  end

  it 'reads a has_many :through over moved and destroyed join records and members' do
    ada, bea = %w[Ada Bea].map { |name| TrackedAuthor.create!(name: name) }
    moved = TrackedArticle.create!(title: 'Moved', author: ada)
    kept = TrackedArticle.create!(title: 'Kept', author: ada)
    gone = TrackedArticle.create!(title: 'Gone', author: bea)
    travelling = moved.comments.create!(body: 'travels')
    destroyed = kept.comments.create!(body: 'destroyed')
    edited = gone.comments.create!(body: 'edited')
    starts = [ada, bea].map { |author| checkpoint(author) }
    moved.update!(author: bea)
    travelling.update!(article: kept)
    destroyed.destroy!
    edited.update!(body: 'edited again')
    gone.destroy!
    kept.comments.create!(body: 'new')
    ends = [ada, bea].map { |author| checkpoint(author) }

    expect_same_results([ada, bea], starts.zip(ends), starts.first.created_at..Time.now.utc,
                        [:comments])
  end

  it 'reads a has_many :through whose source is a belongs_to' do
    article = TrackedArticle.create!(title: 'Article')
    writer, editor = %w[Writer Editor].map { |name| TrackedAuthor.create!(name: name) }
    TrackedAuthorship.create!(article: article, author: writer, role: 'writer')
    leaving = TrackedAuthorship.create!(article: article, author: editor, role: 'editor')
    start = checkpoint(article)
    writer.update!(name: 'Writer renamed')
    leaving.destroy!
    finish = checkpoint(article)

    expect_same_results([article], [[start, finish]], start.created_at..Time.now.utc,
                        [:contributors])
  end

  describe 'a polymorphic source' do
    def history
      holder = SourceTypeHolder.create!(name: 'Holder')
      ada = SourceTypeAuthor.create!(name: 'Ada')
      tag = SourceTypeTag.create!(name: 'Same id', id: ada.id + 1)
      bea = SourceTypeAuthor.create!(name: 'Bea', id: tag.id)
      to_tag = SourceTypeLink.create!(holder: holder, target: ada)
      to_author = SourceTypeLink.create!(holder: holder, target: tag)
      start = checkpoint(holder)
      starts = [to_tag, to_author].map { |link| checkpoint(link) }
      ada.update!(name: 'Ada renamed')
      to_tag.update!(target: SourceTypeTag.create!(name: 'New tag'))
      to_author.update!(target: bea)
      tag.update!(name: 'Same id renamed')
      [holder, start, [to_tag, to_author], starts]
    end

    it 'reads a through with source_type, only for links of that type' do
      holder, start, = history
      finish = checkpoint(holder)

      %i[linked_authors symbol_authors].each do |name|
        expect_same_results([holder], [[start, finish]], start.created_at..Time.now.utc, [name])
      end
    end

    it 'reads a polymorphic belongs_to of each type a link names' do
      _holder, start, links, starts = history
      ends = links.map { |link| checkpoint(link) }

      expect_same_results(links, starts.zip(ends), start.created_at..Time.now.utc, [:target])
    end

    # The tag a link moves to is outside the scope, so that link ends with no
    # target.
    it 'reads a target whose default scope is plain conditions, keeping it out' do
      _holder, start, links, starts = history
      ends = links.map { |link| checkpoint(link) }
      hidden = links.first.target_id
      SourceTypeTag.class_eval { default_scope { where.not(id: hidden) } }

      expect_same_results(links, starts.zip(ends), start.created_at..Time.now.utc, [:target])
      steps = PaperTrailDiff.activity_timeline(links.first, from: starts.first, to: ends.first,
                                                            associations: [:target], snapshots: true)
      expect(steps.last.to_snapshot.associations.fetch('target').records).to eq([])
    ensure
      SourceTypeTag.default_scopes = []
    end

    it 'leaves a type naming no class, and a target scope it cannot read, to the record path' do
      holder, start, links, = history
      SourceTypeLink.where(id: links.first.id).update_all(target_type: 'RenamedModel')
      SourceTypeTag.class_eval { default_scope { where("name <> 'hidden'") } }
      window = start.created_at..Time.now.utc

      expect { PaperTrailDiff.analyze(links.first, within: window, associations: [:target]) }
        .to raise_error(PaperTrailDiff::IncompleteAssociationHistoryError, /RenamedModel/)
      expect_same_results([links.last], [], window, [:target], reify: true)
      expect(holder).to be_persisted
    ensure
      SourceTypeTag.default_scopes = []
    end
  end
end
