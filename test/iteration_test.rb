# frozen_string_literal: true

require "test_helper"

module SidekiqIteration
  class IterationTest < TestCase
    class SimpleIterationJob
      include Sidekiq::Job
      include SidekiqIteration::Iteration

      cattr_accessor :records_performed, default: []
      cattr_accessor :on_start_called, default: 0
      cattr_accessor :on_complete_called, default: 0
      cattr_accessor :on_shutdown_called, default: 0
      cattr_accessor :stop_after_count

      def on_start
        self.class.on_start_called += 1
      end

      def on_complete
        self.class.on_complete_called += 1
      end

      def on_shutdown
        self.class.on_shutdown_called += 1
      end

      private
        def job_should_exit?
          super || (stop_after_count && records_performed.size % stop_after_count == 0)
        end
    end

    def setup
      super
      SimpleIterationJob.descendants.each do |klass|
        klass.records_performed = []
        klass.on_start_called = 0
        klass.on_complete_called = 0
        klass.on_shutdown_called = 0
        klass.stop_after_count = nil
      end
    end

    class MissingBuildEnumeratorJob < SimpleIterationJob
      def each_iteration(*)
      end
    end

    test "#build_enumerator method is missing" do
      assert_raises_with_message(NotImplementedError, /must implement a 'build_enumerator' method/) do
        MissingBuildEnumeratorJob.perform_inline
      end
    end

    class JobWithBuildEnumeratorReturningArray < SimpleIterationJob
      def build_enumerator(*)
        []
      end

      def each_iteration(*)
        raise "should never be called"
      end
    end

    test "#build_enumerator returns array" do
      assert_raises_with_message(ArgumentError, "#build_enumerator is expected to return Enumerator object, but returned Array") do
        JobWithBuildEnumeratorReturningArray.perform_inline
      end
    end

    class MissingEachIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        array_enumerator([1, 2, 3], cursor: cursor)
      end
    end

    test "#each_iteration method is missing" do
      assert_raises_with_message(NotImplementedError, /must implement an 'each_iteration' method/) do
        MissingEachIterationJob.perform_inline
      end
    end

    test "cannot override #perform" do
      assert_raises(RuntimeError, "Job that is using Iteration cannot redefine #perform") do
        Class.new(SimpleIterationJob) do
          def perform(*)
          end
        end
      end
    end

    class NilEnumeratorIterationJob < SimpleIterationJob
      def build_enumerator(*)
      end

      def each_iteration(*)
      end
    end

    test "#build_enumerator returns nil" do
      assert_logged("[SidekiqIteration::Iteration] `build_enumerator` returned nil. Skipping the job.") do
        NilEnumeratorIterationJob.perform_inline
      end
    end

    class ActiveRecordIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        active_record_records_enumerator(Product.all, cursor: cursor)
      end

      def each_iteration(record)
        self.class.records_performed << record
      end
    end

    test "activerecord job" do
      iterate_exact_times(ActiveRecordIterationJob, 2)
      ActiveRecordIterationJob.perform_async

      assert_equal(0, ActiveRecordIterationJob.on_complete_called)

      ActiveRecordIterationJob.perform_one
      assert_equal(2, ActiveRecordIterationJob.records_performed.size)

      job = peek_into_queue
      metadata = iteration_metadata(job)
      assert_equal(1, metadata["times_interrupted"])
      assert_equal(1, metadata["executions"])
      assert_equal(Product.second.id, metadata["cursor_position"])

      ActiveRecordIterationJob.perform_one
      assert_equal(4, ActiveRecordIterationJob.records_performed.size)

      job = peek_into_queue
      metadata = iteration_metadata(job)
      assert_equal(2, metadata["times_interrupted"])
      assert_equal(2, metadata["executions"])
      assert(metadata["cursor_position"])

      assert_equal(0, ActiveRecordIterationJob.on_complete_called)
      assert_equal(2, ActiveRecordIterationJob.on_shutdown_called)
    end

    class BatchActiveRecordIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        active_record_batches_enumerator(Product.all, cursor: cursor, batch_size: 3)
      end

      def each_iteration(record)
        self.class.records_performed << record
      end
    end

    test "activerecord batches complete" do
      BatchActiveRecordIterationJob.perform_inline
      processed_records = Product.order(:id).ids

      assert_jobs_in_queue(0)
      assert_equal([3, 3, 3, 1], BatchActiveRecordIterationJob.records_performed.map(&:size))
      assert_equal(processed_records, BatchActiveRecordIterationJob.records_performed.flatten.map(&:id))
    end

    test "activerecord batches" do
      iterate_exact_times(BatchActiveRecordIterationJob, 1)

      BatchActiveRecordIterationJob.perform_inline
      processed_records = Product.order(:id).ids

      assert_equal(1, BatchActiveRecordIterationJob.records_performed.size)
      assert_equal(3, BatchActiveRecordIterationJob.records_performed.flatten.size)
      assert_equal(1, BatchActiveRecordIterationJob.on_start_called)

      job = peek_into_queue
      metadata = iteration_metadata(job)
      assert_equal(processed_records[2], metadata["cursor_position"])
      assert_equal(1, metadata["times_interrupted"])
      assert_equal(1, metadata["executions"])

      BatchActiveRecordIterationJob.perform_one
      assert_equal(2, BatchActiveRecordIterationJob.records_performed.size)
      assert_equal(6, BatchActiveRecordIterationJob.records_performed.flatten.size)
      assert_equal(1, BatchActiveRecordIterationJob.on_start_called)

      job = peek_into_queue
      metadata = iteration_metadata(job)
      assert_equal(2, metadata["times_interrupted"])
      assert_equal(2, metadata["executions"])
      assert_equal(processed_records[5], metadata["cursor_position"])
      continue_iterating(BatchActiveRecordIterationJob)

      BatchActiveRecordIterationJob.perform_one
      assert_jobs_in_queue(0)
      assert_equal(4, BatchActiveRecordIterationJob.records_performed.size)
      assert_equal(10, BatchActiveRecordIterationJob.records_performed.flatten.size)

      assert_equal(1, BatchActiveRecordIterationJob.on_start_called)
      assert_equal(1, BatchActiveRecordIterationJob.on_complete_called)
    end

    class BatchActiveRecordRelationIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        active_record_relations_enumerator(Product.all, cursor: cursor, batch_size: 3)
      end

      def each_iteration(relation)
        self.class.records_performed << relation
      end
    end

    test "activerecord batch relations" do
      BatchActiveRecordRelationIterationJob.perform_inline

      records_performed = BatchActiveRecordRelationIterationJob.records_performed
      assert_equal([3, 3, 3, 1], records_performed.map(&:count))
      assert(records_performed.all?(ActiveRecord::Relation))
      assert(records_performed.none?(&:loaded?))
    end

    class MultipleColumnsActiveRecordIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        active_record_records_enumerator(
          Product.all,
          cursor: cursor,
          columns: [:updated_at, :id],
          batch_size: 2,
        )
      end

      def each_iteration(record)
        self.class.records_performed << record
      end
    end

    test "multiple columns" do
      iterate_exact_times(MultipleColumnsActiveRecordIterationJob, 3)

      MultipleColumnsActiveRecordIterationJob.perform_async

      1.upto(3) do |iter|
        MultipleColumnsActiveRecordIterationJob.perform_one

        job = peek_into_queue
        last_processed_record = MultipleColumnsActiveRecordIterationJob.records_performed.last
        expected = [last_processed_record.updated_at.strftime("%Y-%m-%d %H:%M:%S.%N"), last_processed_record.id]
        metadata = iteration_metadata(job)
        assert_equal(expected, metadata["cursor_position"])

        assert_equal(iter * 3, MultipleColumnsActiveRecordIterationJob.records_performed.size)
      end

      first_products = Product.all.order(:updated_at, :id).limit(9).to_a
      assert_equal(first_products, MultipleColumnsActiveRecordIterationJob.records_performed)
    end

    class LimitActiveRecordIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        active_record_records_enumerator(Product.limit(5), cursor: cursor)
      end

      def each_iteration(*)
      end
    end

    test "relation with limit" do
      assert_raises_with_message(ArgumentError, /The relation cannot use ORDER BY or LIMIT/) do
        LimitActiveRecordIterationJob.perform_inline
      end
    end

    class OrderedActiveRecordIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        active_record_records_enumerator(Product.order(:name), cursor: cursor)
      end

      def each_iteration(*)
      end
    end

    test "relation with order" do
      assert_raises_with_message(ArgumentError, /The relation cannot use ORDER BY or LIMIT/) do
        OrderedActiveRecordIterationJob.perform_inline
      end
    end

    class MultiArgumentIterationJob < SimpleIterationJob
      def build_enumerator(_one_arg, _another_arg, cursor:)
        array_enumerator([0, 1], cursor: cursor)
      end

      def each_iteration(item, one_arg, another_arg)
        self.class.records_performed << [item, one_arg, another_arg]
      end
    end

    test "supports multiple job arguments" do
      MultiArgumentIterationJob.perform_inline(2, ["a", "b", "c"])

      expected = [
        [0, 2, ["a", "b", "c"]],
        [1, 2, ["a", "b", "c"]],
      ]
      assert_equal(expected, MultiArgumentIterationJob.records_performed)
    end

    class ParamsIterationJob < SimpleIterationJob
      def build_enumerator(_params, cursor:)
        array_enumerator([0, 1], cursor: cursor)
      end

      def each_iteration(_record, params)
        self.class.records_performed << params
      end
    end

    test "passes params to #each_iteration" do
      params = { "walrus" => "best" }
      ParamsIterationJob.perform_inline(params)
      assert_equal([params, params], ParamsIterationJob.records_performed)
    end

    test "passes params to #each_iteration without metadata about interruptions" do
      iterate_exact_times(ParamsIterationJob, 1)
      params = { "walrus" => "yes", "morewalrus" => "si" }
      ParamsIterationJob.perform_inline(params)

      assert_equal([params], ParamsIterationJob.records_performed)

      ParamsIterationJob.perform_one
      assert_equal([params, params], ParamsIterationJob.records_performed)
    end

    test "logs completion data" do
      assert_logged("[SidekiqIteration::Iteration] Completed iterating") do
        ParamsIterationJob.perform_inline({})
      end
    end

    class EmptyEnumeratorJob < SimpleIterationJob
      def build_enumerator(cursor:)
        array_enumerator([], cursor: cursor)
      end

      def each_iteration(*)
      end
    end

    test "logs no iterations" do
      assert_logged("[SidekiqIteration::Iteration] Enumerator found nothing to iterate!") do
        EmptyEnumeratorJob.perform_inline
      end
    end

    class AbortingActiveRecordIterationJob < ActiveRecordIterationJob
      def each_iteration(*)
        abort_strategy if self.class.records_performed.size == 2
        super
      end

      private
        def abort_strategy
          throw(:abort)
        end
    end

    test "aborting in #each_iteration will execute #on_complete callback" do
      AbortingActiveRecordIterationJob.perform_inline

      assert_equal(2, AbortingActiveRecordIterationJob.records_performed.size)
      assert_equal(1, AbortingActiveRecordIterationJob.on_complete_called)
      assert_equal(1, AbortingActiveRecordIterationJob.on_shutdown_called)
    end

    class AbortingBatchActiveRecordIterationJob < SimpleIterationJob
      def build_enumerator(cursor:)
        active_record_batches_enumerator(Product.all, cursor: cursor, batch_size: 3)
      end

      def each_iteration(record)
        self.class.records_performed << record
        abort_strategy if self.class.records_performed.size == 2
      end

      private
        def abort_strategy
          throw(:abort)
        end
    end

    test "aborting in batched job" do
      AbortingBatchActiveRecordIterationJob.perform_inline

      assert_equal(2, AbortingBatchActiveRecordIterationJob.records_performed.size)
      assert_equal([3, 3], AbortingBatchActiveRecordIterationJob.records_performed.map(&:size))
      assert_equal(1, AbortingBatchActiveRecordIterationJob.on_complete_called)
    end

    class AbortingAndSkippingCompleteCallbackActiveRecordIterationJob < AbortingActiveRecordIterationJob
      private
        def abort_strategy
          throw(:abort, :skip_complete_callback)
        end
    end

    test "throwing :skip_complete_callbacks in #each_iteration will not execute #on_complete callback" do
      AbortingAndSkippingCompleteCallbackActiveRecordIterationJob.perform_inline

      assert_equal(2, AbortingAndSkippingCompleteCallbackActiveRecordIterationJob.records_performed.size)
      assert_equal(0, AbortingAndSkippingCompleteCallbackActiveRecordIterationJob.on_complete_called)
      assert_equal(1, AbortingAndSkippingCompleteCallbackActiveRecordIterationJob.on_shutdown_called)
      assert_jobs_in_queue(0)
    end

    class LongRunningJob < SimpleIterationJob
      def build_enumerator(cursor:)
        array_enumerator(10.times.to_a, cursor: cursor)
      end

      def each_iteration(_num)
        sleep(1)
      end
    end

    test "global #max_job_runtime" do
      SidekiqIteration.max_job_runtime = 1.second
      LongRunningJob.perform_inline

      assert_jobs_in_queue(1)
    ensure
      SidekiqIteration.max_job_runtime = nil
    end

    test "local #max_job_runtime" do
      LongRunningJob.max_job_runtime = 1.second
      LongRunningJob.perform_inline

      assert_jobs_in_queue(1)
    ensure
      LongRunningJob.remove_instance_variable(:@max_job_runtime)
    end

    private
      def assert_jobs_in_queue(size)
        assert_equal(size, Sidekiq::Job.jobs.size)
      end

      def peek_into_queue
        jobs = Sidekiq::Job.jobs
        assert_not_empty(jobs)
        jobs.last
      end

      def iteration_metadata(job)
        metadata = job["args"].last.fetch("sidekiq_iteration")
        metadata.slice("times_interrupted", "executions", "cursor_position")
      end

      def iterate_exact_times(job, count)
        job.stop_after_count = count
      end

      def continue_iterating(job)
        job.stop_after_count = nil
      end
  end
end
