# frozen_string_literal: true

require "sidekiq"
require_relative "sidekiq_iteration/version"

module SidekiqIteration
  class << self
    # Use this to _always_ interrupt the job after it's been running for more than N seconds.
    #
    # This setting will make it to always interrupt a job after it's been iterating for 5 minutes.
    # Defaults to nil which means that jobs will not be interrupted except on termination signal.
    #
    # @example Global setting
    #   SidekiqIteration.max_job_runtime = 5.minutes
    #
    # @example Per-job setting
    #   class MyJob
    #     # ...
    #     self.max_job_runtime = 1.minute
    #     # ...
    #   end
    #
    attr_accessor :max_job_runtime

    # Set a custom logger for sidekiq-iteration.
    # Defaults to `Sidekiq.logger`.
    #
    # @example
    #   SidekiqIteration.logger = Logger.new("log/sidekiq-iteration.log")
    #
    attr_writer :logger

    def logger
      @logger ||= Sidekiq.logger
    end
  end
end

require_relative "sidekiq_iteration/iteration"
require_relative "sidekiq_iteration/job_retry_patch"
