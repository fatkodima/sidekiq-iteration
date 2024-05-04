# frozen_string_literal: true

require "sidekiq-iteration"
require "logger"
require_relative "jobs"

# Mute sidekiq logging.
unless ENV["VERBOSE"]
  Sidekiq.configure_server do |config|
    config.logger = nil
  end

  module Sidekiq
    class CLI
      def print_banner
        # no op
      end
    end
  end
end
