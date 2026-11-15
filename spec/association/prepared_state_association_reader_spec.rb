# frozen_string_literal: true

require_relative '../support/source_type_database'

# The reader builds snapshots from stored attributes. Each result here is
# checked against what Active Record read when the version was saved.
RSpec.describe PaperTrailDiff::PreparedStateAssociationReader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedAuthorship, TrackedArticle, TrackedAuthor, SourceTypeLink,
     SourceTypeHolder, SourceTypeAuthor, SourceTypeTag].each(&:delete_all)
  end

  # Who the association holds now, as Active Record reads it.
  def live_members(root, name)
    Array(root.class.find(root.id).public_send(name)).map do |member|
      [member.class.name, member.id]
    end.sort
  end

  # Who the association held at each version, as prepared history reads it.
  def read_members(root, from, to, name)
    analysis = PaperTrailDiff.analyze(root, from: from, to: to, associations: [name],
                                            activity: true, snapshots: true)
    [analysis.from_snapshot, analysis.to_snapshot].map do |snapshot|
      snapshot.associations.fetch(name.to_s).records.map { |record| [record.type, record.id] }.sort
    end
  end

  def expect_members(root, versions, name, before:, after:)
    expect(read_members(root, *versions, name)).to eq([before, after])
    expect(before).not_to eq(after)
  end

  def checkpoint(record)
    record.class.transaction do
      fresh = record.class.find(record.id)
      fresh.paper_trail.save_with_version
      fresh.versions.reorder(:id).last
    end
  end

  # How often a timeline reads scope conditions, for a root with that many
  # comments.
  def condition_lookups(children)
    article = TrackedArticle.create!(title: 'Root')
    children.times { |index| article.comments.create!(body: "Comment #{index}") }
    article.update!(title: 'Edited')
    lookups = 0
    allow_any_instance_of(PaperTrailDiff::ScopeCondition::Cache).to receive(:call)
      .and_wrap_original do |original, *arguments, **options|
        lookups += 1
        original.call(*arguments, **options)
      end
    SpecTimelines.timeline(article, associations: [:comments])
    lookups
  ensure
    RSpec::Mocks.space.reset_all
  end

  # Every child is placed at every boundary, so what the owner and the
  # reflection fix is read once for all of them.
  it "reads the scope's condition once for all of an owner's children" do
    expect(condition_lookups(4)).to eq(condition_lookups(1))
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
    befores = [ada, bea].map { |author| live_members(author, :comments) }
    moved.update!(author: bea)
    travelling.update!(article: kept)
    destroyed.destroy!
    edited.update!(body: 'edited again')
    gone.destroy!
    kept.comments.create!(body: 'new')
    ends = [ada, bea].map { |author| checkpoint(author) }

    [ada, bea].each_with_index do |author, index|
      expect_members(author, [starts[index], ends[index]], :comments,
                     before: befores[index], after: live_members(author, :comments))
    end
  end

  it 'reads a has_many :through whose source is a belongs_to' do
    article = TrackedArticle.create!(title: 'Article')
    writer, editor = %w[Writer Editor].map { |name| TrackedAuthor.create!(name: name) }
    TrackedAuthorship.create!(article: article, author: writer, role: 'writer')
    leaving = TrackedAuthorship.create!(article: article, author: editor, role: 'editor')
    start = checkpoint(article)
    before = live_members(article, :contributors)
    writer.update!(name: 'Writer renamed')
    leaving.destroy!
    finish = checkpoint(article)

    expect_members(article, [start, finish], :contributors,
                   before: before, after: live_members(article, :contributors))
  end

  describe 'a polymorphic source' do
    # Who each record's association held when its start version was saved.
    def befores(holder, links)
      befores = { holder => %i[linked_authors symbol_authors].to_h do |name|
        [name, live_members(holder, name)]
      end }
      links.each { |link| befores[link] = { target: live_members(link, :target) } }
      befores
    end

    def history
      holder = SourceTypeHolder.create!(name: 'Holder')
      ada = SourceTypeAuthor.create!(name: 'Ada')
      tag = SourceTypeTag.create!(name: 'Same id', id: ada.id + 1)
      bea = SourceTypeAuthor.create!(name: 'Bea', id: tag.id)
      to_tag = SourceTypeLink.create!(holder: holder, target: ada)
      to_author = SourceTypeLink.create!(holder: holder, target: tag)
      start = checkpoint(holder)
      starts = [to_tag, to_author].map { |link| checkpoint(link) }
      before = befores(holder, [to_tag, to_author])
      ada.update!(name: 'Ada renamed')
      to_tag.update!(target: SourceTypeTag.create!(name: 'New tag'))
      to_author.update!(target: bea)
      tag.update!(name: 'Same id renamed')
      [holder, start, [to_tag, to_author], starts, before]
    end

    it 'reads a through with source_type, only for links of that type' do
      holder, start, _links, _starts, before = history
      finish = checkpoint(holder)

      %i[linked_authors symbol_authors].each do |name|
        expect_members(holder, [start, finish], name, before: before.fetch(holder).fetch(name),
                                                      after: live_members(holder, name))
      end
    end

    it 'reads a polymorphic belongs_to of each type a link names' do
      _holder, _start, links, starts, before = history
      ends = links.map { |link| checkpoint(link) }

      links.each_with_index do |link, index|
        expect_members(link, [starts[index], ends[index]], :target,
                       before: before.fetch(link).fetch(:target),
                       after: live_members(link, :target))
      end
    end

    # The tag a link moves to is outside the scope, so that link ends with no
    # target.
    it 'reads a target whose default scope is plain conditions, keeping it out' do
      _holder, _start, links, starts, before = history
      ends = links.map { |link| checkpoint(link) }
      hidden = links.first.target_id
      SourceTypeTag.class_eval { default_scope { where.not(id: hidden) } }

      expect_members(links.first, [starts.first, ends.first], :target,
                     before: before.fetch(links.first).fetch(:target), after: [])
      expect_members(links.last, [starts.last, ends.last], :target,
                     before: before.fetch(links.last).fetch(:target),
                     after: live_members(links.last, :target))
      steps = SpecTimelines.activity_timeline(
        links.first, from: starts.first, to: ends.first, associations: [:target], snapshots: true
      )
      expect(steps.last.to_snapshot.associations.fetch('target').records).to eq([])
    ensure
      SourceTypeTag.default_scopes = []
    end

    it 'refuses a type naming no class, and a target scope it cannot read' do
      holder, start, links, = history
      SourceTypeLink.where(id: links.first.id).update_all(target_type: 'RenamedModel')
      SourceTypeTag.class_eval { default_scope { where("name <> 'hidden'") } }
      window = start.created_at..Time.now.utc

      expect { PaperTrailDiff.analyze(links.first, within: window, associations: [:target]) }
        .to raise_error(PaperTrailDiff::IncompleteAssociationHistoryError, /RenamedModel/)
      expect { PaperTrailDiff.analyze(links.last, within: window, associations: [:target]) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        /SourceTypeLink#target cannot be read from history/)
      expect(holder).to be_persisted
    ensure
      SourceTypeTag.default_scopes = []
    end
  end
end
