# frozen_string_literal: true

require_relative '../support/association_database'

# PT-AT compares version times through SQL string conditions, which the SQL
# Server adapter quotes as a legacy `datetime`, up to 1/300 s off. While the
# test clock catches up after the host clock steps back, it hands out
# consecutive microseconds, and the versions the specs write must still
# compare in order that way, or PT-AT misreads the histories the specs
# compare the gem with.
RSpec.describe AssociationSpecVersionClock do
  before { PaperTrail::Version.delete_all }

  # PT-AT compares one version's time with other versions', as here.
  it 'keeps versions in order as a string condition compares them on this database' do
    MonotonicTestClock.advance_past(Time.now + Rational(1, 10))
    versions = Array.new(3) do
      PaperTrail::Version.create!(item_type: 'TrackedArticle', item_id: 1, event: 'update')
    end

    later = versions.map do |version|
      PaperTrail::Version.where.not(id: version.id).where('created_at >= ?', version.created_at)
                         .count
    end
    expect(later).to eq([2, 1, 0])
  end
end
