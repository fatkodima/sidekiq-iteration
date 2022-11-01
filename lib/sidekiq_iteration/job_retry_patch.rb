# frozen_string_literal: true

require "sidekiq/job_retry"

module SidekiqIteration
  # @private
  module JobRetryPatch
    private
      def process_retry(jobinst, msg, queue, exception)
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

        super
      end
  end
end

if Sidekiq::JobRetry.instance_method(:process_retry)
  Sidekiq::JobRetry.prepend(SidekiqIteration::JobRetryPatch)
end
