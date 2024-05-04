# frozen_string_literal: true

require "sidekiq"
require_relative "sidekiq_iteration/iteration"
require_relative "sidekiq_iteration/job_retry_patch"
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

    # Configures a delay duration to wait before resuming an interrupted job.
    #
    # @example
    #   SidekiqIteration.default_retry_backoff = 10.seconds
    #
    # Defaults to nil which means interrupted jobs will be retried immediately.
    # This value will be ignored when an interruption is raised by a throttle enumerator,
    # where the throttle backoff value will take precedence over this setting.
    #
    attr_accessor :default_retry_backoff

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

    # @private
    attr_accessor :stopping
  end
end

Sidekiq.configure_server do |config|
  config.on(:quiet) do
    SidekiqIteration.stopping = true
  end
end
