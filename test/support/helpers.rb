# frozen_string_literal: true

module Helpers
  def self.set_sidekiq_logger(logger)
    if Gem::Version.new(Sidekiq::VERSION) >= Gem::Version.new("7.0")
      Sidekiq.default_configuration.logger = logger
    else
      Sidekiq.logger = logger
    end
  end
end
