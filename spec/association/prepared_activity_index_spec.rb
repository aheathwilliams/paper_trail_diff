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

ActiveRecord::Schema.define do
  create_table :index_spec_boards, force: true do |table|
    table.string :type
    table.string :code
    table.integer :featured_link_id
    table.timestamps null: false
  end

  create_table :index_spec_links, force: true do |table|
    table.string :type
    table.integer :board_id
    table.string :board_type
    table.string :board_code
    table.integer :target_id
    table.string :subject_type
    table.integer :subject_id
    table.boolean :active, null: false, default: true
    table.timestamps null: false
  end

  create_table :index_spec_targets, force: true do |table|
    table.string :name
    table.timestamps null: false
  end

  create_table :index_spec_notes, force: true do |table|
    table.integer :target_id
    table.timestamps null: false
  end
end

class IndexSpecTarget < ActiveRecord::Base
  has_many :notes, class_name: 'IndexSpecNote', foreign_key: :target_id
  has_paper_trail
end

class IndexSpecNote < ActiveRecord::Base
  has_paper_trail
end

class IndexSpecLink < ActiveRecord::Base
  belongs_to :board, class_name: 'IndexSpecBoard', optional: true
  belongs_to :target, class_name: 'IndexSpecTarget', optional: true
  belongs_to :subject, polymorphic: true, optional: true
  has_many :sibling_links, through: :board, source: :links
  has_paper_trail
end

class IndexSpecPinnedLink < IndexSpecLink
end

# A through over each kind of join association a join row's own state can
# place under an owner, or cannot.
class IndexSpecBoard < ActiveRecord::Base
  links = { class_name: 'IndexSpecLink', foreign_key: :board_id }
  has_many :links, **links
  has_many :targets, through: :links
  has_many :active_links, -> { where(active: true) }, **links
  has_many :active_targets, through: :active_links, source: :target
  # Ranked, its order is not total; a through reads its parts unranked.
  has_many :first_active_links, -> { where(active: true).order(:active).limit(1) }, **links
  has_many :first_active_targets, through: :first_active_links, source: :target
  has_many :sql_links, -> { where('active = ?', true) }, **links
  has_many :sql_targets, through: :sql_links, source: :target
  has_many :pinned_links, class_name: 'IndexSpecPinnedLink', foreign_key: :board_id
  has_many :pinned_targets, through: :pinned_links, source: :target
  has_many :coded_links, class_name: 'IndexSpecLink', foreign_key: %i[board_id board_code],
                         primary_key: %i[id code]
  has_many :coded_targets, through: :coded_links, source: :target
  has_many :target_notes, through: :targets, source: :notes
  belongs_to :featured_link, class_name: 'IndexSpecLink', optional: true
  has_one :featured_subject, through: :featured_link, source: :subject,
                             source_type: 'IndexSpecTarget'
  has_paper_trail
end

# Declares a polymorphic join association below the base class, so a row's
# type may name the owner's class, its base class, or this one.
class IndexSpecTeamBoard < IndexSpecBoard
  has_many :held_links, class_name: 'IndexSpecLink', as: :board
  has_many :held_targets, through: :held_links, source: :target
end

class IndexSpecSquadBoard < IndexSpecTeamBoard
end

