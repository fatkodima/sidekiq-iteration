# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in sidekiq-iteration.gemspec
gemspec

gem "rake", "~> 12.0"
gem "minitest", "~> 5.16"
gem "yard", "~> 0.9.28"
gem "rubocop", "< 2"
gem "rubocop-minitest", "~> 0.22"
gem "sqlite3", "~> 1.5"
gem "activerecord", "~> 7.0"

# Will be removed from stdlib in ruby 3.4.
gem "csv"

if defined?(@sidekiq_requirement)
  gem "sidekiq", @sidekiq_requirement
else
  gem "sidekiq" # latest
end
