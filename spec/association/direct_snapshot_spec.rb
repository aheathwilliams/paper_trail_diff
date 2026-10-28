# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'direct snapshot compatibility' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    PreparedDocument.delete_all
  end

  def version_for(model)
    document = model.create!(name: 'Before')
    document.update!(name: 'After')
    [document, document.versions.order(:id).last]
  end

  def omit_name(version)
    version.update_column(:object,
                          PaperTrail.serializer.dump(version.object_deserialized.except('name')))
  end

  it 'normalizes STI states without reification or historical model construction' do
    document, version = version_for(PreparedSpecialDocument)
    expected = version.reify(dup: true).attributes.except('id', 'updated_at')
    allow(PreparedSpecialDocument).to receive(:new).and_call_original
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)

    result = PaperTrailDiff.analyze(document, from: version, to: document)

    expect(PreparedSpecialDocument).not_to have_received(:new)
    expect(result.from_snapshot.type).to eq('PreparedSpecialDocument')
    expect(result.from_snapshot.attributes).to eq(expected)
  end

  it 'does not reapply model attribute writers in the direct path' do
    document, version = version_for(PreparedRewrittenDocument)
    expected = version.reify(dup: true).name
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)

    result = PaperTrailDiff.analyze(document, from: version, to: document)

    expect(result.from_snapshot.attributes.fetch('name')).to eq(expected)
  end

  it 'preserves initialization callbacks for attributes absent from the version' do
    stub_const('CallbackSnapshotDocument', Class.new(PreparedDocument))
    CallbackSnapshotDocument.after_initialize { self.name = 'Callback default' }
    document, version = version_for(CallbackSnapshotDocument)
    omit_name(version)

    expect(PaperTrailDiff::DirectRecordStateLoader.new.call(version)).to be_nil
    result = PaperTrailDiff.analyze(document, from: version, to: document)
    expect(result.from_snapshot.attributes.fetch('name')).to eq('Callback default')
  end

  it 'preserves default-scope attributes instead of substituting column defaults' do
    stub_const('ScopedSnapshotDocument', Class.new(PreparedDocument))
    ScopedSnapshotDocument.class_eval { default_scope { where(name: 'Scope default') } }
    document, version = version_for(ScopedSnapshotDocument)
    omit_name(version)

    expect(PaperTrailDiff::DirectRecordStateLoader.new.call(version)).to be_nil
    result = PaperTrailDiff.analyze(document, from: version, to: document)
    expect(result.from_snapshot.attributes.fetch('name')).to eq('Scope default')
  end

  it 'preserves application defaults that must be evaluated during initialization' do
    stub_const('DefaultSnapshotDocument', Class.new(PreparedDocument))
    DefaultSnapshotDocument.attribute :name, :string, default: -> { 'Runtime default' }
    document, version = version_for(DefaultSnapshotDocument)
    omit_name(version)

    expect(PaperTrailDiff::DirectRecordStateLoader.new.call(version)).to be_nil
    result = PaperTrailDiff.analyze(document, from: version, to: document)
    expect(result.from_snapshot.attributes.fetch('name')).to eq('Runtime default')
  end

  it 'declines virtual attributes and custom attribute types' do
    stub_const('VirtualSnapshotDocument', Class.new(PreparedDocument))
    VirtualSnapshotDocument.attribute :virtual_field, :string
    _document, version = version_for(VirtualSnapshotDocument)
    expect(PaperTrailDiff::DirectRecordStateLoader.new.call(version)).to be_nil

    stub_const('SnapshotCustomType', Class.new(ActiveRecord::Type::String))
    stub_const('CustomSnapshotDocument', Class.new(PreparedDocument))
    CustomSnapshotDocument.attribute :name, SnapshotCustomType.new
    _document, version = version_for(CustomSnapshotDocument)
    expect(PaperTrailDiff::DirectRecordStateLoader.new.call(version)).to be_nil
  end
end
