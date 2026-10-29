# frozen_string_literal: true

require_relative '../support/recorded_changes_database'

RSpec.describe PaperTrailDiff::RecordedChanges do
  before { [RecordedVersion, UnrecordedVersion, RecordedNote].each(&:delete_all) }

  def recorded(version, **options)
    PaperTrailDiff.recorded_changes(version, **options)
  end

  def event_version(note, event)
    RecordedVersion.where(item_id: note.id, event: event).order(:id).last
  end

  def edited_note
    note = RecordedNote.create!(title: 'Draft', rank: 1, stage: :draft)
    note.update!(title: 'Published', rank: 2, stage: :published)
    note
  end

  it 'reports an update as typed value changes in name order, leaving out updated_at' do
    result = recorded(event_version(edited_note, 'update'))

    # PaperTrail stores them in the order they were assigned, title first.
    expect(result.keys).to eq(%w[rank stage title])
    expect(result.transform_values(&:to_h)).to eq(
      'rank' => { from: 1, to: 2 },
      'stage' => { from: 'draft', to: 'published' },
      'title' => { from: 'Draft', to: 'Published' }
    )
  end

  it 'takes ignored names as strings or symbols, and includes updated_at given an empty list' do
    version = event_version(edited_note, 'update')

    expect(recorded(version, ignore: []).keys).to eq(%w[rank stage title updated_at])
    expect(recorded(version, ignore: [:rank, 'updated_at', :stage]).keys).to eq(%w[title])
  end

  it 'takes ignored names in subclasses of Array and String, as other methods do' do
    version = event_version(edited_note, 'update')
    names = Class.new(Array).new([Class.new(String).new('rank')]) # such as ActiveSupport::SafeBuffer

    expect(recorded(version, ignore: names).keys).to eq(%w[stage title updated_at])
  end

  it 'leaves out every column of a composite primary key' do
    changes = { 'note_id' => [1, 2], 'name' => %w[ruby rails], 'colour' => %w[red blue] }
    version = RecordedVersion.create!(item_type: 'RecordedTag', item_id: 1, event: 'update',
                                      object_changes: PaperTrail.serializer.dump(changes))

    expect(recorded(version).keys).to eq(%w[colour])
  end

  it 'reports no change to an attribute has_paper_trail ignores, which a step still shows' do
    note = RankIgnoringNote.create!(title: 'Draft', rank: 1)
    note.update!(title: 'Published', rank: 2)
    note.update!(title: 'Final')
    version = RecordedVersion.where(item_id: note.id, event: 'update').order(:id).first
    step = PaperTrailDiff.timeline(note).find do |candidate|
      candidate.source_boundary.version_id == version.id
    end

    expect(recorded(version).keys).to eq(%w[title])
    expect(step.diff.attributes.keys).to eq(%w[rank title])
  end

  it 'reports a create from nil, without the primary key' do
    note = RecordedNote.create!(title: 'Draft', rank: 1)
    result = recorded(event_version(note, 'create'), ignore: [])

    expect(result.keys).to eq(%w[created_at rank title updated_at])
    expect(result.fetch('title').to_h).to eq(from: nil, to: 'Draft')
  end

  # PaperTrail's own changeset reads the stored integer here, 1.
  it "types a deleted record's last values from its model, without a query" do
    note = RecordedNote.create!(title: 'Draft', stage: :published)
    note.destroy!
    version = event_version(note, 'destroy')
    queries = []
    record_query = lambda do |*, payload|
      queries << payload.fetch(:sql) unless payload[:name] == 'SCHEMA'
    end

    result = ActiveSupport::Notifications.subscribed(record_query, 'sql.active_record') do
      recorded(version)
    end

    expect(result.fetch('stage').to_h).to eq(from: 'published', to: nil)
    expect(queries).to be_empty
  end

  it 'returns a frozen hash of frozen values' do
    result = recorded(event_version(edited_note, 'update'))
    stage = result.fetch('stage')

    expect(result).to be_frozen
    expect(stage).to be_frozen
    expect(stage.to).to be_frozen
  end

  it 'returns an empty hash, not nil, for a version that recorded no changes' do
    note = RecordedNote.create!(title: 'Draft')
    RecordedNote.transaction { RecordedNote.find(note.id).paper_trail.save_with_version }

    expect(recorded(event_version(note, 'update'))).to eq({}).and be_frozen
  end

  it 'returns nil when the version table has no object_changes column' do
    note = UnrecordedNote.create!(title: 'Draft')
    note.update!(title: 'Published')

    expect(recorded(note.versions.last)).to be_nil
  end

  it 'returns nil when the version stored no object_changes value' do
    version = event_version(edited_note, 'update')
    version.update_column(:object_changes, nil)

    expect(recorded(version.reload)).to be_nil
  end

  context 'with an object_changes adapter that loads changesets itself' do
    def use_adapter(changes)
      adapter = Object.new
      adapter.define_singleton_method(:load_changeset) { |_version| changes }
      allow(PaperTrail.config).to receive(:object_changes_adapter).and_return(adapter)
    end

    it 'reads its changes, whose names may be symbols' do
      version = event_version(edited_note, 'update')
      use_adapter(title: %w[Draft Published], id: [1, 1])

      expect(recorded(version).transform_values(&:to_h))
        .to eq('title' => { from: 'Draft', to: 'Published' })
    end

    it 'returns nil when it has none' do
      version = event_version(edited_note, 'update')
      use_adapter(nil)

      expect(recorded(version)).to be_nil
    end
  end

  it 'rejects anything but a version' do
    expect { recorded(edited_note) }
      .to raise_error(PaperTrailDiff::InvalidEndpointError, /PaperTrail version/)
  end

  it 'rejects ignore: values that are not a list of names, even when nothing was recorded' do
    version = event_version(edited_note, 'update')
    unrecorded = UnrecordedNote.create!(title: 'Draft').versions.last

    [{ all: [] }, [1]].each do |ignore|
      expect { recorded(version, ignore: ignore) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /array of strings or symbols/)
    end
    expect { recorded(unrecorded, ignore: 'title') }
      .to raise_error(PaperTrailDiff::ConfigurationError, /array of strings or symbols/)
  end
end
