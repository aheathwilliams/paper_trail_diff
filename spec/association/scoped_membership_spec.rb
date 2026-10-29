# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :scope_boards, force: true do |table|
    table.string :name, null: false
    table.boolean :closed, null: false, default: false
    table.timestamps null: false
  end

  create_table :scope_cards, force: true do |table|
    table.string :title, null: false
    table.integer :board_id
    table.boolean :archived, null: false, default: false
    table.integer :priority
    table.timestamps null: false
  end

  create_table :scope_checks, force: true do |table|
    table.string :item, null: false
    table.integer :card_id
    table.boolean :done, null: false, default: false
    table.timestamps null: false
  end

  create_table :scope_notes, force: true do |table|
    table.string :body, null: false
    table.integer :board_id
    table.boolean :hidden, null: false, default: false
    table.timestamps null: false
  end
end

class ScopeBoard < ActiveRecord::Base
  has_many :active_cards, -> { where(archived: false) }, class_name: 'ScopeCard',
                                                         foreign_key: :board_id
  has_many :urgent_cards, -> { where(priority: [1, 2]) }, class_name: 'ScopeCard',
                                                          foreign_key: :board_id
  has_many :unranked_cards, -> { where(priority: nil) }, class_name: 'ScopeCard',
                                                         foreign_key: :board_id
  has_many :notes, class_name: 'ScopeNote', foreign_key: :board_id
  has_many :cards, class_name: 'ScopeCard', foreign_key: :board_id
  has_many :active_card_checks, through: :active_cards, source: :checks
  has_many :open_checks, -> { where(done: false) }, through: :cards, source: :checks
  has_paper_trail
end

class ScopeCard < ActiveRecord::Base
  belongs_to :board, class_name: 'ScopeBoard', optional: true
  belongs_to :open_board, -> { where(closed: false) }, class_name: 'ScopeBoard',
                                                       foreign_key: :board_id, optional: true
  has_many :checks, class_name: 'ScopeCheck', foreign_key: :card_id
  has_paper_trail
end

class ScopeCheck < ActiveRecord::Base
  belongs_to :card, class_name: 'ScopeCard', optional: true
  has_paper_trail
end

class ScopeNote < ActiveRecord::Base
  default_scope { where(hidden: false) }
  belongs_to :board, class_name: 'ScopeBoard', optional: true
  has_paper_trail
end

