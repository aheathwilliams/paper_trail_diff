# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  %i[polymorphic_pages polymorphic_posts polymorphic_drafts polymorphic_plains].each do |name|
    create_table name, force: true do |table|
      table.string :title, null: false
      table.boolean :hidden, null: false, default: false
      table.timestamps null: false
    end
  end

  create_table :polymorphic_notes, force: true do |table|
    table.string :body, null: false
    table.references :notable, polymorphic: true
    table.timestamps null: false
  end
end

class PolymorphicPage < ActiveRecord::Base
  has_many :notes, class_name: 'PolymorphicNote', as: :notable, inverse_of: :notable
  has_paper_trail
end

class PolymorphicPost < ActiveRecord::Base
  has_paper_trail
end

class PolymorphicDraft < ActiveRecord::Base
  default_scope { where(hidden: false) }
  has_paper_trail
end

class PolymorphicPlain < ActiveRecord::Base
end

class PolymorphicNote < ActiveRecord::Base
  belongs_to :notable, polymorphic: true, optional: true
  has_paper_trail
end

RSpec.describe 'Polymorphic belongs_to history' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [PolymorphicNote, PolymorphicPage, PolymorphicPost, PolymorphicPlain].each(&:delete_all)
    PolymorphicDraft.unscoped.delete_all
  end

  def notable(analysis)
    analysis.diff.associations.fetch('notable').to_h
  end

  def title(side)
    side && [side.fetch(:type), side.fetch(:attributes).fetch('title')]
  end

  def analyses(record, **options)
    [PaperTrailDiff.analyze(record, **options),
     PaperTrailDiff.analyze_many([record], **options).fetch(PaperTrailDiff::Endpoint.identity(record))]
  end

  def statements(&block)
    count = 0
    callback = lambda do |*, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    count
  end

  it 'reports a change to the target when the record did not change' do
    page = PolymorphicPage.create!(title: 'Old')
    note = PolymorphicNote.create!(body: 'one', notable: page)
    start = Time.now.utc
    page.update!(title: 'New')

    window = start..Time.now.utc

    analyses(note, within: window, associations: [:notable], activity: true).each do |analysis|
      expect(notable(analysis).dig(:changed, :attributes, 'title')).to eq(from: 'Old', to: 'New')
    end
  end

  it 'reports a move between targets of different classes in both modes' do
    page = PolymorphicPage.create!(title: 'Page old')
    post = PolymorphicPost.create!(title: 'Post old')
    note = PolymorphicNote.create!(body: 'one', notable: page)
    start = Time.now.utc
    page.update!(title: 'Page new')
    note.update!(notable: post)
    post.update!(title: 'Post new')
    options = { within: start..Time.now.utc, associations: [:notable] }

    # A checkpoint starts at the note's own version, after the page was renamed.
    { false => 'Page new', true => 'Page old' }.each do |activity, from|
      analyses(note, **options, activity: activity).each do |analysis|
        relationship = notable(analysis).fetch(:relationship)
        expect([title(relationship[:from]), title(relationship[:to])])
          .to eq([['PolymorphicPage', from], ['PolymorphicPost', 'Post new']])
      end
    end
  end

  it 'reports a target gained from none' do
    page = PolymorphicPage.create!(title: 'Page')
    note = PolymorphicNote.create!(body: 'loose')
    start = Time.now.utc
    note.update!(notable: page)

    analyses(note, within: start..Time.now.utc, associations: [:notable]).each do |analysis|
      relationship = notable(analysis).fetch(:relationship)
      expect([relationship[:from], title(relationship[:to])]).to eq([nil, %w[PolymorphicPage Page]])
    end
  end

  it 'reports records whose target changed' do
    page = PolymorphicPage.create!(title: 'Old')
    note = PolymorphicNote.create!(body: 'one', notable: page)
    PolymorphicNote.create!(body: 'other', notable: PolymorphicPost.create!(title: 'Quiet'))
    since = Time.now.utc
    page.update!(title: 'New')

    report = PaperTrailDiff.report(PolymorphicNote, since: since, limit: 10,
                                                    associations: [:notable])

    expect(report.roots).to eq([note])
    expect(notable(report.analyses.values.first).dig(:changed, :attributes, 'title'))
      .to eq(from: 'Old', to: 'New')
  end

  it 'reads the targets of many records without a query for each' do
    targets = [PolymorphicPage.create!(title: 'Page'), PolymorphicPost.create!(title: 'Post')]
    notes = Array.new(8) do |index|
      PolymorphicNote.create!(body: 'one', notable: targets[index % 2])
    end
    start = Time.now.utc
    notes.each { |note| note.update!(body: 'two') }
    targets.each { |target| target.update!(title: "#{target.title} new") }
    options = { within: start..Time.now.utc, associations: [:notable], activity: true }

    counts = [notes.first(2), notes].map do |batch|
      statements { PaperTrailDiff.analyze_many(batch, **options) }
    end

    expect(counts.uniq.size).to eq(1)
  end

  # A default scope decides what the association returns, so a target it
  # hides is read as Active Record would read it: as no target.
  it 'reads a default-scoped target as its association does' do
    draft = PolymorphicDraft.create!(title: 'Visible')
    note = PolymorphicNote.create!(body: 'one', notable: draft)
    draft.update!(title: 'Hidden', hidden: true)
    start = Time.now.utc
    note.update!(body: 'two')

    analyses(note, within: start..Time.now.utc, associations: [:notable]).each do |analysis|
      expect(analysis.from_snapshot.associations.fetch('notable').records).to be_empty
    end
    expect(PolymorphicNote.find(note.id).notable).to be_nil
  end

  it 'raises when a record points at a class that is not versioned' do
    note = PolymorphicNote.create!(body: 'one', notable: PolymorphicPlain.create!(title: 'Plain'))
    start = Time.now.utc
    note.update!(body: 'two')

    window = start..Time.now.utc

    expect { PaperTrailDiff.analyze_many([note], within: window, associations: [:notable]) }
      .to raise_error(PaperTrailDiff::UnversionedAssociationError,
                      /PolymorphicNote#notable .*PolymorphicPlain, which is not versioned/)
  end

  # Seeded moves between targets of both classes and none, target renames, and
  # transactions that do both: a single analysis and a batch read the same
  # history through different queries, so they must agree step by step. Seed
  # 13 closes a window on a move to a target renamed inside it.
  it 'gives the same activity for one record as for a batch on seeded histories' do
    (8..13).each do |seed|
      random = Random.new(seed)
      targets = [PolymorphicPage.create!(title: 'p0'), PolymorphicPost.create!(title: 'q0'),
                 PolymorphicPage.create!(title: 'p1')]
      notes = Array.new(3) do
        PolymorphicNote.create!(body: 'n', notable: targets.sample(random: random))
      end
      times = [Time.now.utc]
      12.times do |step|
        PolymorphicNote.transaction do
          note = notes.sample(random: random)
          case random.rand(4)
          when 0 then note.update!(body: "b#{step}")
          when 1 then note.update!(notable: [*targets, nil].sample(random: random))
          when 2 then targets.sample(random: random).update!(title: "t#{step}")
          else
            note.update!(notable: targets.sample(random: random))
            note.notable.update!(title: "x#{step}")
          end
        end
        times << Time.now.utc
      end
      windows = Array.new(3) { Range.new(*times.sample(2, random: random).sort) }

      windows.each do |window|
        options = { within: window, associations: [:notable], activity: true, snapshots: true }
        batch = PaperTrailDiff.analyze_many(notes, **options)
        notes.each do |note|
          steps = [PaperTrailDiff.analyze(note, **options),
                   batch.fetch(PaperTrailDiff::Endpoint.identity(note))].map do |analysis|
            analysis.activity_timeline.map { |step| [step.diff.to_h, step.to_snapshot&.to_h] }
          end
          expect(steps.last).to eq(steps.first), "seed #{seed}, note #{note.id}, window #{window}"
        end
      end
    end
  end

  it 'rejects a path that continues past a polymorphic target' do
    note = PolymorphicNote.create!(body: 'one', notable: PolymorphicPage.create!(title: 'Page'))

    expect { PaperTrailDiff.compare(note, note, associations: ['notable.notes']) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                      'unsupported association notable.notes: notable is polymorphic, ' \
                      'so a path cannot continue past it')
  end
end
