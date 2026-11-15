# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :nested_tasks, force: true do |table|
    table.string :title
    table.integer :parent_id
  end

  create_table :nested_task_notes, force: true do |table|
    table.string :body
    table.string :notable_type
    table.integer :notable_id
  end
end

class NestedTask < ActiveRecord::Base
  belongs_to :parent, class_name: 'NestedTask', optional: true
  has_many :children, class_name: 'NestedTask', foreign_key: :parent_id, inverse_of: :parent
  has_many :notes, class_name: 'NestedTaskNote', as: :notable
  has_paper_trail
end

class NestedTaskNote < ActiveRecord::Base
  belongs_to :notable, polymorphic: true, optional: true
  has_paper_trail
end

# A root of a batch can sit in another root's tree. Its versions after the
# window are events of that tree too, so the other root does not close its
# window on the live rows.
RSpec.describe 'A batch whose root joins another root\'s tree after the window' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [NestedTaskNote, NestedTask].each(&:delete_all)
  end

  def tick
    Time.now.utc.tap { sleep 0.002 }
  end

  it 'reads the root as analyze does, without the later child' do
    first = NestedTask.create!(title: 'a')
    leaving = NestedTask.create!(title: 'c', parent: first)
    joining = NestedTask.create!(title: 'b')
    note = NestedTaskNote.create!(body: 'n')
    start = tick
    leaving.update!(parent: nil)
    finish = tick
    joining.update!(title: 'b renamed later')
    NestedTask.transaction do
      note.update!(notable: leaving)
      joining.update!(parent: first)
    end
    first.reload
    joining.reload
    options = { within: start..finish, associations: ['children.notes'], activity: true,
                snapshots: true }

    single = PaperTrailDiff.analyze(first, **options)
    batch = PaperTrailDiff.analyze_many([first, joining], **options)
                          .fetch(PaperTrailDiff::Endpoint.identity(first))

    expect(batch.to_snapshot.associations.fetch('children').records).to be_empty
    expect(batch.diff.to_h).to eq(single.diff.to_h)
    expect(batch.timeline.map { |step| step.to_boundary.version_id })
      .to eq(single.timeline.map { |step| step.to_boundary.version_id })
  end
end
