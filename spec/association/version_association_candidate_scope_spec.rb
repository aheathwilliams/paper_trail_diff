# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::VersionAssociationCandidateScope do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedReply.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  # SQLite reads these names unquoted and passes times through its type, so
  # the examples that save versions cannot see either. These stand-ins mark both.
  let(:visible_connection) do
    Object.new.tap do |connection|
      connection.define_singleton_method(:quote_table_name) { |name| "[#{name}]" }
      connection.define_singleton_method(:quote_column_name) { |name| "{#{name}}" }
      connection.define_singleton_method(:quote) { |value| "<#{value}>" }
    end
  end

  let(:visible_type) do
    Object.new.tap do |type|
      type.define_singleton_method(:cast) { |time| "cast #{time.strftime('%H:%M')}" }
      type.define_singleton_method(:serialize) { |value| "stored #{value}" }
    end
  end

  # Active Record 7.1 has no `with_connection`, so the scope falls back to
  # `connection` there.
  def visible_version_class(style)
    connection = visible_connection
    types = { 'created_at' => visible_type }
    Object.new.tap do |version_class|
      version_class.define_singleton_method(:table_name) { 'item versions' }
      version_class.define_singleton_method(:type_for_attribute) { |name| types.fetch(name) }
      if style == :with_connection
        version_class.define_singleton_method(:with_connection) { |&block| block.call(connection) }
      else
        version_class.define_singleton_method(:connection) { connection }
      end
    end
  end

  it 'keeps start-state and later candidates without retaining removed history' do
    article = TrackedArticle.create!(title: 'Candidate window')
    stable = article.comments.create!(body: 'Stable at start')
    removed = article.comments.create!(body: 'Removed before start')
    removed.destroy!
    start = article.paper_trail.save_with_version
    recent = article.comments.create!(body: 'Created after start')
    finish = article.paper_trail.save_with_version
    later = article.comments.create!(body: 'Created after finish')
    version_class = PaperTrail::Version
    relation = PaperTrail::VersionAssociation.joins(:version).where(
      foreign_key_name: 'article_id',
      foreign_key_id: article.id,
      versions: { item_type: 'TrackedComment' }
    )

    ids = described_class.new(
      version_class,
      start.created_at,
      end_at: finish.created_at
    ).call(relation).distinct.pluck(version_class.arel_table[:item_id])
    forward = described_class.new(
      version_class,
      start.created_at
    ).call(relation).distinct.pluck(version_class.arel_table[:item_id])
    unbounded = described_class.new(
      version_class,
      nil
    ).call(relation).distinct.pluck(version_class.arel_table[:item_id])

    expect(ids).to contain_exactly(stable.id, recent.id)
    expect(forward).to contain_exactly(stable.id, recent.id, later.id)
    expect(unbounded).to contain_exactly(stable.id, removed.id, recent.id, later.id)
  end

  # SQL Server quotes a bare time as `datetime`, rounded to 1/300 second: a
  # 2.0ms start reads as 3ms and a 5.0ms end as 7ms. Times compared as the
  # column stores them keep a version saved a fraction of a millisecond away
  # on the side it was saved.
  it 'compares boundaries at the precision the versions were saved with' do
    article = TrackedArticle.create!(title: 'Precise window')
    comment = article.comments.create!(body: 'one')
    comment.update!(body: 'two')
    comment.update!(body: 'three')
    created, inside, after = comment.versions.reorder(:id).to_a
    base = Time.utc(2026, 1, 1, 12)
    { created => base, inside => base + 0.0021, after => base + 1.006 }.each do |version, at|
      PaperTrail::Version.where(id: version.id).update_all(created_at: at)
    end
    relation = PaperTrail::VersionAssociation.joins(:version)
                                             .where(versions: { item_type: 'TrackedComment' })

    ids = described_class.new(PaperTrail::Version, base + 0.002, end_at: base + 1.005)
                         .call(relation).distinct.pluck(PaperTrail::Version.arel_table[:id])

    expect(ids).to contain_exactly(created.id, inside.id)
  end

  it 'quotes every name and types every time through the version class' do
    noon = Time.utc(2032, 1, 1, 12)
    relation = Object.new.tap { |where| where.define_singleton_method(:where) { |sql| sql } }
    outer = '[item versions]'
    later = '[paper_trail_diff_later_versions]'
    before_start = "( #{outer}.{created_at} < <stored cast 12:00> AND #{outer}.{event} != " \
                   "<destroy> AND NOT EXISTS ( SELECT 1 FROM #{outer} #{later} WHERE " \
                   "#{later}.{item_type} = #{outer}.{item_type} AND #{later}.{item_id} = " \
                   "#{outer}.{item_id} AND #{later}.{created_at} < <stored cast 12:00> AND " \
                   "#{later}.{created_at} > #{outer}.{created_at} ) )"

    %i[with_connection connection].each do |style|
      bounded = described_class.new(visible_version_class(style), noon, end_at: noon + 3600)

      expect(bounded.call(relation))
        .to eq("( (#{outer}.{created_at} >= <stored cast 12:00> AND #{outer}.{created_at} <= " \
               "<stored cast 13:00>) OR #{before_start} )")
    end
    expect(described_class.new(visible_version_class(:connection), noon).call(relation))
      .to eq("( #{outer}.{created_at} >= <stored cast 12:00> OR #{before_start} )")
  end
end
