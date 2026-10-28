# frozen_string_literal: true

require_relative '../support/string_item_database'

RSpec.describe 'Association history with a string versions.item_id' do
  before do
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    StringItemNote.delete_all
    StringItemPost.delete_all
  end

  def note_changes(diff)
    diff.associations.fetch('notes').changed.map do |change|
      [change.record.id, change.attributes.fetch('body').to_h]
    end
  end

  def checkpoint(post)
    StringItemPost.transaction { StringItemPost.find(post.id).paper_trail.save_with_version }
    post.versions.reload.last
  end

  it 'reads each child once in a checkpoint timeline ending at current state' do
    post = StringItemPost.create!(title: 'Root')
    note = post.notes.create!(body: 'one')
    checkpoint(post)
    note.update!(body: 'two')

    steps = PaperTrailDiff.timeline(post, from: :first, to: post, associations: [:notes])

    expect(note_changes(steps.last.diff)).to eq([[note.id, { from: 'one', to: 'two' }]])
  end

  it 'reads a child-only activity window closed by a later checkpoint' do
    post = StringItemPost.create!(title: 'Root')
    note = post.notes.create!(body: 'one')
    note.update!(body: 'two')
    edit = note.versions.last
    checkpoint(post)

    steps = PaperTrailDiff.activity_timeline(
      post, within: edit.created_at..edit.created_at, associations: [:notes]
    )
    analysis = PaperTrailDiff.analyze(
      post, within: edit.created_at..edit.created_at, associations: [:notes], activity: true
    )

    expect(steps.reject(&:empty?).map { |step| note_changes(step.diff) })
      .to eq([[[note.id, { from: 'one', to: 'two' }]]])
    expect(note_changes(analysis.diff)).to eq([[note.id, { from: 'one', to: 'two' }]])
  end
end
