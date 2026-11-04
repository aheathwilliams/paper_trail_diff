# frozen_string_literal: true

require_relative '../support/unversioned_writes'

# Change rows against the writes that made them (see
# spec/support/unversioned_writes.rb). Over the whole history every check
# holds. A window can start inside a transaction whose earlier versions it
# does not read, where a row may stay credited to a version rather than be
# split, so there only the checks a row must always pass are made.
RSpec.describe 'Change rows against unversioned writes' do
  before { Oracle.reset! }

  # With the author requested, `author_id` is its relationship.
  let(:paths) { { [:comments] => [], %i[comments author] => ['author_id'] } }
  let(:groups) { [nil, :transaction] }

  def expect_rows_accounted_for(seed)
    history = UnversionedWrites::History.new(seed, steps: Oracle.steps(16)).build
    described = Struct.new(:describe).new("#{history.writes.size} writes")
    failures = Oracle::Failures.new(seed, described)
    yield history, failures
    expect(failures).to be_empty, -> { failures.message }
  end

  def each_timeline(history, **options)
    paths.each do |associations, structural|
      groups.each do |group|
        steps = PaperTrailDiff.activity_timeline(
          history.article, associations: associations, recorded_changes: true, group: group,
                           **options
        )
        yield steps, "#{associations.inspect} group #{group.inspect}", structural
      end
    end
  end

  Oracle.seeds((1..6).to_a).each do |seed|
    it "accounts for every row of the whole history (seed #{seed})" do
      expect_rows_accounted_for(seed) do |history, failures|
        first = history.article.versions.reorder(:created_at, :id).first
        each_timeline(history, from: first) do |steps, label, structural|
          check = UnversionedWrites::RowCheck.new(history, failures, label,
                                                  strict: true, structural: structural)
          check.call(steps)
          check.complete(steps.flat_map(&:change_rows))
        end
      end
    end

    it "accounts for every row of windows inside the history (seed #{seed})" do
      expect_rows_accounted_for(seed) do |history, failures|
        times = PaperTrail::Version.order(:created_at).pluck(:created_at)
        random = Random.new(seed)
        4.times do |index|
          start, finish = times.sample(2, random: random).sort
          each_timeline(history, within: start..finish) do |steps, label, _structural|
            UnversionedWrites::RowCheck.new(history, failures, "window #{index} #{label}",
                                            strict: false).call(steps)
          end
        end
      end
    end
  end
end
