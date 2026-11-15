# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :unreadable_boards, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :unreadable_cards, force: true do |table|
    table.string :title, null: false
    table.integer :board_id
    table.integer :priority
    table.timestamps null: false
  end
end

class UnreadableCard < ActiveRecord::Base
  belongs_to :board, class_name: 'UnreadableBoard', optional: true
  has_paper_trail
end

class UnreadableBoard < ActiveRecord::Base
  has_many :cards, class_name: 'UnreadableCard', foreign_key: :board_id
  # SQL text, which history cannot read.
  has_many :high_cards, -> { where('priority > 2') }, class_name: 'UnreadableCard',
                                                      foreign_key: :board_id
  has_paper_trail
end

# PT-AT would rebuild such an association from its current members, so a
# record that entered the scope since would read as a member it was not.
RSpec.describe 'An association scope history cannot read' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [UnreadableCard, UnreadableBoard].each(&:delete_all)
  end

  let(:message) do
    'association high_cards cannot be read from history (association scope): who was in it ' \
      'at a past point cannot be told. Remove this path, or make its scope plain conditions ' \
      "on the target's own columns"
  end

  # The card is low priority at the start and enters the scope later.
  def history
    board = UnreadableBoard.create!(name: 'Board')
    card = board.cards.create!(title: 'card', priority: 1)
    from = board.versions.last
    card.update!(priority: 5)
    [board, from]
  end

  it 'is refused in every method that reads history' do
    board, from = history
    options = { associations: [:high_cards] }

    expect { PaperTrailDiff.compare(from, board, **options) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
    expect { SpecTimelines.activity_timeline(board, **options) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
    expect { PaperTrailDiff.analyze_many([board], **options) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
    expect { PaperTrailDiff.compare(board, board, **options) }.not_to raise_error
  end

  it 'is an error diagnose reports' do
    board, from = history

    report = PaperTrailDiff.diagnose(from, board, associations: [:high_cards])

    expect(report.errors.map { |issue| [issue.code, issue.path, issue.message] })
      .to eq([[:unreadable_association, 'high_cards', message]])
  end
end