# A scoped association's members at a boundary are the records whose key
# matched the owner and whose state met the scope's conditions, both read as
# the record stood at that boundary.
RSpec.describe 'A statically scoped association over time' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [ScopeNote, ScopeCheck, ScopeCard, ScopeBoard].each(&:delete_all)
  end

  let(:todo) { ScopeBoard.create!(name: 'Todo') }
  let(:done) { ScopeBoard.create!(name: 'Done') }

  # One version per board, saved together, at which the range starts or ends.
  def checkpoint(*boards)
    ScopeBoard.transaction do
      boards.to_h do |board|
        fresh = ScopeBoard.find(board.id)
        fresh.paper_trail.save_with_version
        [board.id, fresh.versions.reorder(:id).last]
      end
    end
  end

  def change(diff, name, attribute = 'title')
    association = diff.associations[name.to_s]
    return empty unless association

    { added: association.added.map { |record| record.attributes.fetch(attribute) },
      removed: association.removed.map { |record| record.attributes.fetch(attribute) },
      changed: association.changed.map { |entry| entry.attributes.transform_values(&:to_h) } }
  end

  def empty
    { added: [], removed: [], changed: [] }
  end

  def single(board, from, to, path = :active_cards)
    PaperTrailDiff.analyze(board, from: from.fetch(board.id), to: to.fetch(board.id),
                                  associations: [path]).diff
  end

  def compared(board, from, to, path = :active_cards)
    PaperTrailDiff.compare(from.fetch(board.id), to.fetch(board.id), associations: [path])
  end

  it 'adds and removes a card as its attribute moves it into and out of the scope' do
    leaving = todo.active_cards.create!(title: 'leaving')
    entering = ScopeCard.create!(title: 'entering', board: todo, archived: true)
    from = checkpoint(todo)
    leaving.update!(archived: true)
    entering.update!(archived: false)
    to = checkpoint(todo)

    expected = { added: ['entering'], removed: ['leaving'], changed: [] }
    expect(change(single(todo, from, to), :active_cards)).to eq(expected)
    expect(change(compared(todo, from, to), :active_cards)).to eq(expected)
  end

  it 'reports an edit that keeps the card in the scope as a change' do
    card = todo.active_cards.create!(title: 'kept', priority: 1)
    from = checkpoint(todo)
    card.update!(priority: 2)
    to = checkpoint(todo)

    expect(change(single(todo, from, to, :urgent_cards), :urgent_cards))
      .to eq(empty.merge(changed: [{ 'priority' => { from: 1, to: 2 } }]))
    expect(change(single(todo, from, to, :unranked_cards), :unranked_cards)).to eq(empty)
  end

  it 'reads IN and nil conditions against the stored attribute' do
    card = ScopeCard.create!(title: 'ranked', board: todo)
    from = checkpoint(todo)
    card.update!(priority: 3)
    to = checkpoint(todo)
    card.update!(priority: 2)
    last = checkpoint(todo)

    expect(change(single(todo, from, to, :unranked_cards), :unranked_cards))
      .to eq(empty.merge(removed: ['ranked']))
    expect(change(single(todo, from, to, :urgent_cards), :urgent_cards)).to eq(empty)
    expect(change(single(todo, to, last, :urgent_cards), :urgent_cards))
      .to eq(empty.merge(added: ['ranked']))
  end

  it 'moves a card in the scope from one board to the other, and ignores one outside it' do
    moving = todo.active_cards.create!(title: 'moving')
    archived = ScopeCard.create!(title: 'archived', board: todo, archived: true)
    from = checkpoint(todo, done)
    moving.update!(board: done)
    archived.update!(board: done)
    to = checkpoint(todo, done)

    expect(change(single(todo, from, to), :active_cards)).to eq(empty.merge(removed: ['moving']))
    expect(change(single(done, from, to), :active_cards)).to eq(empty.merge(added: ['moving']))
  end

  it 'removes a destroyed card only if it was in the scope' do
    todo.active_cards.create!(title: 'active')
    ScopeCard.create!(title: 'archived', board: todo, archived: true)
    from = checkpoint(todo)
    ScopeCard.find_each(&:destroy!)
    to = checkpoint(todo)

    expect(change(single(todo, from, to), :active_cards)).to eq(empty.merge(removed: ['active']))
  end

  it 'reads changes made in one transaction as that transaction left them' do
    flipped = todo.active_cards.create!(title: 'flipped')
    archived = todo.active_cards.create!(title: 'archived')
    from = checkpoint(todo)
    ScopeCard.transaction do
      flipped.update!(archived: true)
      flipped.update!(archived: false)
      archived.update!(archived: true)
    end
    to = checkpoint(todo)

    expect(change(single(todo, from, to), :active_cards)).to eq(empty.merge(removed: ['archived']))
  end

  # A boundary is the state before its transaction, so a card archived in the
  # same transaction as the board's version is still in the scope there.
  it 'reads a card archived in the boundary version’s transaction as it was before' do
    card = todo.active_cards.create!(title: 'card')
    from = ScopeBoard.transaction do
      todo.update!(name: 'Todo renamed')
      card.update!(archived: true)
      todo.versions.reorder(:id).last
    end
    to = checkpoint(todo)

    expect(change(single(todo, { todo.id => from }, to), :active_cards))
      .to eq(empty.merge(removed: ['card']))
  end

  # Like any change saved without a version, an archive PaperTrail never
  # recorded belongs to the card's last recorded change, here its creation.
  it 'places a scope change saved without a version at the card’s last recorded change' do
    from = checkpoint(todo)
    hidden = todo.active_cards.create!(title: 'archived unrecorded')
    shown = ScopeCard.create!(title: 'restored unrecorded', board: todo, archived: true)
    to = checkpoint(todo)
    hidden.update_columns(archived: true)
    shown.update_columns(archived: false)

    expect(change(single(todo, from, to), :active_cards))
      .to eq(empty.merge(added: ['restored unrecorded']))
  end

  it 'reads a scoped belongs_to as empty while its target is outside the scope' do
    card = todo.active_cards.create!(title: 'card')
    card.update!(title: 'card on an open board')
    from = card.versions.reorder(:id).last
    todo.update!(closed: true)
    card.update!(title: 'card on a closed board')
    to = card.versions.reorder(:id).last
    todo.update!(closed: false)

    relationship = lambda do |from_endpoint, to_endpoint|
      PaperTrailDiff.analyze(card, from: from_endpoint, to: to_endpoint,
                                   associations: [:open_board])
                    .diff.associations.fetch('open_board').relationship.to_h
                    .transform_values { |board| board&.fetch(:attributes)&.fetch('name') }
    end
    expect(relationship.call(from, to)).to eq(from: 'Todo', to: nil)
    expect(relationship.call(to, card)).to eq(from: nil, to: 'Todo')
  end

  it 'filters a through by the scopes of its parts and by its own' do
    kept, archived = %w[kept archived].map { |title| todo.active_cards.create!(title: title) }
    kept_check = kept.checks.create!(item: 'kept check')
    archived.checks.create!(item: 'archived check')
    from = checkpoint(todo)
    archived.update!(archived: true)
    kept_check.update!(done: true)
    to = checkpoint(todo)

    expect(change(single(todo, from, to, :active_card_checks), :active_card_checks, 'item'))
      .to eq(empty.merge(removed: ['archived check'],
                         changed: [{ 'done' => { from: false, to: true } }]))
    expect(change(single(todo, from, to, :open_checks), :open_checks, 'item'))
      .to eq(empty.merge(removed: ['kept check']))
  end

  it 'applies the default scope of the target the same way' do
    shown = todo.notes.create!(body: 'shown')
    hidden = ScopeNote.create!(body: 'hidden', board: todo, hidden: true)
    from = checkpoint(todo)
    shown.update!(hidden: true)
    ScopeNote.unscoped.find(hidden.id).update!(hidden: false)
    to = checkpoint(todo)

    expect(change(single(todo, from, to, :notes), :notes, 'body'))
      .to eq({ added: ['hidden'], removed: ['shown'], changed: [] })
  end

  describe 'activity' do
    def activity(board, window, path = :active_cards)
      PaperTrailDiff.analyze(board, within: window, associations: [path], activity: true)
                    .activity_timeline.reject(&:empty?)
    end

    it 'reports entering and leaving the scope as an addition and a removal at that version' do
      card = ScopeCard.create!(title: 'card', board: todo, archived: true)
      start = checkpoint(todo).values.first.created_at
      card.update!(archived: false)
      entered = card.versions.reorder(:id).last
      card.update!(title: 'card edited')
      edited = card.versions.reorder(:id).last
      card.update!(archived: true)
      left = card.versions.reorder(:id).last
      card.update!(title: 'card unseen')
      window = start..Time.now.utc

      steps = activity(todo, window).map do |step|
        [step.source_boundary.version_id, change(step.diff, :active_cards)]
      end
      expect(steps).to eq(
        [[entered.id, empty.merge(added: ['card'])],
         [edited.id, empty.merge(changed: [{ 'title' => { from: 'card', to: 'card edited' } }])],
         [left.id, empty.merge(removed: ['card edited'])]]
      )
    end
  end

  describe 'in a batch' do
    let(:paths) { %i[active_cards urgent_cards unranked_cards notes] }
    let(:through_paths) { %i[active_card_checks open_checks] }

    def batched(boards, window, **options)
      PaperTrailDiff.analyze_many(boards, within: window, associations: paths + through_paths,
                                          **options)
    end

    def separately(boards, window, **options)
      boards.to_h do |board|
        [PaperTrailDiff::Endpoint.identity(board),
         PaperTrailDiff.analyze(board, within: window, associations: paths + through_paths,
                                       **options)]
      end
    end

    # A current boundary records when each call read it, so steps compare by
    # the version they start at.
    def summary(analysis)
      steps = analysis.activity_timeline&.map do |step|
        [step.from_boundary.version_id, step.to_boundary.kind, step.diff.to_h]
      end
      [analysis.diff.to_h, steps]
    end

    it 'matches each board analyzed alone, with or without activity' do
      moving = todo.active_cards.create!(title: 'moving', priority: 1)
      leaving = todo.active_cards.create!(title: 'leaving')
      gone = ScopeCard.create!(title: 'gone', board: done, archived: true, priority: 2)
      note = todo.notes.create!(body: 'note')
      check = leaving.checks.create!(item: 'check')
      start = checkpoint(todo, done).values.first.created_at
      ScopeCard.transaction do
        moving.update!(board: done, priority: nil)
        leaving.update!(archived: true)
      end
      gone.destroy!
      note.update!(hidden: true)
      check.update!(done: true)
      checkpoint(todo, done)
      window = start..Time.now.utc

      summaries = ->(results) { results.transform_values { |analysis| summary(analysis) } }
      [{}, { activity: true }].each do |options|
        expect(summaries.call(batched([todo, done], window, **options)))
          .to eq(summaries.call(separately([todo, done], window, **options)))
      end
      todo_diff, done_diff = batched([todo, done], window).values.map(&:diff)
      expect(paths.map { |path| change(todo_diff, path, path == :notes ? 'body' : 'title') })
        .to eq([empty.merge(removed: %w[moving leaving]), empty.merge(removed: ['moving']),
                empty.merge(changed: [{ 'archived' => { from: false, to: true } }]),
                empty.merge(removed: ['note'])])
      expect(paths.map { |path| change(done_diff, path, path == :notes ? 'body' : 'title') })
        .to eq([empty.merge(added: ['moving']), empty.merge(removed: ['gone']),
                empty.merge(added: ['moving']), empty])
    end

    it 'reports through compare_many and report without an expensive opt-in' do
      card = todo.active_cards.create!(title: 'card')
      from = checkpoint(todo)
      card.update!(archived: true)
      to = checkpoint(todo)

      result = PaperTrailDiff.compare_many([{ from: from.fetch(todo.id), to: to.fetch(todo.id) }],
                                           associations: paths)
      expect(change(result.values.first, :active_cards)).to eq(empty.merge(removed: ['card']))
      report = PaperTrailDiff.report(ScopeBoard, since: from.fetch(todo.id).created_at - 1,
                                                 limit: 5, associations: paths)
      expect(report.roots.length).to eq(1)
    end
  end
end
