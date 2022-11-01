# frozen_string_literal: true

require "sidekiq-iteration"
require "logger"
require_relative "jobs"

# Mute sidekiq logging.
unless ENV["VERBOSE"]
  Sidekiq.logger = nil

  module Sidekiq
    class CLI
      def print_banner
        # no op
      end
    end
  end
end
