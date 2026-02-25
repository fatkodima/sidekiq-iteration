# frozen_string_literal: true

require "test_helper"
require "sidekiq/api"
require_relative "jobs"

module SidekiqIteration
  class IntegrationTest < TestCase
    def setup
      super
      Sidekiq::Testing.disable!
    end

    test "interrupts the job" do
      Sidekiq.redis do |conn|
        IterationJob.perform_async

        conn.set("stop_after_num", 0)
        start_worker_and_wait

        assert_equal(1, queue_size)
        assert_equal(1, iteration_metadata["cursor_position"])
        assert_equal(1, iteration_metadata["times_interrupted"])

        conn.set("stop_after_num", 2)
        start_worker_and_wait

        assert_equal(1, queue_size)
        assert_equal(3, iteration_metadata["cursor_position"])
        assert_equal(2, iteration_metadata["times_interrupted"])

        TerminateJob.perform_async
        conn.del("stop_after_num")
        start_worker_and_wait

        assert_equal(0, queue_size)
      end
    end

    test "failing iteration job" do
      FailingIterationJob.perform_async

      start_worker_and_wait

      Sidekiq.redis do |conn|
        assert_equal(3, iteration_metadata["cursor_position"])
        assert_equal(1, iteration_metadata["executions"])
        assert_equal(0, iteration_metadata["times_interrupted"])
        assert_equal(["0", "1", "2"], conn.lrange("records_performed", 0, -1))
        assert_equal(1, conn.get("on_start_called").to_i)

        start_worker_and_wait

        assert_equal(6, iteration_metadata["cursor_position"])
        assert_equal(2, iteration_metadata["executions"])
        assert_equal(0, iteration_metadata["times_interrupted"])
        assert_equal(["0", "1", "2", "3", "4", "5"], conn.lrange("records_performed", 0, -1))
        assert_equal(1, conn.get("on_start_called").to_i)
        assert_equal(0, conn.get("on_complete_called").to_i)

        # last attempt
        start_worker_and_wait

        assert_equal(1, Sidekiq::RetrySet.new.size)
        assert_equal(["0", "1", "2", "3", "4", "5", "6", "7", "8"], conn.lrange("records_performed", 0, -1))
      end
    end

    test "failing non iteration job" do
      FailingJob.perform_async

      start_worker_and_wait

      assert_nil(iteration_metadata)
    end

    private
      def start_worker_and_wait
        pid = spawn("bundle exec sidekiq -r ./test/integration/init.rb -c 1")
      ensure
        Process.wait(pid)
      end

      def queue_size
        Sidekiq::Queue.new.size
      end

      def job_args
        Sidekiq::Queue.new.first.args
      end

      def iteration_metadata
        job = Sidekiq::Queue.new.first || Sidekiq::RetrySet.new.first
        job["args"].last["sidekiq_iteration"] if job["args"].last.is_a?(Hash)
      end
  end
end
