# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/source_type_database'

ActiveRecord::Schema.define do
  create_table :traversal_notes, force: true do |table|
    table.string :body
    table.references :holder, polymorphic: true
    table.integer :reviewer_id
    table.timestamps null: false
  end
end

# Apart from the polymorphic notes, only reflections are read, so these reuse
# the fixture tables.
class TraversalNote < ActiveRecord::Base
  belongs_to :holder, polymorphic: true, optional: true
  belongs_to :reviewer, class_name: 'TrackedAuthor', optional: true
  has_many :holder_replies, through: :holder, source: :replies
end

class TraversalNamedTag < ActiveRecord::Base
  self.table_name = 'tracked_tags'
  default_scope { where.not(name: '') }
end

class TraversalArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  belongs_to :author, class_name: 'TrackedAuthor', optional: true
  has_many :comments, class_name: 'TrackedComment', foreign_key: :article_id
  has_many :notes, class_name: 'TraversalNote', as: :holder
  has_and_belongs_to_many :tags, class_name: 'TrackedTag', join_table: :tracked_articles_tags,
                                 foreign_key: :tracked_article_id,
                                 association_foreign_key: :tracked_tag_id
  has_and_belongs_to_many :labels, class_name: 'TrackedTag', join_table: :tracked_articles_tags,
                                   foreign_key: :tracked_article_id,
                                   association_foreign_key: :tracked_tag_id
  # PT-AT records only the members a scope admits when the owner saves.
  has_and_belongs_to_many :named_tags, -> { where.not(name: '') },
                          class_name: 'TrackedTag', join_table: :tracked_articles_tags,
                          foreign_key: :tracked_article_id, association_foreign_key: :tracked_tag_id
  has_and_belongs_to_many :default_named_tags, class_name: 'TraversalNamedTag',
                                               join_table: :tracked_articles_tags,
                                               foreign_key: :tracked_article_id,
                                               association_foreign_key: :tracked_tag_id
  has_many :tagged_articles, through: :tags, source: :articles
  has_many :tagged_comments, through: :tagged_articles, source: :comments
  has_paper_trail
end

class TraversalAuthor < ActiveRecord::Base
  self.table_name = 'tracked_authors'
  has_many :articles, class_name: 'TrackedArticle', foreign_key: :author_id
  has_many :article_tags, through: :articles, source: :tags
  has_many :traversal_articles, class_name: 'TraversalArticle', foreign_key: :author_id
  has_many :articles_tagged_alike, through: :traversal_articles, source: :tagged_articles
  has_paper_trail
end

class TraversalDocument < PreparedDocument
end

class TraversalSpecialDocument < TraversalDocument
end

