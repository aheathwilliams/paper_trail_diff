# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :traversal_pages, force: true do |table|
    table.string :type
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :traversal_notes, force: true do |table|
    table.string :body, null: false
    table.references :notable, polymorphic: true
    table.references :page
    table.timestamps null: false
  end
end

class TraversalPage < ActiveRecord::Base
  has_many :notes, class_name: 'TraversalNote', as: :notable, inverse_of: :notable
  has_paper_trail
end

class TraversalLandingPage < TraversalPage
end

class TraversalPromoPage < TraversalLandingPage
end

class TraversalArchivePage < TraversalPage
end

class TraversalNote < ActiveRecord::Base
  belongs_to :notable, polymorphic: true, optional: true
  belongs_to :page, class_name: 'TraversalPage', optional: true
  has_paper_trail
end

RSpec.describe PaperTrailDiff::AssociationTraversal do
  def traversal(*paths)
    described_class.new(PaperTrailDiff::AssociationTree.build(paths))
  end

  def reflection(model, name)
    model.reflect_on_association(name)
  end

  def note(type)
    TraversalNote.new(body: 'note', notable_type: type, notable_id: 1)
  end

  it 'names the class a belongs_to points at, reading a polymorphic type per record' do
    notable = reflection(TraversalNote, :notable)

    expect(described_class.belongs_to_target(reflection(TrackedComment, :article), nil))
      .to eq(TrackedArticle)
    expect(described_class.belongs_to_target(notable, note('TraversalLandingPage')))
      .to eq(TraversalLandingPage)
    expect([nil, ''].map { |type| described_class.belongs_to_target(notable, note(type)) })
      .to eq([nil, nil])
  end

  it 'raises naming the record and column when a polymorphic type names no class' do
    record = note('RemovedModel')
    record.id = 7

    expect { described_class.belongs_to_target(reflection(TraversalNote, :notable), record) }
      .to raise_error(
        PaperTrailDiff::IncompleteAssociationHistoryError,
        'association TraversalNote#notable cannot be read: TraversalNote 7 has notable_type ' \
        'RemovedModel, which names no class. If the model was renamed, replace the old name ' \
        'in that column and in the versions that recorded it.'
      )
  end

  it 'resolves a stored type name to its class, or to nothing' do
    expect(%w[TraversalPage RemovedModel].map { |name| described_class.named_class(name) })
      .to eq([TraversalPage, nil])
  end

  it 'counts a row as a subclass member when its type names the class or a descendant' do
    members = %w[TraversalLandingPage TraversalPromoPage TraversalPage TraversalArchivePage]
              .map { |type| described_class.sti_member?(TraversalLandingPage, 'type' => type) }

    expect(members).to eq([true, true, false, false])
    expect(described_class.sti_member?(TraversalLandingPage, {})).to be(false)
    expect(described_class.sti_member?(TraversalPage, 'type' => 'TraversalArchivePage')).to be(true)
    expect(described_class.sti_member?(TrackedArticle, {})).to be(true)
  end

  it 'lists every requested association depth first, with its path' do
    found = traversal('comments.replies', 'author', :tags).selected_reflections(TrackedArticle)

    expect(found.map { |path, found_reflection| [path, found_reflection.name] })
      .to eq([['author', :author], ['comments', :comments], ['comments.replies', :replies],
              ['tags', :tags]])
    expect(found.last.last).to equal(reflection(TrackedArticle, :tags))
    expect(found).to be_frozen
  end

  # A batch can check its paths before they are validated, so listing stops
  # at a polymorphic association rather than asking for its class.
  it 'lists nothing past a polymorphic association' do
    expect(traversal('notable.notes', :page).selected_reflections(TraversalNote).map(&:first))
      .to eq(%w[notable page])
  end

  it 'accepts every supported path and names the full path of one it rejects' do
    expect { traversal('comments.replies', 'contributors', :tags).validate!(TrackedArticle) }
      .not_to raise_error
    expect { traversal(:notable).validate!(TraversalNote) }.not_to raise_error
    expect { traversal('author', 'comments.replies.missing').validate!(TrackedArticle) }
      .to raise_error(PaperTrailDiff::UnknownAssociationError,
                      'unknown association: comments.replies.missing')
    expect { traversal('versions').validate!(TrackedArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                      'unsupported association versions: PaperTrail versions')
    expect { traversal('notable.notes.notable').validate!(TraversalNote) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                      'unsupported association notable.notes: notable is polymorphic, ' \
                      'so a path cannot continue past it')
  end

  it 'rejects a macro it does not support' do
    unsupported = Struct.new(:name, :macro).new(:embedded, :embeds_many)
    model = Class.new do
      define_singleton_method(:reflect_on_association) { |_name| unsupported }
    end

    expect { traversal('embedded').validate!(model) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                      'unsupported association embedded: embeds_many')
  end

  it 'reads each model and tree once, whatever path reaches them' do
    comments = traversal(:comments)
    tree = comments.tree
    first = comments.reflections_for(TrackedArticle, tree, path: '')

    expect(comments.reflections_for(TrackedArticle, tree, path: 'other')).to equal(first)
    expect(comments.reflections_for(TrackedAuthor, tree, path: '').first)
      .to equal(reflection(TrackedAuthor, :comments))
    expect(comments.reflections_for(TrackedArticle, PaperTrailDiff::AssociationTree.build([]),
                                    path: '')).to eq([])
    expect(first).to be_frozen
  end

  it 'names the HABTM paths at any depth' do
    expect(traversal('comments.article.tags', :author, :tags).habtm_paths(TrackedArticle))
      .to eq(%w[comments.article.tags tags])
    expect(traversal(:comments, :contributors).habtm_paths(TrackedArticle)).to eq([])
    expect(traversal(:tags).habtm_paths(TrackedArticle)).to be_frozen
  end

  it 'requires a transaction id on a root version only when a HABTM path is requested' do
    without = Struct.new(:id).new(7)
    blank = Struct.new(:id, :transaction_id).new(8, nil)
    recorded = Struct.new(:id, :transaction_id).new(9, 3)
    tagged = traversal(:tags, 'comments.article.tags')

    expect { traversal(:comments).ensure_habtm_history!(TrackedArticle, without) }
      .not_to raise_error
    expect { tagged.ensure_habtm_history!(TrackedArticle, recorded) }.not_to raise_error
    [without, blank].each do |version|
      expect { tagged.ensure_habtm_history!(TrackedArticle, version) }
        .to raise_error(PaperTrailDiff::IncompleteAssociationHistoryError,
                        "HABTM history is incomplete at version #{version.id}: " \
                        'comments.article.tags, tags')
    end
  end

  it 'refuses activity that ends at the current record only for HABTM paths' do
    expect { traversal(:comments).reject_live_habtm_activity!(TrackedArticle) }.not_to raise_error
    expect { traversal(:tags, 'comments.article.tags').reject_live_habtm_activity!(TrackedArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedLiveActivityError,
                      'live-ended activity cannot reconstruct HABTM event boundaries: ' \
                      'comments.article.tags, tags')
  end

  it 'names the columns a child points back at its owner with' do
    columns = lambda do |model, name|
      traversal.incoming_relationship_columns(reflection(model, name))
    end
    composite = Struct.new(:macro, :foreign_key, :type) do
      def through_reflection?
        false
      end
    end.new(:has_many, %i[article_id title])

    expect(columns.call(TrackedArticle, :comments)).to eq(['article_id'])
    expect(columns.call(TrackedArticle, :profile)).to eq(['article_id'])
    expect(columns.call(TraversalPage, :notes)).to eq(%w[notable_id notable_type])
    expect(%i[author contributors tags].map { |name| columns.call(TrackedArticle, name) })
      .to eq([[], [], []])
    expect(traversal.incoming_relationship_columns(composite)).to eq(%w[article_id title])
  end
end
