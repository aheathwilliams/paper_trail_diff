# frozen_string_literal: true

require_relative '../support/graph_oracle'

ActiveRecord::Schema.define do
  create_table :oracle_shape_users, force: true do |table|
    table.string :name
    table.timestamps
  end

  create_table :oracle_shape_teams, force: true do |table|
    table.string :name
    table.timestamps
  end

  create_table :oracle_shape_boards, force: true do |table|
    table.string :name
    table.string :owner_type
    table.integer :owner_id
    table.timestamps
  end

  create_table :oracle_shape_cards, force: true do |table|
    table.string :type
    table.integer :board_id
    table.integer :assignee_id
    table.integer :position
    table.boolean :done, null: false, default: false
    table.string :title
    table.timestamps
  end

  create_table :oracle_shape_comments, force: true do |table|
    table.string :commentable_type
    table.integer :commentable_id
    table.string :body
    table.timestamps
  end

  create_table :oracle_shape_labels, force: true do |table|
    table.integer :board_id
    table.boolean :archived, null: false, default: false
    table.string :name
    table.timestamps
  end
end

class OracleShapeUser < ActiveRecord::Base
  has_paper_trail
end

class OracleShapeTeam < ActiveRecord::Base
  has_paper_trail
end

# Association shapes the other oracles leave out: a polymorphic belongs_to on
# the root, polymorphic has_many and has_one (`as:`), children that use
# single-table inheritance and change type, an association to one subclass,
# a child's own belongs_to, scoped and ranked has_many and has_one, and a
# target with a default scope.
class OracleShapeBoard < ActiveRecord::Base
  cards = { class_name: 'OracleShapeCard', foreign_key: :board_id }
  belongs_to :owner, polymorphic: true, optional: true
  has_many :cards, **cards, inverse_of: :board
  has_many :open_cards, -> { where(done: false) }, **cards
  has_many :top_cards, -> { order(:position, :id).limit(2) }, **cards
  has_one :next_card, -> { where(done: false).order(:position, :id) }, **cards
  has_many :bugs, class_name: 'OracleShapeBug', foreign_key: :board_id
  has_many :assignees, through: :cards
  has_many :comments, class_name: 'OracleShapeComment', as: :commentable
  has_one :latest_comment, -> { order(id: :desc) }, class_name: 'OracleShapeComment',
                                                    as: :commentable
  has_many :labels, class_name: 'OracleShapeLabel', foreign_key: :board_id
  has_paper_trail
end

class OracleShapeCard < ActiveRecord::Base
  belongs_to :board, class_name: 'OracleShapeBoard', optional: true, inverse_of: :cards
  belongs_to :assignee, class_name: 'OracleShapeUser', optional: true
  has_many :comments, class_name: 'OracleShapeComment', as: :commentable
  has_paper_trail
end

class OracleShapeTask < OracleShapeCard
end

class OracleShapeBug < OracleShapeCard
end

class OracleShapeComment < ActiveRecord::Base
  belongs_to :commentable, polymorphic: true, optional: true
  has_paper_trail
end

class OracleShapeLabel < ActiveRecord::Base
  default_scope { where(archived: false) }
  belongs_to :board, class_name: 'OracleShapeBoard', optional: true
  has_paper_trail
end

