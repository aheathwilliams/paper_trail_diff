# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/source_type_database'

ActiveRecord::Schema.define do
  create_table :index_spec_pages, force: true do |table|
    table.string :type
    table.string :title, null: false
    table.integer :author_id
    table.timestamps null: false
  end

  create_table :index_spec_sections, force: true do |table|
    table.string :title, null: false
    table.integer :page_id
    table.integer :featured_page_id
    table.timestamps null: false
  end
end

class IndexSpecPage < ActiveRecord::Base
  belongs_to :author, class_name: 'TrackedAuthor', optional: true
  has_many :sections, class_name: 'IndexSpecSection', foreign_key: :page_id, inverse_of: :page
  has_many :featured_sections, class_name: 'IndexSpecSection', foreign_key: :featured_page_id,
                               inverse_of: :featured_page
  has_paper_trail
end

# PaperTrail records a subclass under its base class, and so does the index.
class IndexSpecLandingPage < IndexSpecPage
end

class IndexSpecPromoPage < IndexSpecLandingPage
end

class IndexSpecArchivePage < IndexSpecPage
end

class IndexSpecSection < ActiveRecord::Base
  belongs_to :page, class_name: 'IndexSpecPage', optional: true, inverse_of: :sections
  belongs_to :featured_page, class_name: 'IndexSpecPage', optional: true,
                             inverse_of: :featured_sections
  has_paper_trail
end

