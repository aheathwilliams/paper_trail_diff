# frozen_string_literal: true

require_relative '../support/string_item_database'
require_relative '../support/consistency_checks'

RSpec.describe 'Consistency across methods on generated association histories' do
  include ConsistencyChecks

  before do
    [PaperTrail::VersionAssociation, PaperTrail::Version, TrackedComment, TrackedArticle,
     StringItemVersionAssociation, StringItemVersion, StringItemNote, StringItemPost]
      .each(&:delete_all)
  end

  schemas = {
    'an integer versions.item_id' => [TrackedArticle, :comments, 'TrackedArticle'],
    'a string versions.item_id' => [StringItemPost, :notes, 'StringItemPost']
  }
  serializers = {
    'YAML' => PaperTrail::Serializers::YAML,
    'JSON' => PaperTrail::Serializers::JSON
  }

  schemas.each do |schema, (root_class, children, scope_name)|
    serializers.each do |format, serializer|
      context "with #{schema} and #{format} history" do
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
          root_class.transaction do
            root_class.create!(title: 'Probe')
            raise ActiveRecord::Rollback
          end
        rescue StandardError => e
          skip "PaperTrail cannot record #{format} history here: #{e.class}: #{e.message}"
        end

        ConsistencyChecks::SEEDS.each do |seed|
          it "agrees on the whole history and on random windows (seed #{seed})" do
            root = ConsistencyChecks::History.new(root_class, seed: seed, children: children).build

            expect_whole_history_consistent(root, associations: [children])
            windows = Random.new(seed)
            3.times do
              expect_window_consistent(root, associations: [children],
                                             scope: Object.const_get(scope_name), random: windows)
            end
          end
        end
      end
    end
  end
end
