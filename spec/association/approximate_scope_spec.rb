# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :approximate_boards, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :approximate_cards, force: true do |table|
    table.string :title, null: false
    table.integer :board_id
    table.integer :priority
    table.timestamps null: false
  end
end

class ApproximateCard < ActiveRecord::Base
  belongs_to :board, class_name: 'ApproximateBoard', optional: true
  has_paper_trail
end

class ApproximateBoard < ActiveRecord::Base
  has_many :cards, class_name: 'ApproximateCard', foreign_key: :board_id
  # SQL text, which history cannot read: PT-AT reads it instead.
  has_many :high_cards, -> { where('priority > 2') }, class_name: 'ApproximateCard',
                                                      foreign_key: :board_id
  has_paper_trail
end

# PT-AT rebuilds an association from its current members, so a record that
# entered the scope since reads as a member it was not. History that cannot
# read a scope is used only when the caller accepts that.
RSpec.describe 'An association scope history cannot read' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [ApproximateCard, ApproximateBoard].each(&:delete_all)
  end

  let(:message) { /association high_cards cannot be read exactly .*allow_approximate: true/ }

  # The card is low priority at the start and enters the scope later.
  def history
    board = ApproximateBoard.create!(name: 'Board')
    card = board.cards.create!(title: 'card', priority: 1)
    from = board.versions.last
    card.update!(priority: 5)
    [board, from]
  end

  it 'is refused in every method that reads history unless allow_approximate: is passed' do
    board, from = history
    options = { associations: [:high_cards] }

    expect { PaperTrailDiff.compare(from, board, **options) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
    expect { PaperTrailDiff.activity_timeline(board, **options) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
    expect { PaperTrailDiff.analyze_many([board], allow_expensive: true, **options) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
    expect { PaperTrailDiff.compare(board, board, **options) }.not_to raise_error
  end

  it 'reads it with PT-AT when allowed' do
    board, from = history
    options = { associations: [:high_cards], allow_approximate: true }

    expect { PaperTrailDiff.compare(from, board, **options) }.not_to raise_error
    expect { PaperTrailDiff.analyze_many([board], allow_expensive: true, **options) }
      .not_to raise_error
  end

  it 'is an error diagnose reports, and a warning once allowed' do
    board, from = history
    options = { associations: [:high_cards] }
    error = begin
      PaperTrailDiff.compare(from, board, **options)
    rescue PaperTrailDiff::UnsupportedAssociationError => e
      e
    end

    report = PaperTrailDiff.diagnose(from, board, **options)
    allowed = PaperTrailDiff.diagnose(from, board, allow_approximate: true, **options)

    expect(report.errors.map { |issue| [issue.code, issue.path, issue.message] })
      .to eq([[:approximate_association, 'high_cards', error.message]])
    expect(allowed).to be_ok
    expect(allowed.warnings.map { |issue| [issue.code, issue.path] })
      .to include([:approximate_association, 'high_cards'])
  end

  it 'takes only true or false' do
    board, from = history

    expect do
      PaperTrailDiff.compare(from, board, associations: [:high_cards], allow_approximate: 1)
    end.to raise_error(PaperTrailDiff::ConfigurationError,
                       'allow_approximate: must be true or false')
  end
end
