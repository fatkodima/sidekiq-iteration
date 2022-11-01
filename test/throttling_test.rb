# frozen_string_literal: true

require "test_helper"

module SidekiqIteration
  class ThrottlingTest < TestCase
    class ThrottleJob
      include Sidekiq::Job
      include SidekiqIteration::Iteration

      extend Enumerators

      cattr_accessor :iterations_performed, default: []
      cattr_accessor :on_complete_called, default: 0
      cattr_accessor :should_throttle_sequence, default: []

      throttle_on(backoff: 30.seconds) do
        ThrottleJob.should_throttle_sequence.shift
      end

      def on_complete
        self.class.on_complete_called += 1
      end

      def build_enumerator(cursor:)
        array_enumerator([1, 2, 3], cursor: cursor)
      end

      def each_iteration(record)
        self.class.iterations_performed << record
      end
    end

    class ChildThrottleJob < ThrottleJob
      throttle_on do
        true
      end
    end

    def setup
      super
      ThrottleJob.iterations_performed = []
      ThrottleJob.on_complete_called = 0
      ThrottleJob.should_throttle_sequence = []
    end

    test "pushes job back to the queue if throttle" do
      ThrottleJob.should_throttle_sequence = [false, true, false]
      ThrottleJob.perform_inline

      enqueued = ThrottleJob.jobs
      job = enqueued.first
      runs_metadata = job["args"].last.fetch("sidekiq_iteration")
      assert_equal(1, enqueued.size)
      assert_equal(1, runs_metadata.fetch("cursor_position"))
      assert_equal(1, runs_metadata.fetch("times_interrupted"))

      assert_equal([1, 2], ThrottleJob.iterations_performed)
    end

    test "does not pushed back to queue if not throttle" do
      assert_empty(ThrottleJob.jobs)

      ThrottleJob.should_throttle_sequence = [false, false, false]
      ThrottleJob.perform_inline

      assert_empty(ThrottleJob.jobs)
      assert_equal([1, 2, 3], ThrottleJob.iterations_performed)
    end

    test "does not execute on_complete callback if throttle" do
      ThrottleJob.should_throttle_sequence = [true]

      ThrottleJob.perform_inline
      assert_equal(0, ThrottleJob.on_complete_called)
    end

    test "child jobs copies throttling conditions" do
      assert_not_empty(ThrottleJob.throttle_conditions)
      assert_equal(ThrottleJob.throttle_conditions.size + 1, ChildThrottleJob.throttle_conditions.size)
    end
  end
end
