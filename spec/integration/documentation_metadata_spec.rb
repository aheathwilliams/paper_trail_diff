# frozen_string_literal: true

require_relative '../support/core_database'
require_relative '../support/documentation_examples'

RSpec.describe 'documented file metadata callback' do
  before do
    PaperTrail::Version.delete_all
    ActiveRecord::Schema.define do
      create_table :document_revisions, force: true do |table|
        table.string :filename
        table.string :checksum
        table.string :content_type
        table.integer :byte_size
        table.references :attachable, polymorphic: true
        table.timestamps
      end
    end
    # Exercise the documented callback with real AR/PaperTrail saves. Storage
    # is a stand-in: this gem's bundle deliberately does not install Rails.
    base = Class.new(ActiveRecord::Base) do
      def self.has_one_attached(name)
        attr_accessor name
      end
    end
    stub_const('ApplicationRecord', base)
    base.abstract_class = true
    stub_const('DocumentRevision', Class.new(base))
    DocumentationExamples.evaluate(File.expand_path('../../docs/reference.md', __dir__),
                                   session: 'reference-file-metadata', context: TOPLEVEL_BINDING)
  end

  def attachment(filename, checksum)
    blob = double(filename: filename, checksum: checksum, content_type: 'text/plain', byte_size: 5)
    double(attached?: true, blob: blob)
  end

  it 'records original metadata and file replacement in the versioned save' do
    revision = DocumentRevision.new(file: attachment('before.txt', 'before'))
    revision.save!
    expect(revision.versions.last.changeset.fetch('filename')).to eq([nil, 'before.txt'])
    revision.file = attachment('after.txt', 'after')
    revision.save!

    expect(revision.versions.count).to eq(2)
    expect(revision.versions.last.changeset.fetch('filename')).to eq(%w[before.txt after.txt])
    expect(revision.versions.last.reify.filename).to eq('before.txt')
    expect(PaperTrailDiff.compare(revision.versions.last,
                                  revision).attributes.fetch('filename').to_h)
      .to eq(from: 'before.txt', to: 'after.txt')
  end
end
