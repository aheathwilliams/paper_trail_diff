# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'simplecov'

coverage_name = ENV.fetch('PAPER_TRAIL_DIFF_COVERAGE', 'core')
SimpleCov.command_name(coverage_name)
SimpleCov.use_merging false
SimpleCov.start do
  enable_coverage :branch
  coverage_dir File.join('coverage', coverage_name)
  add_filter '/spec/'
  if coverage_name == 'associations'
    minimum_coverage line: 95, branch: 80
  else
    add_filter '/association_discovery.rb'
    add_filter '/association_traversal.rb'
    add_filter '/branch_snapshot_refresher.rb'
    add_filter '/diagnostics.rb'
    add_filter '/historical_association_reifier.rb'
    add_filter '/activity_version_collector.rb'
    add_filter '/activity_belongs_to_event_applier.rb'
    add_filter '/activity_collection_event_applier.rb'
    add_filter '/activity_collection_record_updater.rb'
    add_filter '/activity_collection_route_change.rb'
    add_filter '/activity_collection_route_updater.rb'
    add_filter '/activity_event_record_normalizer.rb'
    add_filter '/activity_event_record_resolver.rb'
    add_filter '/activity_event_route_finder.rb'
    add_filter '/activity_event_snapshot_refresher.rb'
    add_filter '/activity_relationship.rb'
    add_filter '/activity_root_snapshot_refresher.rb'
    add_filter '/prepared_record_index.rb'
    add_filter '/prepared_history.rb'
    add_filter '/prepared_edge_loader.rb'
    add_filter '/prepared_history_loader.rb'
    add_filter '/prepared_association_reifier.rb'
    add_filter '/timeline_snapshot_provider.rb'
    minimum_coverage line: 85, branch: 60
  end
end

require 'paper_trail_diff'
