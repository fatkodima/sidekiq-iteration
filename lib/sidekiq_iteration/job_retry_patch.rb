# frozen_string_literal: true

require "sidekiq/job_retry"

module SidekiqIteration
  # @private
  module JobRetryPatch
    private
      def process_retry(jobinst, msg, queue, exception)
        add_sidekiq_iteration_metadata(jobinst, msg)
        super
      end

      # The method was renamed in https://github.com/mperham/sidekiq/commit/0676a5202e89aa9da4ad7991f4111b97a9d8a0a4.
      def attempt_retry(jobinst, msg, queue, exception)
        add_sidekiq_iteration_metadata(jobinst, msg)
        super
      end

      def add_sidekiq_iteration_metadata(jobinst, msg)
        if jobinst.is_a?(Iteration)
          unless msg["args"].last.is_a?(Hash)
            msg["args"].push({})
          end

          msg["args"].last["sidekiq_iteration"] = {
            "executions" => jobinst.executions,
            "cursor_position" => jobinst.cursor_position,
            "times_interrupted" => jobinst.times_interrupted,
            "total_time" => jobinst.total_time,
          }
        end
      end
  end
end

if Sidekiq::JobRetry.private_method_defined?(:process_retry) ||
   Sidekiq::JobRetry.private_method_defined?(:attempt_retry)
  Sidekiq::JobRetry.prepend(SidekiqIteration::JobRetryPatch)
else
  raise "Sidekiq #{Sidekiq::VERSION} removed the #process_retry method. " \
        "Please open an issue at the `sidekiq-iteration` gem."
end
