# frozen_string_literal: true

require_relative '../support/core_database'

# A window whose last change is the root's destruction closes on the absence
# that destruction left, so its net diff ends at nil in every reporting mode.
RSpec.describe 'net diffs for windows closing on a deletion' do
  before do
    PaperTrail::Version.delete_all
    CoreArticle.delete_all
  end

  let(:window_start) { Time.now.utc - 3600 }

  # Created before the window, destroyed inside it.
  def create_removed
    article = CoreArticle.create!(title: 'Existing', internal_note: 'stable')
    article.versions.first.update_column(:created_at, window_start - 86_400)
    article.destroy!
    article
  end

  # Created and destroyed inside the window.
  def create_transient
    article = CoreArticle.create!(title: 'Transient', internal_note: 'stable')
    article.update!(title: 'Transient edited')
    article.destroy!
    article
  end

  def presence(analysis)
    change = analysis.diff.record_presence_change
    change && [change.from&.attributes&.fetch('title'), change.to&.attributes&.fetch('title')]
  end

  def deleted_analyses(activity:)
    PaperTrailDiff.analyze_scope(
      CoreArticle, limit: 10, within: window_start..(Time.now.utc + 60), activity: activity,
                   close_on: :current, include_deleted: true
    ).deleted
  end

  [true, false].each do |activity|
    context "with activity: #{activity}" do
      it 'reports a record that existed before the window as removed' do
        removed = create_removed

        analysis = deleted_analyses(activity: activity).fetch(['CoreArticle', removed.id.to_s])

        expect(presence(analysis)).to eq(['Existing', nil])
        expect(analysis.to_snapshot).to be_nil
      end

      it 'reports no net change for a record created and removed inside the window' do
        transient = create_transient

        analysis = deleted_analyses(activity: activity).fetch(['CoreArticle', transient.id.to_s])

        expect(analysis.diff).to be_empty
        expect(analysis.from_snapshot).to be_nil
        expect(analysis.to_snapshot).to be_nil
      end
    end
  end

  it 'agrees with report' do
    transient = create_transient
    removed = create_removed

    deleted = PaperTrailDiff.report(CoreArticle, since: window_start, limit: 10,
                                                 include_deleted: true).deleted

    expect(deleted.fetch(['CoreArticle', transient.id.to_s]).diff).to be_empty
    expect(presence(deleted.fetch(['CoreArticle', removed.id.to_s]))).to eq(['Existing', nil])
  end

  it 'keeps compare semantics for a range ending at an explicit destroy version' do
    transient = create_transient
    versions = PaperTrail::Version.where(item_id: transient.id.to_s).order(:id).to_a

    analysis = PaperTrailDiff.analyze(transient, from: versions.first, to: versions.last)

    expect(presence(analysis)).to eq([nil, 'Transient edited'])
  end
end
