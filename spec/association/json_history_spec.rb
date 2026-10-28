# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'Association history stored as JSON' do
  around do |example|
    original = PaperTrail.serializer
    PaperTrail.serializer = PaperTrail::Serializers::JSON
    example.run
  ensure
    PaperTrail.serializer = original
  end

  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
    skip_unless_json_history_writable
  end

  # See spec/integration/json_history_spec.rb: some PaperTrail, Ruby, and
  # adapter combinations cannot write JSON history at all.
  def skip_unless_json_history_writable
    TrackedArticle.transaction do
      TrackedArticle.create!(title: 'Probe')
      raise ActiveRecord::Rollback
    end
  rescue StandardError => e
    skip "PaperTrail cannot record JSON history here: #{e.class}: #{e.message}"
  end

  # Attribute names reported as changed anywhere in the diff, with their path.
  def changed_attributes(diff)
    names = []
    diff.each_change do |entry|
      next unless entry.kind == :attribute_changed

      names << [*entry.association_path, entry.attribute].join('.')
    end
    names.sort
  end

  def create_history
    sub_millisecond = Time.utc(2026, 1, 1, 12, 0, 0, Rational(123_456))
    article = TrackedArticle.create!(title: 'Draft', created_at: sub_millisecond)
    comment = article.comments.create!(body: 'First', created_at: sub_millisecond)
    article.update!(title: 'Review')
    comment.update!(body: 'Edited')
    article.update!(title: 'Published')
    article
  end

  it 'compares a version with the current graph without timestamp noise' do
    article = create_history

    diff = PaperTrailDiff.compare(article.versions[1], article, associations: [:comments])

    expect(changed_attributes(diff)).to eq(%w[comments.body title])
  end

  it 'builds prepared activity through current state without timestamp noise' do
    article = create_history

    steps = PaperTrailDiff.activity_timeline(
      article, from: :first, to: article, associations: [:comments]
    )

    expect(steps.map { |step| changed_attributes(step.diff) })
      .to eq([[], [], ['title'], ['comments.body'], ['title']])
  end

  it 'reports through now without timestamp noise' do
    article = create_history

    report = PaperTrailDiff.report(
      TrackedArticle.all, since: Time.utc(2000), limit: 5, associations: [:comments]
    )

    analysis = report.analyses.fetch(['TrackedArticle', article.id.to_s])
    expect(analysis.activity_timeline.map { |step| changed_attributes(step.diff) })
      .to eq([[], [], ['title'], ['comments.body'], ['title']])
  end
end
