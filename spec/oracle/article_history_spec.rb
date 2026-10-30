# frozen_string_literal: true

require_relative '../support/oracle'

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

      Oracle.seeds([1, 3]).each do |seed|
        it "rebuilds every endpoint and activity step (seed #{seed})" do
          expect_recorded_states(seed) do |_history, checker|
            checker.membership
            checker.endpoints
            checker.activity
            checker.activity(group: :transaction)
          end
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
