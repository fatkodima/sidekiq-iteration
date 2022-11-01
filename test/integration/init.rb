# frozen_string_literal: true

require "sidekiq-iteration"
require "logger"
require_relative "jobs"
require_relative "../support/helpers"

# Mute sidekiq logging.
unless ENV["VERBOSE"]
  Helpers.set_sidekiq_logger(nil)

  module Sidekiq
    class CLI
      def print_banner
        # no op
      end
    end
  end
end
