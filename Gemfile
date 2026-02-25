# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in sidekiq-iteration.gemspec
gemspec

gem "rake"
gem "minitest"
gem "yard"
gem "rubocop"
gem "rubocop-minitest"
gem "sqlite3"
gem "activerecord", "~> 7.0"

# Will be removed from stdlib in ruby 3.4.
gem "csv"

if defined?(@sidekiq_requirement)
  gem "sidekiq", @sidekiq_requirement
else
  gem "sidekiq" # latest
end
