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

  # `versions.item_id` is a string here and the keys integers, so selection
  # reads ids instead of comparing columns in SQL.
  it 'selects posts whose notes changed, or whose note moved between them' do
    first = StringItemPost.create!(title: 'From')
    second = StringItemPost.create!(title: 'To')
    StringItemPost.create!(title: 'Quiet').notes.create!(body: 'still')
    note = first.notes.create!(body: 'one')
    since = Time.now.utc
    note.update!(post: second, body: 'two')

    report = PaperTrailDiff.report(StringItemPost, since: since, associations: [:notes], limit: 10)

    expect(report.roots.map(&:id)).to eq([first.id, second.id])
  end

  it 'does not report a note without a post as an unreachable post' do
    post = StringItemPost.create!(title: 'Quiet')
    note = post.notes.create!(body: 'one')
    since = Time.now.utc
    note.update!(body: 'two')
    StringItemNote.where(id: note.id).update_all(post_id: 0)
    StringItemVersionAssociation.where(foreign_key_name: 'post_id').update_all(foreign_key_id: nil)

    report = PaperTrailDiff.report(StringItemPost, since: since, associations: [:notes], limit: 10)

    expect(report.unreachable).to be_empty
  end

  it 'selects notes whose post was renamed' do
    post = StringItemPost.create!(title: 'Old')
    note = post.notes.create!(body: 'one')
    StringItemPost.create!(title: 'Other').notes.create!(body: 'other')
    since = Time.now.utc
    post.update!(title: 'New')

    report = PaperTrailDiff.report(StringItemNote, since: since, associations: [:post], limit: 10)

    expect(report.roots).to eq([note])
    expect(report.analyses.values.first.diff.associations.fetch('post').changed
                 .attributes.fetch('title').to_h).to eq(from: 'Old', to: 'New')
  end
end
