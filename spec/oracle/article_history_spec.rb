# frozen_string_literal: true

require_relative '../support/oracle'
require_relative '../support/json_versions_table'

RSpec.describe 'Rebuilt article history against the recorded states' do
  before { Oracle.reset! }

  def expect_recorded_states(seed)
    history = Oracle::ArticleHistory.new(seed, steps: Oracle.steps(18)).build
    failures = Oracle::Failures.new(seed, history.recorder)
    yield(history, Oracle::Checker.new(history, failures))
    expect(failures).to be_empty, -> { failures.message }
  end

  serializers = {
    'YAML' => PaperTrail::Serializers::YAML,
    'JSON' => PaperTrail::Serializers::JSON
  }

  serializers.each do |format, serializer|
    context "with #{format} history" do
      around do |example|
        original = PaperTrail.serializer
        PaperTrail.serializer = serializer
        example.run
      ensure
        PaperTrail.serializer = original
      end

      # The SQL Server adapter hands PaperTrail's JSON encoder a type wrapper
      # that refuses `as_json`, so no history can be written there.
      before do
        TrackedAuthor.transaction do
          TrackedAuthor.create!(name: 'probe')
          raise ActiveRecord::Rollback
        end
      rescue StandardError => e
        skip "PaperTrail cannot record #{format} history here: #{e.class}: #{e.message}"
      end

      Oracle.seeds([1, 3]).each do |seed|
        it "rebuilds every endpoint, timeline step and activity step (seed #{seed})" do
          expect_recorded_states(seed) do |_history, checker|
            checker.membership
            checker.endpoints
            checker.timeline
            checker.activity
            checker.activity(group: :transaction)
          end
        end
      end
    end
  end

  context 'with json object columns, which PaperTrail does not cast back' do
    around { |example| JsonVersionsTable.with_json_columns(&example) }

    Oracle.seeds([1, 2]).each do |seed|
      it "rebuilds every endpoint and activity step (seed #{seed})" do
        expect_recorded_states(seed) do |_history, checker|
          checker.endpoints
          checker.activity
        end
      end
    end
  end

  context 'with whole-second version timestamps, as MySQL datetime(0) stores them' do
    before do
      allow(AssociationSpecVersionClock).to receive(:next) do |time|
        (time || Time.now.utc).change(usec: 0)
      end
    end

    Oracle.seeds([3]).each do |seed|
      it "rebuilds every endpoint and activity step (seed #{seed})" do
        expect_recorded_states(seed) do |_history, checker|
          checker.endpoints
          checker.activity(group: :transaction)
        end
      end
    end
  end

  context 'with windows followed only by association edits' do
    Oracle.seeds([6, 7]).each do |seed|
      it "ends each window at its own end, not at the current record (seed #{seed})" do
        expect_recorded_states(seed) do |history, checker|
          window_end = history.recorder.entries.length - 1
          history.close_with_association_edits(3)
          checker.windows_ending_at(window_end, Random.new(seed))
        end
      end
    end
  end

  context 'with two windows that meet between transactions' do
    Oracle.seeds([1, 2, 5]).each do |seed|
      it "reads each activity step in exactly one of them (seed #{seed})" do
        expect_recorded_states(seed) do |_history, checker|
          checker.splits(Random.new(seed))
        end
      end
    end
  end

  context 'with two windows that meet inside a transaction' do
    it 'reads each activity step in exactly one of them' do
      failures = Oracle.seeds([1, 2, 3]).map do |seed|
        Oracle.reset!
        history = Oracle::ArticleHistory.new(seed, steps: Oracle.steps(18)).build
        Oracle::Failures.new(seed, history.recorder).tap do |list|
          Oracle::Checker.new(history, list).splits_inside_transactions
        end
      end

      expect(failures).to all(be_empty), -> { failures.reject(&:empty?).map(&:message).join("\n") }
    end
  end

  context 'with windows that have a root version after them' do
    Oracle.seeds([4, 5]).each do |seed|
      it "rebuilds each window in every method (seed #{seed})" do
        expect_recorded_states(seed) do |history, checker|
          history.close_with_root_edit
          checker.windows(Random.new(seed))
        end
      end
    end
  end
end