# Random edits to two boards and the records around them.
class OracleShapeHistory
  PATHS = [%w[owner cards.assignee cards.comments], %w[comments latest_comment labels],
           %w[open_cards top_cards next_card bugs assignees]].freeze
  CARD_TYPES = [nil, 'OracleShapeTask', 'OracleShapeBug'].freeze
  OPERATIONS = %i[
    edit_board checkpoint set_owner set_owner edit_user edit_team destroy_user
    add_card add_card edit_card edit_card retype_card retype_card move_card destroy_card
    assign_card add_comment add_comment edit_comment move_comment destroy_comment
    add_label edit_label archive_label move_label destroy_label combo
  ].freeze
  # Each writes a version of a board. A board versioned twice in one
  # transaction has a version there whose state this oracle never records.
  BOARD_OPERATIONS = %i[edit_board checkpoint set_owner].freeze

  attr_reader :recorder, :root_ids

  def initialize(seed, steps:)
    @random = Random.new(seed)
    @steps = steps
    @counter = 0
    @root_ids = []
    @recorder = Oracle::Recorder.new do
      [nil, nil, Oracle::GraphTruth.states(OracleShapeBoard, @root_ids, PATHS)]
    end
  end

  def build
    @recorder.run(:plant) { plant }
    @steps.times do
      operation = OPERATIONS.sample(random: @random)
      @recorder.run(operation) { send(operation) }
    end
    self
  end

  private

  def plant
    users = Array.new(3) { |index| OracleShapeUser.create!(name: "user #{index}") }
    OracleShapeTeam.create!(name: 'team 0')
    boards = Array.new(2) do |index|
      board = OracleShapeBoard.create!(name: "board #{index}", owner: users[index])
      card = OracleShapeTask.create!(board: board, title: "card #{index}", position: index,
                                     assignee: users[index])
      OracleShapeComment.create!(commentable: index.zero? ? board : card, body: "comment #{index}")
      OracleShapeLabel.create!(board: board, name: "label #{index}")
      board
    end
    @root_ids = boards.map(&:id)
  end

  def next_number = @counter += 1
  def any(list) = list.sample(random: @random)
  def boards = OracleShapeBoard.order(:id).to_a
  def users = OracleShapeUser.order(:id).to_a
  def teams = OracleShapeTeam.order(:id).to_a
  def cards = OracleShapeCard.order(:id).to_a
  def comments = OracleShapeComment.order(:id).to_a
  def labels = OracleShapeLabel.unscoped.order(:id).to_a
  def commentables = [*boards, *cards]
  def position = any([nil, 1, 2, 3])

  def edit_board = any(boards).update!(name: "board #{next_number}")
  def checkpoint = OracleShapeBoard.find(any(@root_ids)).paper_trail.save_with_version
  def set_owner = any(boards).update!(owner: any([nil, *users, *teams]))
  def edit_user = any(users)&.update!(name: "user #{next_number}")
  def edit_team = any(teams).update!(name: "team #{next_number}")
  def destroy_user = users.length > 2 && any(users).destroy!

  def add_card
    type = any(CARD_TYPES)
    (type ? type.constantize : OracleShapeCard).create!(
      board: any(boards), title: "card #{next_number}", position: position,
      done: any([true, false]), assignee: any([nil, *users])
    )
  end

  def edit_card
    changes = [{ title: "card #{next_number}" }, { position: position },
               { done: any([true, false]) }, { position: position, done: any([true, false]) }]
    any(cards)&.update!(any(changes))
  end

  def retype_card
    card = any(cards) or return
    card.update!(type: any(CARD_TYPES - [card.type]))
  end

  def move_card
    card = any(cards)
    card&.update!(board_id: (@root_ids - [card.board_id]).first)
  end

  def destroy_card = any(cards)&.destroy!
  def assign_card = any(cards)&.update!(assignee: any([nil, *users]))

  def add_comment
    OracleShapeComment.create!(commentable: any(commentables), body: "comment #{next_number}")
  end

  def edit_comment = any(comments)&.update!(body: "comment #{next_number}")
  def destroy_comment = any(comments)&.destroy!

  def move_comment
    comment = any(comments) or return
    current = [comment.commentable_type, comment.commentable_id]
    others = commentables.reject { |record| [record.class.base_class.name, record.id] == current }
    comment.update!(commentable: any(others))
  end

  def add_label
    OracleShapeLabel.create!(board: any(boards), name: "label #{next_number}",
                             archived: any([true, false]))
  end

  def edit_label = any(labels)&.update!(name: "label #{next_number}")
  def destroy_label = any(labels)&.destroy!

  def archive_label
    label = any(labels)
    label&.update!(archived: !label.archived)
  end

  def move_label
    label = any(labels)
    label&.update!(board_id: (@root_ids - [label.board_id]).first)
  end

  # Several versions in one transaction, at most one of them a board's.
  def combo
    board_versioned = false
    3.times do
      operation = any(OPERATIONS - %i[combo destroy_user])
      next if BOARD_OPERATIONS.include?(operation) && board_versioned

      board_versioned ||= BOARD_OPERATIONS.include?(operation)
      send(operation)
    end
  end
end

RSpec.describe 'Rebuilt association shapes against the recorded states' do
  before do
    [PaperTrail::VersionAssociation, PaperTrail::Version, OracleShapeUser, OracleShapeTeam,
     OracleShapeBoard, OracleShapeCard, OracleShapeComment, OracleShapeLabel.unscoped]
      .each(&:delete_all)
  end

  Oracle.seeds([1, 2]).each do |seed|
    it "rebuilds every endpoint, timeline, activity step, window and split (seed #{seed})" do
      history = OracleShapeHistory.new(seed, steps: Oracle.steps(24)).build
      failures = Oracle::Failures.new(seed, history.recorder)
      Oracle::GraphChecker.new(OracleShapeBoard, history.recorder, history.root_ids,
                               OracleShapeHistory::PATHS, failures).run(Random.new(seed))

      expect(failures).to be_empty, -> { failures.message }
    end
  end
end
