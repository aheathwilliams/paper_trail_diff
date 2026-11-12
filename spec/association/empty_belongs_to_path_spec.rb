# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :empty_path_owners, force: true do |table|
    table.string :name, null: false
  end

  create_table :empty_path_posts, force: true do |table|
    table.string :title, null: false
    table.integer :owner_id
  end

  create_table :empty_path_notes, force: true do |table|
    table.string :body, null: false
    table.integer :post_id
  end
end

class EmptyPathOwner < ActiveRecord::Base
  has_paper_trail
end

class EmptyPathPost < ActiveRecord::Base
  belongs_to :owner, class_name: 'EmptyPathOwner', optional: true
  has_paper_trail
end

class EmptyPathNote < ActiveRecord::Base
  belongs_to :post, class_name: 'EmptyPathPost', optional: true
  has_paper_trail
end

# No root has a record at the path's first step, so the history holds no
# record of the model the second step starts from.
RSpec.describe 'Activity on a path past a belongs_to that names no record',
               mutant_expression: 'PaperTrailDiff::PreparedActivityIndex' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [EmptyPathNote, EmptyPathPost, EmptyPathOwner].each(&:delete_all)
  end

  let(:options) { { associations: ['post.owner'] } }

  it 'reads a record that never had the first one' do
    note = EmptyPathNote.create!(body: 'alone')
    note.update!(body: 'still alone')

    steps = PaperTrailDiff.activity_timeline(note, **options)

    expect(steps.map { |step| step.diff.attributes.keys }).to eq([[], ['body']])
    expect(steps.last.diff.associations).to be_empty
  end

  it 'reports the first one and its own when the record gains them' do
    note = EmptyPathNote.create!(body: 'alone')
    owner = EmptyPathOwner.create!(name: 'Ann')
    note.update!(post: EmptyPathPost.create!(title: 'Post', owner: owner))

    steps = PaperTrailDiff.activity_timeline(note, **options)

    joined = steps.last.diff.associations.fetch('post').relationship.to
    expect(joined.associations.fetch('owner').records.map(&:id)).to eq([owner.id])
  end

  it 'selects and reads such a record in a report' do
    since = Time.now.utc
    note = EmptyPathNote.create!(body: 'alone')

    report = PaperTrailDiff.report(EmptyPathNote.all, since: since, limit: 5, **options)

    expect(report.analyses.keys).to eq([PaperTrailDiff::Endpoint.identity(note)])
  end
end