RSpec.describe PaperTrailDiff::AssociationTraversal do
  def traversal(*paths)
    described_class.new(PaperTrailDiff::AssociationTree.build(paths))
  end

  def habtm_reason(habtm)
    "it goes through #{habtm}, a has_and_belongs_to_many, whose hidden join model has no " \
      'history to compare'
  end

  def unsupported(path, habtm)
    "unsupported association #{path}: #{habtm_reason(habtm)}"
  end

  def scoped(habtm)
    "#{habtm} is a scoped has_and_belongs_to_many, and PaperTrail records only the members " \
      'its scope admitted when the owner saved, so membership between saves cannot be ' \
      'rebuilt; replace it with a has_many :through a versioned join model'
  end

  def below_root(habtm)
    "#{habtm} is a has_and_belongs_to_many below the root, and a root checkpoint records " \
      'HABTM membership for the root alone'
  end

  describe '.belongs_to_target' do
    let(:reflection) { TraversalNote.reflect_on_association(:holder) }

    it 'returns the declared class of an ordinary belongs_to' do
      expect(described_class.belongs_to_target(TrackedArticle.reflect_on_association(:author),
                                               TrackedArticle.new))
        .to eq(TrackedAuthor)
    end

    it 'returns the class a polymorphic record names' do
      note = TraversalNote.new(holder_type: 'TrackedArticle', holder_id: 1)

      expect(described_class.belongs_to_target(reflection, note)).to eq(TrackedArticle)
    end

    it 'returns nil when a polymorphic record names no type' do
      [nil, ''].each do |type|
        expect(described_class.belongs_to_target(reflection, TraversalNote.new(holder_type: type)))
          .to be_nil
      end
    end

    it 'names the record and the column when a polymorphic type names no class' do
      note = TraversalNote.create!(body: 'Note', holder_type: 'RenamedArticle', holder_id: 1)

      expect { described_class.belongs_to_target(reflection, note) }
        .to raise_error(PaperTrailDiff::IncompleteAssociationHistoryError,
                        'association TraversalNote#holder cannot be read: ' \
                        "TraversalNote #{note.id} has holder_type RenamedArticle, which names " \
                        'no class. If the model was renamed, replace the old name in that ' \
                        'column and in the versions that recorded it.')
    end
  end

  describe '.named_class' do
    it 'returns the class a type names, or nil when it names none' do
      expect(described_class.named_class('TrackedArticle')).to eq(TrackedArticle)
      expect(described_class.named_class('RenamedArticle')).to be_nil
      expect(described_class.named_class('not a constant')).to be_nil
    end
  end

  describe '.source_type_join?' do
    def join?(name, join)
      described_class.source_type_join?(SourceTypeHolder.reflect_on_association(name), join)
    end

    it 'takes a join row only when its type column names the source type' do
      %i[linked_authors symbol_authors].each do |name|
        expect(join?(name, SourceTypeLink.new(target_type: 'SourceTypeAuthor'))).to be(true)
        expect(join?(name, SourceTypeLink.new(target_type: 'SourceTypeTag',
                                              origin_type: 'SourceTypeAuthor'))).to be(false)
        expect(join?(name, SourceTypeLink.new)).to be(false)
      end
    end

    it 'takes every join row of a through without one' do
      expect(described_class.source_type_join?(TrackedAuthor.reflect_on_association(:comments),
                                               Object.new)).to be(true)
    end
  end

  describe '.source_type_member?' do
    it 'takes a stored type only when it names the source type, and any without one' do
      %i[linked_authors symbol_authors].each do |name|
        reflection = SourceTypeHolder.reflect_on_association(name)
        expect(described_class.source_type_member?(reflection, 'SourceTypeAuthor')).to be(true)
        expect(described_class.source_type_member?(reflection, 'SourceTypeTag')).to be(false)
        expect(described_class.source_type_member?(reflection, nil)).to be(false)
      end
      expect(described_class.source_type_member?(TrackedAuthor.reflect_on_association(:comments),
                                                 nil)).to be(true)
    end
  end

  describe '.sti_member?' do
    it 'takes every row for a base class' do
      expect(described_class.sti_member?(PreparedDocument, 'type' => 'PreparedSpecialDocument'))
        .to be(true)
      expect(described_class.sti_member?(PreparedDocument, {})).to be(true)
    end

    it 'takes rows of an STI subclass and its descendants, leaving out siblings and parents' do
      member = ->(type) { described_class.sti_member?(TraversalDocument, 'type' => type) }

      expect(member.call('TraversalDocument')).to be(true)
      expect(member.call('TraversalSpecialDocument')).to be(true)
      expect(member.call('PreparedSpecialDocument')).to be(false)
      expect(member.call('PreparedDocument')).to be(false)
      expect(described_class.sti_member?(TraversalDocument, {})).to be(false)
    end
  end

  describe '.unsupported_reason' do
    def reason(model, name, root: true)
      described_class.unsupported_reason(model, model.reflect_on_association(name), root: root)
    end

    it 'accepts every supported macro and a has_many :through' do
      %i[author profile comments tags contributors].each do |name|
        expect(reason(TrackedArticle, name)).to be_nil
      end
    end

    # PT-AT keys HABTM rows by transaction and association name, not by owner,
    # so a root checkpoint holds the root's membership alone.
    it 'names a HABTM below the root, and accepts every other association there' do
      expect(reason(TrackedTag, :articles, root: false)).to eq(below_root('TrackedTag#articles'))
      expect(reason(TrackedTag, :articles)).to be_nil
      %i[author profile comments contributors].each do |name|
        expect(reason(TrackedArticle, name, root: false)).to be_nil
      end
      expect(reason(TraversalAuthor, :article_tags, root: false))
        .to eq(habtm_reason('TrackedArticle#tags'))
    end

    it 'names a HABTM with a scope or a default-scoped target' do
      expect(reason(TraversalArticle, :named_tags)).to eq(scoped('TraversalArticle#named_tags'))
      expect(reason(TraversalArticle, :default_named_tags))
        .to eq(scoped('TraversalArticle#default_named_tags'))
      expect(reason(TraversalArticle, :labels)).to be_nil
    end

    it 'names the PaperTrail versions association' do
      expect(reason(TrackedArticle, :versions)).to eq('PaperTrail versions')
    end

    it 'names an unsupported macro' do
      reflection = TrackedArticle.reflect_on_association(:comments)
      allow(reflection).to receive(:macro).and_return(:composed_of)

      expect(reason(TrackedArticle, :comments)).to eq('composed_of')
    end

    it 'names the HABTM a has_many :through goes through' do
      expect(reason(TraversalArticle, :tagged_comments))
        .to eq(habtm_reason('TraversalArticle#tags'))
      expect(reason(TraversalAuthor, :article_tags)).to eq(habtm_reason('TrackedArticle#tags'))
    end

    it "raises Active Record's own error for a through it cannot follow" do
      expect { reason(TraversalNote, :holder_replies) }
        .to raise_error(ActiveRecord::HasManyThroughAssociationPolymorphicThroughError)
    end

    # A settings screen offers what discovery lists, so a path it lists must be
    # one a request accepts.
    it 'is what discovery leaves out, so every path it lists can be requested' do
      expect(PaperTrailDiff.association_paths(TraversalArticle).map(&:path))
        .to eq(%w[author comments labels notes tags])
      article_paths = PaperTrailDiff.association_paths(TrackedArticle, max_depth: 2).map(&:path)
      expect(article_paths).to include('tags', 'comments.article')
      expect(article_paths).not_to include('tags.articles')
      expect(PaperTrailDiff.association_paths(TraversalAuthor).map(&:path))
        .to eq(%w[articles traversal_articles])

      paths = PaperTrailDiff.association_paths(TraversalAuthor, max_depth: 2).map(&:path)
      expect(paths).to include('traversal_articles.comments', 'articles.contributors')
      expect(paths).not_to include('traversal_articles.tagged_articles',
                                   'traversal_articles.tagged_comments',
                                   'articles.tags', 'traversal_articles.tags')
      expect { traversal(*paths).validate!(TraversalAuthor) }.not_to raise_error
    end

    it "makes discovery raise Active Record's own error for a through it cannot follow" do
      expect { PaperTrailDiff.association_paths(TraversalNote) }
        .to raise_error(ActiveRecord::HasManyThroughAssociationPolymorphicThroughError)
    end
  end

  describe '#tree' do
    it 'returns the tree it walks' do
      tree = PaperTrailDiff::AssociationTree.build([:comments])

      expect(described_class.new(tree).tree).to equal(tree)
    end
  end

  describe '#validate!' do
    it 'accepts supported paths, including nested and through paths' do
      paths = [:author, :profile, :tags, :contributors, 'comments.replies', 'comments.article']

      expect { traversal(*paths).validate!(TrackedArticle) }.not_to raise_error
      expect { traversal(:comments, 'articles.contributors').validate!(TrackedAuthor) }
        .not_to raise_error
    end

    it 'names the full path of an unknown association' do
      expect { traversal('comments.missing').validate!(TrackedArticle) }
        .to raise_error(PaperTrailDiff::UnknownAssociationError,
                        'unknown association: comments.missing')
    end

    it 'rejects the PaperTrail versions association' do
      expect { traversal('comments.versions').validate!(TrackedArticle) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        'unsupported association comments.versions: PaperTrail versions')
    end

    it 'rejects an unsupported macro' do
      reflection = TrackedArticle.reflect_on_association(:comments)
      allow(reflection).to receive(:macro).and_return(:composed_of)

      expect { traversal(:comments).validate!(TrackedArticle) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        'unsupported association comments: composed_of')
    end

    it 'rejects a path that continues past a polymorphic belongs_to' do
      expect { traversal('holder.comments.replies').validate!(TraversalNote) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        'unsupported association holder.comments: holder is polymorphic, ' \
                        'so a path cannot continue past it')
    end

    it 'accepts a polymorphic belongs_to that ends its path' do
      expect { traversal(:holder).validate!(TraversalNote) }.not_to raise_error
    end

    it 'checks paths below the root' do
      expect { traversal('author.articles.missing').validate!(TrackedArticle) }
        .to raise_error(PaperTrailDiff::UnknownAssociationError,
                        'unknown association: author.articles.missing')
    end

    it 'checks the paths below every association, not only the first' do
      expect { traversal(:author, 'comments.missing').validate!(TrackedArticle) }
        .to raise_error(PaperTrailDiff::UnknownAssociationError,
                        'unknown association: comments.missing')
    end

    # Active Record replaces each HABTM in a through chain with a hidden
    # has_many, so the HABTM shows only on the public reflection.
    it 'rejects a has_many :through whose through association is a HABTM' do
      expect { traversal(:tagged_articles).validate!(TraversalArticle) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        unsupported('tagged_articles', 'TraversalArticle#tags'))
    end

    it 'rejects a has_many :through whose source is a HABTM' do
      expect { traversal(:article_tags).validate!(TraversalAuthor) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        unsupported('article_tags', 'TrackedArticle#tags'))
    end

    it 'rejects a has_many :through that reaches a HABTM through another through' do
      expect { traversal(:tagged_comments).validate!(TraversalArticle) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        unsupported('tagged_comments', 'TraversalArticle#tags'))
      expect { traversal(:articles_tagged_alike).validate!(TraversalAuthor) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        unsupported('articles_tagged_alike', 'TraversalArticle#tags'))
    end

    it 'names the full path of a through over a HABTM below the root' do
      expect { traversal('traversal_articles.tagged_articles').validate!(TraversalAuthor) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        unsupported('traversal_articles.tagged_articles', 'TraversalArticle#tags'))
    end

    it 'rejects a HABTM below the root, even on a path that leads back to the root' do
      {
        'tags.articles' => %w[tags.articles TrackedTag#articles],
        'tags.articles.tags' => %w[tags.articles TrackedTag#articles],
        'author.articles.tags' => %w[author.articles.tags TrackedArticle#tags],
        'comments.article.tags' => %w[comments.article.tags TrackedArticle#tags]
      }.each do |requested, (path, habtm)|
        expect { traversal(requested).validate!(TrackedArticle) }
          .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                          "unsupported association #{path}: #{below_root(habtm)}")
      end
    end

    it "raises Active Record's own error for a through it cannot follow" do
      expect { traversal(:holder_replies).validate!(TraversalNote) }
        .to raise_error(ActiveRecord::HasManyThroughAssociationPolymorphicThroughError)
    end
  end

  describe '#selected_reflections' do
    it 'lists each requested path with its reflection, depth first and frozen' do
      selected = traversal('comments.replies', :author).selected_reflections(TrackedArticle)

      expect(selected).to be_frozen
      expect(selected).to eq(
        [['author', TrackedArticle.reflect_on_association(:author)],
         ['comments', TrackedArticle.reflect_on_association(:comments)],
         ['comments.replies', TrackedComment.reflect_on_association(:replies)]]
      )
    end

    it 'stops at a polymorphic belongs_to and goes on to its siblings' do
      expected = %i[holder reviewer].map do |name|
        [name.to_s, TraversalNote.reflect_on_association(name)]
      end

      expect(traversal('holder.comments', :reviewer).selected_reflections(TraversalNote))
        .to eq(expected)
    end

    it 'rejects a through over a HABTM' do
      expect { traversal(:article_tags).selected_reflections(TraversalAuthor) }
        .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                        unsupported('article_tags', 'TrackedArticle#tags'))
    end
  end

  describe '#habtm_paths' do
    it 'lists the HABTM paths, frozen' do
      paths = traversal(:tags, :comments, :labels, 'author.articles').habtm_paths(TraversalArticle)

      expect(paths).to be_frozen
      expect(paths).to eq(%w[labels tags])
    end

    it 'leaves out a has_many :through' do
      expect(traversal(:contributors).habtm_paths(TrackedArticle)).to eq([])
    end
  end

  describe '#ensure_habtm_history!' do
    let(:version) { Struct.new(:id, :transaction_id) }

    it 'requires a transaction id on the version when a HABTM path is selected' do
      walker = traversal(:tags, :comments, :labels)

      expect { walker.ensure_habtm_history!(TraversalArticle, version.new(4, nil)) }
        .to raise_error(PaperTrailDiff::IncompleteAssociationHistoryError,
                        'HABTM history is incomplete at version 4: labels, tags')
      expect(walker.ensure_habtm_history!(TraversalArticle, version.new(4, 9))).to be_nil
    end

    it 'requires a transaction_id column' do
      expect { traversal(:tags).ensure_habtm_history!(TrackedArticle, Struct.new(:id).new(5)) }
        .to raise_error(PaperTrailDiff::IncompleteAssociationHistoryError,
                        'HABTM history is incomplete at version 5: tags')
    end

    it 'accepts any version when no HABTM path is selected' do
      expect(traversal(:comments).ensure_habtm_history!(TrackedArticle, Object.new)).to be_nil
    end
  end

  describe '#reject_live_habtm_activity!' do
    it 'refuses live-ended activity over HABTM paths and names them' do
      walker = traversal(:tags, :labels)

      expect { walker.reject_live_habtm_activity!(TraversalArticle) }
        .to raise_error(PaperTrailDiff::UnsupportedLiveActivityError,
                        'live-ended activity cannot reconstruct HABTM event boundaries: ' \
                        'labels, tags')
    end

    it 'allows activity without HABTM paths' do
      expect(traversal(:comments).reject_live_habtm_activity!(TrackedArticle)).to be_nil
    end
  end

  describe '#reflections_for' do
    it 'resolves the children of a tree once, frozen' do
      tree = PaperTrailDiff::AssociationTree.build(%i[comments author])
      walker = described_class.new(tree)
      reflections = walker.reflections_for(TrackedArticle, tree, path: '')
      expected = %i[author comments].map { |name| TrackedArticle.reflect_on_association(name) }

      expect(reflections).to be_frozen
      expect(reflections).to eq(expected)
      expect(walker.reflections_for(TrackedArticle, tree, path: '')).to equal(reflections)
    end

    it 'keeps the reflections of each model and tree apart' do
      tree = PaperTrailDiff::AssociationTree.build([:comments])
      other_tree = PaperTrailDiff::AssociationTree.build([:articles])
      walker = described_class.new(tree)

      expect(walker.reflections_for(TrackedArticle, tree, path: '').first.active_record)
        .to eq(TrackedArticle)
      expect(walker.reflections_for(TrackedAuthor, tree, path: '').first.active_record)
        .to eq(TrackedAuthor)
      expect(walker.reflections_for(TrackedAuthor, other_tree, path: '').first.name)
        .to eq(:articles)
    end
  end

  describe '#incoming_relationship_columns' do
    def columns(model, name)
      traversal.incoming_relationship_columns(model.reflect_on_association(name))
    end

    it 'returns the keys a direct has_one or has_many child points back with' do
      expect(columns(TrackedArticle, :comments)).to eq(['article_id'])
      expect(columns(TrackedArticle, :profile)).to eq(['article_id'])
    end

    it 'returns every column of a composite foreign key' do
      reflection = instance_double(ActiveRecord::Reflection::HasManyReflection,
                                   macro: :has_many, through_reflection?: false,
                                   foreign_key: %w[article_id reviewer_id].freeze, type: nil)

      expect(traversal.incoming_relationship_columns(reflection)).to eq(%w[article_id reviewer_id])
    end

    it 'adds the type column of a polymorphic child' do
      expect(columns(TraversalArticle, :notes)).to eq(%w[holder_id holder_type])
    end

    it 'returns no columns for a belongs_to, a HABTM, or a has_many :through' do
      expect(columns(TrackedArticle, :author)).to eq([])
      expect(columns(TrackedArticle, :tags)).to eq([])
      expect(columns(TrackedArticle, :contributors)).to eq([])
    end
  end

  describe 'public methods' do
    def statements(&block)
      sql = []
      callback = proc do |_name, _start, _finish, _id, payload|
        sql << payload.fetch(:sql) unless payload[:name] == 'SCHEMA' || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      sql
    end

    def calls(record, association)
      from, to = record.versions.order(:id).to_a
      window = (Time.now.utc - 60)..Time.now.utc
      options = { associations: [association] }
      [
        -> { PaperTrailDiff.compare(from, to, **options) },
        -> { PaperTrailDiff.compare(record, record, **options) },
        -> { PaperTrailDiff.compare_many([{ from: from, to: record }], **options) },
        -> { PaperTrailDiff.timeline(record, from: from, to: to, **options) },
        -> { PaperTrailDiff.activity_timeline(record, from: from, to: to, **options) },
        -> { PaperTrailDiff.analyze(record, within: window, **options) },
        -> { PaperTrailDiff.analyze(record, within: window, activity: true, **options) },
        -> { PaperTrailDiff.analyze_many([record], within: window, **options) },
        -> { PaperTrailDiff.analyze_scope(record.class.all, within: window, limit: 5, **options) },
        -> { PaperTrailDiff.report(record.class.all, since: window.begin, limit: 5, **options) }
      ]
    end

    it 'reject a through over a HABTM, or a HABTM below the root, before running any query' do
      article = TraversalArticle.create!(title: 'Article')
      article.update!(title: 'Renamed')
      author = TraversalAuthor.create!(name: 'Author')
      author.update!(name: 'Renamed')
      cases = [[article, :tagged_articles, unsupported('tagged_articles', 'TraversalArticle#tags')],
               [author, :article_tags, unsupported('article_tags', 'TrackedArticle#tags')],
               [article, 'tags.articles',
                "unsupported association tags.articles: #{below_root('TrackedTag#articles')}"],
               [article, :named_tags,
                "unsupported association named_tags: #{scoped('TraversalArticle#named_tags')}"]]

      cases.each do |record, association, message|
        calls(record, association).each do |call|
          sql = statements do
            expect(&call).to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
          end
          expect(sql).to eq([])
        end
      end
    end
  end
end
