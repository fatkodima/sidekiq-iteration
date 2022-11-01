# frozen_string_literal: true

module SidekiqIteration
  module Throttling
    # @private
    class ThrottleCondition
      def initialize(condition, backoff)
        @condition = condition
        @backoff = backoff
      end

      def valid?(job)
        @condition.call(job)
      end

      def backoff
        if @backoff.is_a?(Proc)
          @backoff.call
        else
          @backoff
        end
      end
    end

    # @private
    attr_writer :throttle_conditions

    # @private
    def throttle_conditions
      @throttle_conditions ||= []
    end

    # Add a condition under which this job will be throttled.
    #
    # @param backoff [Numeric, #call] (30) a custom backoff (in seconds).
    #   This is the time to wait before retrying the job.
    # @yieldparam job [Sidekiq::Job] current sidekiq job that is yielded to `condition` proc
    # @yieldreturn [Boolean] whether the throttle condition is being met,
    #   indicating that the job should throttle.
    #
    def throttle_on(backoff: 30, &condition)
      throttle_conditions << ThrottleCondition.new(condition, backoff)
    end
  end
end
