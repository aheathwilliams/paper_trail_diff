# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :sti_root_folders, force: true do |table|
    table.string :type
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :sti_root_files, force: true do |table|
    table.string :name, null: false
    table.integer :folder_id
    table.timestamps null: false
  end
end

class StiRootFolder < ActiveRecord::Base
  has_paper_trail
end

# Only the subclass declares the association.
class StiRootSharedFolder < StiRootFolder
  has_many :files, class_name: 'StiRootFile', foreign_key: :folder_id, inverse_of: :folder
end

class StiRootFile < ActiveRecord::Base
  belongs_to :folder, class_name: 'StiRootSharedFolder', optional: true, inverse_of: :files
  has_paper_trail
end

# The versions table has no `item_subtype` column, so PaperTrail stores only
# the base class. The subclass, and the associations it declares, must come
# from the type each version stored.
RSpec.describe 'An association declared by an STI root subclass' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [StiRootFile, StiRootFolder].each(&:delete_all)
  end

  def checkpoint(folder)
    StiRootFolder.transaction { StiRootFolder.find(folder.id).paper_trail.save_with_version }
    folder.versions.reorder(:created_at, :id).last
  end

  def names(records)
    records.map { |record| record.attributes['name'] }
  end

  def files(diff)
    change = diff.associations.fetch('files')
    { added: names(change.added), removed: names(change.removed),
      changed: change.changed.map { |record| record.attributes.fetch('name').to_h } }
  end

  let(:paths) { { associations: [:files] } }
  let(:folder) { StiRootSharedFolder.create!(name: 'Docs') }
  let(:other) { StiRootSharedFolder.create!(name: 'Other') }

  it 'compares two versions' do
    file = folder.files.create!(name: 'notes')
    from = checkpoint(folder)
    file.update!(folder: other)
    to = checkpoint(folder)

    expect(files(PaperTrailDiff.compare(from, to, **paths)))
      .to eq(added: [], removed: ['notes'], changed: [])
  end

  it 'compares a version with the current record' do
    from = checkpoint(folder)
    folder.files.create!(name: 'new')

    expect(files(PaperTrailDiff.compare(from, folder, **paths)))
      .to eq(added: ['new'], removed: [], changed: [])
  end

  it 'compares many roots in one batch' do
    file = folder.files.create!(name: 'notes')
    from = checkpoint(folder)
    other_from = checkpoint(other)
    file.update!(folder: other)
    to = checkpoint(folder)

    results = PaperTrailDiff.compare_many(
      [{ from: from, to: to }, { from: other_from, to: other }], **paths
    )

    expect(results.transform_values { |diff| files(diff) }).to eq(
      ['StiRootFolder', folder.id.to_s] => { added: [], removed: ['notes'], changed: [] },
      ['StiRootFolder', other.id.to_s] => { added: ['notes'], removed: [], changed: [] }
    )
  end

  it 'reports through analyses and timelines' do
    file = folder.files.create!(name: 'notes')
    from = checkpoint(folder)
    file.update!(name: 'notes 2')
    to = checkpoint(folder)
    expected = { added: [], removed: [], changed: [{ from: 'notes', to: 'notes 2' }] }

    checkpoints = PaperTrailDiff.analyze(folder, from: from, to: to, **paths)
    activity = PaperTrailDiff.analyze(folder, from: from, to: to, activity: true, **paths)

    timeline = PaperTrailDiff.timeline(folder, from: from, to: to, **paths)
    window = from.created_at..to.created_at
    batched = PaperTrailDiff.analyze_many([folder], within: window, **paths).values.first

    expect(files(checkpoints.diff)).to eq(expected)
    expect(files(activity.diff)).to eq(expected)
    expect(timeline.map { |step| files(step.diff) }).to eq([expected])
    expect(files(batched.diff)).to eq(expected)
    file_steps = activity.activity_timeline.select { |step| step.diff.associations.key?('files') }
    expect(file_steps.map { |step| [step.from_boundary.item_type, files(step.diff)] })
      .to eq([['StiRootFile', expected]])
  end

  it 'reads the subclass from the change a create version recorded' do
    created = folder.versions.reorder(:created_at, :id).first
    folder.files.create!(name: 'notes')
    to = checkpoint(folder)

    diff = PaperTrailDiff.compare(created, to, **paths)

    expect(created.event).to eq('create')
    expect([diff.record_presence_change.from, diff.record_presence_change.to&.type])
      .to eq([nil, 'StiRootSharedFolder'])
  end

  # As it would against a current record of the base class: the later state
  # has no such association to compare.
  it 'rejects the association at a version where the record was the base class' do
    from = checkpoint(folder)
    StiRootFolder.find(folder.id).update!(type: nil)
    to = checkpoint(folder)

    expect { PaperTrailDiff.compare(from, to, **paths) }
      .to raise_error(PaperTrailDiff::UnknownAssociationError, /files/)
  end

  it 'names a stored type that no longer resolves to a class' do
    version = checkpoint(folder)
    stored = version.object.sub('StiRootSharedFolder', 'StiRootRemovedFolder')
    version.update_column(:object, stored)

    expect { PaperTrailDiff.compare(version, folder, **paths) }
      .to raise_error(PaperTrailDiff::InvalidEndpointError, /StiRootRemovedFolder/)
  end

  describe 'PaperTrailDiff::RecordedClass.for' do
    # Its object cannot be read, so a result proves it was never read.
    let(:unreadable) do
      Struct.new(:item_type, :item_subtype, :item_id) do
        def reify = nil
        def object = '---'
        def object_deserialized = raise('object read')
      end
    end

    def version_double(item_type, item_subtype: nil)
      unreadable.new(item_type, item_subtype, 1)
    end

    it 'trusts a recorded item_subtype without reading the object' do
      version = version_double('StiRootFolder', item_subtype: 'StiRootSharedFolder')

      expect(PaperTrailDiff::RecordedClass.for(version)).to eq(StiRootSharedFolder)
    end

    it 'reads no object for a model without an inheritance column' do
      expect(PaperTrailDiff::RecordedClass.for(version_double('TrackedArticle')))
        .to eq(TrackedArticle)
    end

    it 'keeps the base class for a version that stored no type' do
      folder = StiRootFolder.create!(name: 'Plain')
      folder.update!(name: 'Plain 2')

      expect(PaperTrailDiff::RecordedClass.for(folder.versions.reorder(:id).last))
        .to eq(StiRootFolder)
    end
  end
end
