# frozen_string_literal: true

require_relative "lib/sidekiq_iteration/version"

Gem::Specification.new do |spec|
  spec.name          = "sidekiq-iteration"
  spec.version       = SidekiqIteration::VERSION
  spec.authors       = ["fatkodima", "Shopify"]
  spec.email         = ["fatkodima123@gmail.com"]

  spec.summary       = "Makes your sidekiq jobs interruptible and resumable."
  spec.homepage      = "https://github.com/fatkodima/sidekiq-iteration"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.7.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files         = Dir["*.{md,txt}", "{lib,guides}/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sidekiq", ">= 6.0"
end