RSpec.describe PaperTrailDiff::PreparedActivityIndex do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [IndexSpecSection, IndexSpecPage, TrackedComment, TrackedArticle, TrackedAuthor,
     TrackedTag, SourceTypeLink, SourceTypeAuthor, SourceTypeTag].each(&:delete_all)
  end

  def statements(&block)
    count = 0
    callback = lambda do |*, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    count
  end

  def range(start_boundary, end_boundary)
    PaperTrailDiff::ActivityRange.new(start_boundary, end_boundary)
  end

  # An index over everything from `origin`, as a batch builds one for all its
  # roots, with each call narrowing to one root's range.
  def index_for(origin, loads, root_versions: [])
    records = PaperTrailDiff::PreparedRecordIndex.new(origin)
    loads.each { |model, ids| records.load(model, ids) }
    described_class.new(records, root_versions, start_at: origin, end_at: Time.now.utc)
  end

  def sections
    IndexSpecPage.reflect_on_association(:sections)
  end

  it 'reads root versions as given and every other record from the record index' do
    origin = Time.now.utc
    root, other = %w[Root Other].map { |title| IndexSpecLandingPage.create!(title: title) }
    given = [root.versions.reorder(:id).first]
    root.update!(title: 'Root again')
    other.update!(title: 'Other again')
    index = index_for(origin, { IndexSpecPage => [root.id, other.id] }, root_versions: given)

    expect(index.versions(IndexSpecLandingPage, [root.id, other.id.to_s]))
      .to eq(given + other.versions.reorder(:id).to_a)
    expect([index.loaded?(IndexSpecPage, other.id), index.loaded?(IndexSpecPage, 0)])
      .to eq([true, false])
  end

  # The batch registers each record under the class it found it as, and asks
  # for its children under the class an association names.
  it 'reads every record registered under a class or its subclass, once each' do
    origin = Time.now.utc
    first, second = %w[First Second].map { |title| IndexSpecLandingPage.create!(title: title) }
    kept = [first, second].map { |page| IndexSpecSection.create!(title: 'kept', page: page) }
    index = index_for(origin, { IndexSpecSection => kept.map(&:id) })
    index.register(IndexSpecLandingPage, [first.id])
    index.register(IndexSpecPage, [second.id])
    index.register(IndexSpecPage, [second.id])

    found = index.child_ids(IndexSpecLandingPage, [first.id, second.id], sections,
                            range(origin, Time.now.utc))

    expect(found).to match_array(kept.map(&:id))
  end

  # Children are found by key across the whole table, so a subclass keeps the
  # records that had its class or a descendant's at some point, and of those
  # the versions in the range that had it before or after.
  it 'keeps the records and versions an STI subclass had, leaving out its siblings' do
    origin = Time.now.utc
    plain = IndexSpecPage.create!(title: 'Plain')
    sibling, joining = %w[Sibling Joining].map { |name| IndexSpecArchivePage.create!(title: name) }
    leaving = IndexSpecLandingPage.create!(title: 'Leaving')
    promo = IndexSpecPromoPage.create!(title: 'Promo')
    pages = [plain, sibling, joining, leaving, promo]
    start = Time.now.utc
    pages.each { |page| page.update!(title: "#{page.title} again") }
    joined = IndexSpecPage.find(joining.id).tap { |row| row.update!(type: 'IndexSpecLandingPage') }
    left = IndexSpecPage.find(leaving.id).tap { |row| row.update!(type: 'IndexSpecArchivePage') }
    [joined, left].each { |page| page.update!(title: 'Moved') }
    ids = pages.map(&:id)
    index = index_for(origin, { IndexSpecPage => ids })
    window = range(start, Time.now.utc)
    inside = ->(page) { page.versions.reorder(:id).select { |version| window.include?(version) } }

    expect(index.member_ids(IndexSpecLandingPage, ids)).to eq([joining.id, leaving.id, promo.id])
    expect(index.member_versions(IndexSpecLandingPage, ids, window).map(&:id))
      .to eq([*inside.call(joining).drop(1), *inside.call(leaving).take(2),
              *inside.call(promo)].map(&:id))
    expect(index.member_versions(IndexSpecPage, ids, window))
      .to eq(pages.flat_map { |page| inside.call(page) })
  end

  # A base class takes every row, so it reads nothing from the record index.
  it 'keeps every record and version of a base class without reading their history' do
    origin = Time.now.utc
    page = IndexSpecPage.create!(title: 'Unloaded')
    version = page.versions.last
    index = index_for(origin, {}, root_versions: [version])

    expect(index.member_ids(IndexSpecPage, [page.id, 0])).to eq([page.id, 0])
    expect(index.member_versions(IndexSpecPage, [page.id], range(origin, Time.now.utc)))
      .to eq([version])
  end

  # PT-AT records a version's foreign keys after its change: the latest one
  # before the range names the children at its start. A section moved away
  # before the index's own start, or saved after its end, is outside it.
  it "reads a page's sections at the range start, inside it, and live at a current end" do
    page, other, bare = %w[Page Other Bare].map { |title| IndexSpecPage.create!(title: title) }
    early = IndexSpecSection.create!(title: 'early', page: page)
    early.update!(page: other)
    origin = Time.now.utc
    kept, moved, gone = %w[kept moved gone].map do |title|
      IndexSpecSection.create!(title: title, page: page)
    end
    adopted = IndexSpecSection.create!(title: 'adopted')
    moved.update!(page: other)
    gone.destroy!
    start = Time.now.utc
    added = IndexSpecSection.create!(title: 'added', page: page)
    added.update!(title: 'added again')
    finish = TrackedAuthor.create!(name: 'End').versions.last
    late = IndexSpecSection.create!(title: 'late', page: page)
    # Saved without a version, so only the live row has it.
    IndexSpecSection.where(id: adopted.id).update_all(page_id: page.id)
    ids = [early, kept, moved, gone, adopted, added, late].map(&:id)
    index = index_for(origin, { IndexSpecSection => ids })
    index.register(IndexSpecPage, [page.id, other.id, bare.id])
    IndexSpecSection.create!(title: 'fleeting', page: page).destroy!

    closed = index.child_ids(IndexSpecPage, [page.id], sections, range(start, finish))
    current = index.child_ids(IndexSpecPage, [page.id, bare.id], sections,
                              range(start, Time.now.utc))
    both = index.child_ids(IndexSpecPage, [page.id, other.id], sections, range(start, finish))

    expect(closed).to contain_exactly(kept.id, added.id)
    expect(current).to contain_exactly(kept.id, added.id, late.id, adopted.id)
    expect(both).to contain_exactly(kept.id, added.id, moved.id, early.id)
  end

  it 'reads the rows of each association once for every page' do
    origin = Time.now.utc
    page, other = %w[Page Other].map { |title| IndexSpecLandingPage.create!(title: title) }
    listed = IndexSpecSection.create!(title: 'listed', page: other)
    featured = IndexSpecSection.create!(title: 'featured', featured_page: page)
    index = index_for(origin, { IndexSpecSection => [listed.id, featured.id] })
    index.register(IndexSpecPage, [page.id, other.id])
    index.register(IndexSpecSection, [listed.id, featured.id])
    window = range(origin, Time.now.utc)
    index.child_ids(IndexSpecLandingPage, [page.id], sections, window)
    owner = ->(name) { IndexSpecSection.reflect_on_association(name) }
    owners = lambda do |name|
      index.target_rows(IndexSpecSection, [featured.id], owner.call(name), window)
           .map(&:foreign_key_id).uniq
    end

    queries = statements do
      expect(index.child_ids(IndexSpecPage, [other.id], sections, window)).to eq([listed.id])
    end
    expect(queries).to eq(0)
    expect(index.child_ids(IndexSpecPage, [page.id],
                           IndexSpecPage.reflect_on_association(:featured_sections), window))
      .to eq([featured.id])
    expect([owners.call(:page), owners.call(:featured_page)]).to eq([[nil], [page.id]])
  end

  # The version a range ends at names the author after it, which the range
  # never reached.
  it 'reads the authors a page pointed at in the range, and its live one at a current end' do
    origin = Time.now.utc
    first, second, third = %w[Ann Bea Cy].map { |name| TrackedAuthor.create!(name: name) }
    page, other, gone = %w[Page Other Gone].map do |title|
      IndexSpecPage.create!(title: title, author: first)
    end
    unversioned = PaperTrail.request(enabled: false) do
      IndexSpecPage.create!(title: 'Unversioned', author: first)
    end
    other.update!(author: second)
    gone.destroy!
    start = Time.now.utc
    page.update!(author: second)
    page.update!(author: third)
    closing = page.versions.reorder(:id).last
    ids = [page, other, gone, unversioned].map(&:id)
    index = index_for(origin, { IndexSpecPage => ids })
    index.register(IndexSpecPage, ids)
    author = IndexSpecPage.reflect_on_association(:author)
    fields = ->(rows) { rows.map { |row| [row.owner_id, row.foreign_key_id, row.event] } }

    closed = index.target_rows(IndexSpecLandingPage, [page.id, gone.id], author,
                               range(start, closing))
    current = index.target_rows(IndexSpecPage, [page.id, unversioned.id], author,
                                range(start, Time.now.utc))

    expect(fields.call(closed))
      .to contain_exactly([page.id, first.id, 'create'], [page.id, second.id, 'update'])
    expect(fields.call(current)).to contain_exactly(
      [page.id, first.id, 'create'], [page.id, second.id, 'update'],
      [page.id, third.id, 'update'], [page.id, third.id, nil], [unversioned.id, first.id, nil]
    )
    queries = statements do
      found = index.target_rows(IndexSpecPage, [other.id], author, range(start, closing))
      expect(fields.call(found)).to eq([[other.id, second.id, 'update']])
    end
    expect(queries).to eq(0)
  end

  def checkpoint(article)
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    article.versions.reorder(:id).last
  end

  # A transaction's id is its first version's, which here is a comment's, and
  # the comment's own `belongs_to` rows share it.
  it 'reads the tags each selected transaction recorded, for registered articles only' do
    origin = Time.now.utc
    article, other = %w[Tagged Other].map { |title| TrackedArticle.create!(title: title) }
    ruby, rails = %w[ruby rails].map { |name| TrackedTag.create!(name: name) }
    article.tags << ruby
    TrackedArticle.transaction do
      article.comments.create!(body: 'First in the transaction')
      TrackedArticle.find(article.id).paper_trail.save_with_version
    end
    tagged = article.versions.reorder(:id).last
    other.tags << rails
    other_tagged = checkpoint(other)
    ruby.articles << other
    TrackedTag.transaction { TrackedTag.find(ruby.id).paper_trail.save_with_version }
    retagged = ruby.versions.reorder(:id).last
    untracked = Struct.new(:id).new(tagged.id)
    index = index_for(origin, { TrackedArticle => [article.id, other.id], TrackedTag => [ruby.id] })
    index.register(TrackedArticle, [article.id])
    index.register(TrackedTag, [ruby.id])
    rows = lambda do |model, selected, name|
      index.habtm_rows(model, selected, model.reflect_on_association(name)).map(&:foreign_key_id)
    end

    expect(rows.call(TrackedArticle, [tagged, tagged, untracked], :tags)).to eq([ruby.id])
    queries = statements { expect(rows.call(TrackedArticle, [other_tagged], :tags)).to eq([]) }
    expect(queries).to eq(0)
    expect(rows.call(TrackedTag, [retagged], :articles)).to contain_exactly(article.id, other.id)
  end

  describe '#join_versions' do
    # Of a link's versions, only those it named an author before or after
    # are on a path that names its type.
    it 'keeps a version of a source_type join row only when the row had that type' do
      origin = Time.now.utc
      author = SourceTypeAuthor.create!(name: 'Author')
      tag = SourceTypeTag.create!(name: 'Tag')
      link = SourceTypeLink.create!(target: tag, origin: author)
      [author, author, tag, tag].each_with_index do |target, index|
        link.update!(target: target, origin_id: index)
      end
      versions = link.versions.reorder(:id).to_a
      # Saved before the link had a type column: no type, and the author after.
      versions[1].update_columns(object: versions[1].object.sub(/^target_type:.*\n/, ''))
      index = index_for(origin, { SourceTypeLink => [link.id] })
      group = { model: SourceTypeLink, versions: versions }

      %i[linked_authors symbol_authors].each do |name|
        expect(index.join_versions(group, SourceTypeHolder.reflect_on_association(name)))
          .to eq(versions[1..3])
      end
      expect(index.join_versions(group, TrackedAuthor.reflect_on_association(:comments)))
        .to eq(versions)
    end
  end

  it 'explains missing graph registration instead of leaking a hash lookup error' do
    records = PaperTrailDiff::PreparedRecordIndex.new(Time.now.utc - 60)
    index = described_class.new(records, [], start_at: Time.now.utc - 60, end_at: Time.now.utc)

    expect do
      index.child_ids(TrackedArticle, [1], TrackedArticle.reflect_on_association(:comments),
                      PaperTrailDiff::ActivityRange.new(Time.now.utc - 60, Time.now.utc))
    end.to raise_error(PaperTrailDiff::ConfigurationError, /missing TrackedArticle.*register/)
  end

  it 'matches SQL candidate selection for pre-window moves, destroys, ties and boundaries' do
    origin = Time.utc(2030, 1, 1)
    # The second entry for identity 2 belongs to an unselected owner. It must
    # still disqualify the older membership, just as the SQL subquery does.
    events = [[1, 1, 'create', true], [2, 1, 'create', true], [2, 5, 'update', false],
              [3, 1, 'create', true], [3, 5, 'destroy', true],
              [4, 5, 'create', true], [4, 5, 'update', true],
              [5, 10, 'create', true], [5, 20, 'destroy', true],
              [6, 21, 'create', true], [7, 5, 'create', true], [7, 12, 'update', true],
              [8, 1, 'create', true], [8, 10, 'destroy', true]]
    # The spec clock moves a version saved out of order past the last one, so
    # each time is set after saving to keep these ties and boundaries.
    candidates = events.filter_map do |id, offset, event, selected_owner|
      version = PaperTrail::Version.create!(item_type: 'TrackedComment', item_id: id,
                                            event: event)
      version.update_columns(created_at: origin + offset)
      version if selected_owner
    end
    records = PaperTrailDiff::PreparedRecordIndex.new(origin)
    records.load(TrackedComment, (1..8).to_a)
    index = described_class.new(records, [], start_at: origin, end_at: origin + 30)
    relation = PaperTrail::Version.where(id: candidates.map(&:id))

    [10, 15].each do |start|
      range = PaperTrailDiff::ActivityRange.new(origin + start, origin + 20)
      expected = PaperTrailDiff::VersionAssociationCandidateScope.new(
        PaperTrail::Version, range.start_time, end_at: range.end_time
      ).call(relation).pluck(:id)
      actual = candidates.select do |version|
        index.send(:eligible_version?, TrackedComment, version.item_id, version.created_at,
                   version.event, range)
      end.map(&:id)

      expect(actual).to match_array(expected)
      expect(actual).not_to include(candidates.find { |version| version.item_id.to_s == '2' }.id)
    end
  end
end
