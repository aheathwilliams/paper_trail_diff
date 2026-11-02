# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::ActivityRootSteps do
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  def snapshot(title)
    PaperTrailDiff::RecordSnapshot.new(type: 'FilterArticle', id: 1, attributes: { title: title },
                                       associations: {})
  end

  def changes(step)
    step.diff.attributes.transform_values { |change| [change.from, change.to] }
  end

  # Created and updated twice, with the snapshot each version names.
  def history
    article = FilterArticle.create!(title: 'Draft')
    %w[Review Final].each { |title| article.update!(title: title) }
    versions = FilterVersion.where(item_id: article.id).order(:id).to_a
    snapshots = versions.zip(%w[Draft Review Final]).to_h do |version, title|
      [PaperTrailDiff::Support.row_key(version), snapshot(title)]
    end
    [article, versions, snapshots]
  end

  it 'builds a step for each mutation the plan reports, from the snapshots of its ends' do
    _article, (created, reviewed, final), snapshots = history
    plan = PaperTrailDiff::RootVersionPlan.contiguous([created, reviewed, final])
                                          .reporting([reviewed])

    steps = described_class.call(plan, snapshots)

    expect(steps.map { |step| [step.from_version, step.to_version] }).to eq([[reviewed, final]])
    expect(changes(steps.sole)).to eq('title' => %w[Review Final])
    expect(steps).to be_frozen
  end

  it 'closes on the live record with the snapshot passed for it, captured when given' do
    article, (created, reviewed,), snapshots = history
    captured_at = Time.utc(2032, 1, 1, 12)
    plan = PaperTrailDiff::RootVersionSelection.new(
      in_range: [created, reviewed], selected: [created, reviewed], after_range: nil,
      windowed: true, live_endpoint: article
    ).call

    steps = described_class.call(plan, snapshots, closing_snapshot: snapshot('Live'),
                                                  captured_at: captured_at)

    expect(changes(steps.last)).to eq('title' => %w[Review Live])
    expect(steps.last.to_boundary.recorded_at).to eq(captured_at)
  end
end