RSpec.describe PaperTrailDiff::PreparedActivityIndex do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [IndexSpecSection, IndexSpecPage, TrackedComment, TrackedArticle, TrackedAuthor,
     TrackedTag, SourceTypeLink, SourceTypeAuthor, SourceTypeTag, SourceTypeHolder,
     IndexSpecBoard, IndexSpecLink, IndexSpecTarget, IndexSpecNote].each(&:delete_all)
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
    described_class.new(records, root_versions, start_at: origin)
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
  # before the index's own start is outside it. One saved after the range's
  # end, even after the index was built, or only in the live row, is a
  # candidate whatever the end: a key written without a version is recorded
  # only after it.
  it "reads a page's sections from the range start onward, and live ones" do
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
    fleeting = IndexSpecSection.create!(title: 'fleeting', page: page).tap(&:destroy!)

    closed = index.child_ids(IndexSpecPage, [page.id], sections, range(start, finish))
    current = index.child_ids(IndexSpecPage, [page.id, bare.id], sections,
                              range(start, Time.now.utc))
    both = index.child_ids(IndexSpecPage, [page.id, other.id], sections, range(start, finish))

    later = [late.id, adopted.id, fleeting.id]
    expect(closed).to contain_exactly(kept.id, added.id, *later)
    expect(current).to contain_exactly(kept.id, added.id, *later)
    expect(both).to contain_exactly(kept.id, added.id, moved.id, early.id, *later)
  end

  # A range starting at a version starts before that version's transaction
  # (see VersionBoundary.transaction_start), so a section that left the page
  # earlier in it was still one of the page's sections at the start.
  it 'reads the sections that left a page in the transaction a version start opens' do
    page, other = %w[Page Other].map { |title| IndexSpecPage.create!(title: title) }
    moved, gone = %w[moved gone].map { |title| IndexSpecSection.create!(title: title, page: page) }
    start = IndexSpecPage.transaction do
      moved.update!(page: other)
      gone.destroy!
      page.update!(title: 'Renamed')
      page.versions.reorder(:created_at, :id).last
    end
    origin = PaperTrailDiff::VersionBoundary.transaction_start([start], start.created_at)
    index = index_for(origin, { IndexSpecSection => [moved.id, gone.id] })
    index.register(IndexSpecPage, [page.id, other.id])

    expect(index.child_ids(IndexSpecPage, [page.id], sections, range(start, Time.now.utc)))
      .to contain_exactly(moved.id, gone.id)
    expect(index.child_ids(IndexSpecPage, [page.id], sections,
                           range(start.created_at, Time.now.utc))).to be_empty
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
    # Children are read for each owner class, whose own name a polymorphic
    # row can store, so both reads are of the subclass the pages are.
    index.child_ids(IndexSpecLandingPage, [page.id], sections, window)
    owner = ->(name) { IndexSpecSection.reflect_on_association(name) }
    owners = lambda do |name|
      index.target_rows(IndexSpecSection, [featured.id], owner.call(name), window)
           .map(&:foreign_key_id).uniq
    end

    queries = statements do
      expect(index.child_ids(IndexSpecLandingPage, [other.id], sections, window))
        .to eq([listed.id])
    end
    expect(queries).to eq(0)
    expect(index.child_ids(IndexSpecPage, [page.id],
                           IndexSpecPage.reflect_on_association(:featured_sections), window))
      .to eq([featured.id])
    expect([owners.call(:page), owners.call(:featured_page)]).to eq([[nil], [page.id]])
  end

  # The version a range ends at names the author after it, which the range
  # never reached, but a key written without a version is recorded only after
  # it too, so every author from the start onward is a candidate, and the live
  # one. So is every author a page's recorded states name, without an event,
  # which a key PT-AT never saw reaches only that way.
  it 'reads the authors a page pointed at from the range start onward, and its live one' do
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

    recorded = [[page.id, first.id, nil], [page.id, second.id, nil], [page.id, third.id, nil]]
    expect(fields.call(closed)).to contain_exactly(
      [page.id, first.id, 'create'], [page.id, second.id, 'update'],
      [page.id, third.id, 'update'], [page.id, third.id, nil], *recorded, [gone.id, first.id, nil]
    )
    expect(fields.call(current)).to contain_exactly(
      [page.id, first.id, 'create'], [page.id, second.id, 'update'],
      [page.id, third.id, 'update'], [page.id, third.id, nil], [unversioned.id, first.id, nil],
      *recorded, [unversioned.id, first.id, nil]
    )
    queries = statements do
      found = index.target_rows(IndexSpecPage, [other.id], author, range(start, closing))
      expect(fields.call(found))
        .to eq([[other.id, second.id, 'update'], [other.id, second.id, nil],
                [other.id, first.id, nil], [other.id, second.id, nil]])
    end
    expect(queries).to eq(0)
  end

  # The latest row before the start names the author a page had there, so the
  # rows it replaced cannot matter, and are not read.
  it 'reads no author row that a later one before the start replaced' do
    first, second, third = %w[Ann Bea Cy].map { |name| TrackedAuthor.create!(name: name) }
    page = IndexSpecPage.create!(title: 'Page', author: first)
    page.update!(author: second)
    origin = Time.now.utc
    page.update!(author: third)
    index = index_for(origin, { IndexSpecPage => [page.id] })
    index.register(IndexSpecPage, [page.id])

    historical, = index.send(:target_candidates, IndexSpecPage,
                             IndexSpecPage.reflect_on_association(:author))

    expect(historical.fetch(page.id.to_s).map(&:foreign_key_id))
      .to contain_exactly(second.id, third.id)
  end

  # Each state a link recorded names its target by type and id; one with no
  # target names none, and a key of two columns is left to the record path.
  it "reads the targets an owner's recorded states name" do
    author = SourceTypeAuthor.create!(name: 'Author')
    tag = SourceTypeTag.create!(name: 'Tag')
    link = SourceTypeLink.create!(target: author)
    [{ target: tag }, { target: nil }].each { |change| link.update!(change) }
    index = index_for(Time.now.utc - 60, { SourceTypeLink => [link.id] })
    fields = lambda do |name|
      index.send(:recorded_target_rows, SourceTypeLink, [link.id],
                 SourceTypeLink.reflect_on_association(name))
           .map { |row| [row.owner_id, row.foreign_type, row.foreign_key_id] }
    end
    composite = SourceTypeLink.reflect_on_association(:target).dup
    allow(composite).to receive(:foreign_key).and_return(Class.new(Array).new(%w[target_id x]))

    expect(fields.call(:target)).to eq([[link.id, 'SourceTypeAuthor', author.id],
                                        [link.id, 'SourceTypeTag', tag.id]])
    expect(index.send(:recorded_target_rows, SourceTypeLink, [link.id], composite)).to eq([])
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
    let!(:origin) { Time.now.utc }
    let(:board) { IndexSpecBoard.create! }
    let(:owners) { { model: IndexSpecBoard, ids: [board.id] } }

    # The join versions of `records` the named through keeps, and all of
    # them, in order. Without `load`, the index holds no state to read.
    def join_versions(owners, records, reflection, load: true)
      records = Array(records)
      model = records.first.class.base_class
      versions = records.flat_map { |record| record.versions.reorder(:id).to_a }
      index = index_for(origin, load ? { model => records.map(&:id) } : {})
      [index.join_versions(owners, { model: model, versions: versions }, reflection), versions]
    end

    def through(name, model = IndexSpecBoard)
      model.reflect_on_association(name)
    end

    # A version saved under another owner changes nothing this one shows.
    it 'keeps the versions a join row saved while it joined one of the owners' do
      other = IndexSpecBoard.create!
      link = IndexSpecLink.create!(board_id: board.id)
      [{ board_id: other.id }, { active: false }, { board_id: board.id }, { board_id: nil },
       { active: true }].each { |change| link.update!(change) }

      kept, versions = join_versions(owners, link, through(:targets))

      expect(kept).to eq(versions.values_at(0, 1, 3, 4))
    end

    # By its states before and after the transaction, as a record in the
    # tree is judged: one that existed only inside it joined nobody.
    it 'judges the versions a row saved in one transaction together' do
      other = IndexSpecBoard.create!
      fleeting, returning = IndexSpecLink.transaction do
        [IndexSpecLink.create!(board_id: board.id).tap(&:destroy!),
         IndexSpecLink.create!(board_id: board.id)]
      end
      IndexSpecLink.transaction do
        returning.update!(board_id: other.id)
        returning.update!(board_id: board.id)
      end

      kept, versions = join_versions(owners, [fleeting, returning], through(:targets))

      expect(versions.length).to eq(5)
      expect(kept).to match_array(versions.last(3))
    end

    # PaperTrail leaves the transaction blank outside one.
    it 'judges each version saved outside a transaction alone' do
      link = IndexSpecLink.create!(board_id: board.id)
      other = IndexSpecBoard.create!
      [{ board_id: other.id }, { active: false }].each { |change| link.update!(change) }
      link.versions.update_all(transaction_id: nil)

      kept, versions = join_versions(owners, link, through(:targets))

      expect(kept).to eq(versions.first(2))
    end

    it "reads an `as:` join row's type for each name an owner's rows may hold" do
      squad = IndexSpecSquadBoard.create!
      links = %w[IndexSpecSquadBoard IndexSpecBoard IndexSpecTeamBoard IndexSpecPage].map do |type|
        IndexSpecLink.create!(board_id: squad.id, board_type: type)
      end
      owners = { model: IndexSpecSquadBoard, ids: [squad.id] }

      kept, versions = join_versions(owners, links, through(:held_targets, IndexSpecTeamBoard))

      expect(kept).to eq(versions.first(3))
    end

    it 'keeps a join row of an association to a subclass only while it was of that class' do
      link = IndexSpecPinnedLink.create!(board_id: board.id)
      link.update!(type: 'IndexSpecLink')
      IndexSpecLink.find(link.id).update!(active: false)

      kept, versions = join_versions(owners, link, through(:pinned_targets))

      expect(kept).to eq(versions.first(2))
    end

    it "leaves out the versions a join row saved outside its association's scope" do
      link = IndexSpecLink.create!(board_id: board.id)
      [{ active: false }, { target_id: 1 }, { active: true }].each { |change| link.update!(change) }

      %i[active_targets first_active_targets].each do |name|
        kept, versions = join_versions(owners, link, through(name))
        expect(kept).to eq(versions.values_at(0, 1, 3))
      end
      kept, versions = join_versions(owners, link, through(:sql_targets))
      expect(kept).to eq(versions)
    end

    # The owner's key, rows further down, or a key of two columns joins them,
    # so no state of the row is read.
    it 'keeps every version of join rows a key on the row alone cannot place' do
      target = IndexSpecTarget.create!
      target.update!(name: 'renamed')
      other = IndexSpecBoard.create!
      link = IndexSpecLink.create!(board_id: other.id)
      link.update!(active: false)
      # An Array subclass, as a composite key may be, so only `is_a?` sees it.
      composite = through(:coded_targets)
      key = Class.new(Array).new(%w[board_id board_code])
      allow(composite.through_reflection).to receive(:foreign_key).and_return(key)

      [[owners, target, through(:target_notes)], [owners, link, composite],
       [{ model: IndexSpecLink, ids: [link.id] }, board, through(:sibling_links, IndexSpecLink)]]
        .each do |owners, record, reflection|
          kept, versions = join_versions(owners, record, reflection, load: false)
          expect(kept).to eq(versions)
        end
    end

    # Of a link's versions, only those it named an author before or after
    # are on a path that names its type.
    it 'keeps a version of a source_type join row only when the row had that type' do
      holder = SourceTypeHolder.create!(name: 'Holder')
      author = SourceTypeAuthor.create!(name: 'Author')
      tag = SourceTypeTag.create!(name: 'Tag')
      link = SourceTypeLink.create!(holder: holder, target: tag, origin: author)
      [author, author, tag, tag].each_with_index do |target, index|
        link.update!(target: target, origin_id: index)
      end
      versions = link.versions.reorder(:id).to_a
      # Saved before the link had a type column: no type, and the author after.
      versions[1].update_columns(object: versions[1].object.sub(/^target_type:.*\n/, ''))
      index = index_for(origin, { SourceTypeLink => [link.id] })
      group = { model: SourceTypeLink, versions: versions }
      owners = { model: SourceTypeHolder, ids: [holder.id] }

      %i[linked_authors symbol_authors].each do |name|
        expect(index.join_versions(owners, group, SourceTypeHolder.reflect_on_association(name)))
          .to eq(versions[1..3])
      end
    end

    it 'reads the type of a join row an owner reaches through its own key' do
      link = IndexSpecLink.create!(subject: IndexSpecTarget.create!)
      link.update!(subject: IndexSpecNote.create!)
      link.update!(active: false)

      kept, versions = join_versions({ model: IndexSpecBoard, ids: [] }, link,
                                     through(:featured_subject))

      expect(kept).to eq(versions.first(2))
    end
  end

  it 'explains missing graph registration instead of leaking a hash lookup error' do
    records = PaperTrailDiff::PreparedRecordIndex.new(Time.now.utc - 60)
    index = described_class.new(records, [], start_at: Time.now.utc - 60)

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
    index = described_class.new(records, [], start_at: origin)
    relation = PaperTrail::Version.where(id: candidates.map(&:id))

    [10, 15].each do |start|
      range = PaperTrailDiff::ActivityRange.new(origin + start, origin + 20)
      expected = PaperTrailDiff::VersionAssociationCandidateScope.new(
        PaperTrail::Version, range.start_time
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
