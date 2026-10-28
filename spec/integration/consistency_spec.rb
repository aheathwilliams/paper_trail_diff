# frozen_string_literal: true

require_relative '../support/core_database'
require_relative '../support/consistency_checks'

RSpec.describe 'Consistency across methods on generated root histories' do
  include ConsistencyChecks

  before do
    [PaperTrail::Version, CoreArticle, SkippingArticle].each(&:delete_all)
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

      # See spec/integration/json_history_spec.rb: some PaperTrail, Ruby, and
      # adapter combinations cannot write JSON history at all.
      before do
        CoreArticle.transaction do
          CoreArticle.create!(title: 'Probe', internal_note: 'probe')
          raise ActiveRecord::Rollback
        end
      rescue StandardError => e
        skip "PaperTrail cannot record #{format} history here: #{e.class}: #{e.message}"
      end

      ConsistencyChecks::SEEDS.each do |seed|
        it "agrees on a root history and on random windows (seed #{seed})" do
          root = ConsistencyChecks::History.new(
            CoreArticle, seed: seed, attributes: { internal_note: 'stable' }
          ).build

          expect_whole_history_consistent(root, associations: [])
          windows = Random.new(seed)
          3.times do
            expect_window_consistent(root, associations: [], scope: CoreArticle, random: windows)
          end
        end

        it "never reports a skip: column, which history does not hold (seed #{seed})" do
          root = ConsistencyChecks::History.new(SkippingArticle, seed: seed).build
          root.update!(view_count: seed * 10)

          expect_whole_history_consistent(root, associations: [])
          reported = PaperTrailDiff.analyze(root, activity: true).activity_timeline
                                   .flat_map { |step| step.diff.attributes.keys }
          expect(reported).not_to include('view_count')
        end
      end
    end
  end
end
