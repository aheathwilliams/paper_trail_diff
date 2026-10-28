# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::PreparedActivityIndex do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
  end

  it 'explains missing graph registration instead of leaking a hash lookup error' do
    records = PaperTrailDiff::PreparedRecordIndex.new(Time.now.utc - 60)
    index = described_class.new(records, [], start_at: Time.now.utc - 60, end_at: Time.now.utc)

    expect do
      index.child_ids(TrackedArticle, [1], TrackedArticle.reflect_on_association(:comments),
                      PaperTrailDiff::ActivityRange.new(Time.now.utc - 60, Time.now.utc))
    end.to raise_error(PaperTrailDiff::ConfigurationError, /missing TrackedArticle.*register/)
  end

  it 'matches SQL candidate selection for pre-window moves, destroys, ties and boundaries' do
    origin = Time.utc(2030, 1, 1)
    # The second entry for identity 2 belongs to an unselected owner. It must
    # still disqualify the older membership, just as the SQL subquery does.
    events = [[1, 1, 'create', true], [2, 1, 'create', true], [2, 5, 'update', false],
              [3, 1, 'create', true], [3, 5, 'destroy', true],
              [4, 5, 'create', true], [4, 5, 'update', true],
              [5, 10, 'create', true], [5, 20, 'destroy', true],
              [6, 21, 'create', true], [7, 5, 'create', true], [7, 12, 'update', true]]
    candidates = events.filter_map do |id, offset, event, selected_owner|
      version = PaperTrail::Version.create!(item_type: 'TrackedComment', item_id: id,
                                            event: event, created_at: origin + offset)
      version if selected_owner
    end
    records = PaperTrailDiff::PreparedRecordIndex.new(origin)
    records.load(TrackedComment, (1..7).to_a)
    index = described_class.new(records, [], start_at: origin, end_at: origin + 30)
    relation = PaperTrail::Version.where(id: candidates.map(&:id))

    [10, 15].each do |start|
      range = PaperTrailDiff::ActivityRange.new(origin + start, origin + 20)
      expected = PaperTrailDiff::VersionAssociationCandidateScope.new(
        PaperTrail::Version, range.start_time, end_at: range.end_time
      ).call(relation).pluck(:id)
      actual = candidates.select do |version|
        row = [1, version.item_id, version.created_at, version.event]
        index.send(:eligible_child?, TrackedComment, row, range)
      end.map(&:id)

      expect(actual).to match_array(expected)
      expect(actual).not_to include(candidates.find { |version| version.item_id.to_s == '2' }.id)
    end
  end
end
