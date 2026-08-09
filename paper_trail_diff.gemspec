# frozen_string_literal: true

require_relative 'lib/paper_trail_diff/version'

Gem::Specification.new do |spec|
  spec.name = 'paper_trail_diff'
  spec.version = PaperTrailDiff::VERSION
  spec.authors = ['Alex Williams']
  spec.email = ['alex.williams.dev@gmail.com']

  spec.summary = 'Structured endpoint and activity diffs for PaperTrail'
  spec.description = <<~DESCRIPTION
    paper_trail_diff compares reified PaperTrail histories and returns structured
    attribute and explicitly selected association changes.
  DESCRIPTION
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir.chdir(__dir__) do
    Dir[
      'lib/**/*.rb',
      'sig/generated/**/*.rbs',
      'CHANGELOG.md',
      'LICENSE',
      'README.md'
    ].sort
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'paper_trail', '>= 16', '< 18'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
