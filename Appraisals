# frozen_string_literal: true

# Active Support 8.0 passes the json gem 3 an option it no longer takes, so
# it cannot encode JSON at all there.
appraise 'paper_trail_16' do
  gem 'activerecord', '>= 7.1', '< 8.1'
  gem 'json', '< 3'
  gem 'paper_trail', '~> 16.0'
end

appraise 'paper_trail_17' do
  gem 'activerecord', '>= 7.1', '< 8.2'
  gem 'paper_trail', '~> 17.0'
end
