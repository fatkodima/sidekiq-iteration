# frozen_string_literal: true

require_relative "throttling"
require_relative "enumerators"

module SidekiqIteration
  module Iteration
    include Enumerators

    # @private
    def self.included(base)
      base.extend(ClassMethods)
      base.extend(Throttling)

      base.class_eval do
        throttle_on(backoff: 0) do |job|
          job.class.max_job_runtime &&
            job.start_time &&
            (Time.now.utc - job.start_time) > job.class.max_job_runtime
        end

        throttle_on(backoff: 0) do
          defined?(Sidekiq::CLI) &&
            Sidekiq::CLI.instance.launcher.stopping?
        end
      end

      super
    end

    # @private
    module ClassMethods
      def inherited(base)
        base.throttle_conditions = throttle_conditions.dup
        super
      end

      def method_added(method_name)
        if method_name == :perform
          raise "Job that is using Iteration cannot redefine #perform"
        end

        super
      end

      attr_writer :max_job_runtime

      def max_job_runtime
        if defined?(@max_job_runtime)
          @max_job_runtime
        else
          SidekiqIteration.max_job_runtime
        end
      end
    end

    attr_reader :executions,
      :cursor_position,
      :start_time,
      :times_interrupted,
      :total_time,
      :current_run_iterations

    # @private
    def initialize
      super
      @arguments = nil
      @job_iteration_retry_backoff = nil
      @needs_reenqueue = false
      @current_run_iterations = 0
    end

    # @private
    def perform(*arguments)
      extract_previous_runs_metadata(arguments)
      @arguments = arguments
      interruptible_perform(*arguments)
    end

    # A hook to override that will be called when the job starts iterating.
    # Is called only once, for the first time.
    def on_start
    end

    # A hook to override that will be called when the job resumes iterating.
    def on_resume
    end

    # A hook to override that will be called each time the job is interrupted.
    # This can be due to throttling (throttle enumerator), `max_job_runtime` configuration,
    # or sidekiq restarting.
    def on_shutdown
    end

    # A hook to override that will be called when the job finished iterating.
    def on_complete
    end

    # The enumerator to be iterated over.
    #
    # @return [Enumerator]
    #
    # @raise [NotImplementedError] with a message advising subclasses to
    #     implement an override for this method.
    #
    def build_enumerator(*)
      raise NotImplementedError, "#{self.class.name} must implement a 'build_enumerator' method"
    end

    # The action to be performed on each item from the enumerator.
    #
    # @return [void]
    #
    # @raise [NotImplementedError] with a message advising subclasses to
    #     implement an override for this method.
    #
    def each_iteration(*)
      raise NotImplementedError, "#{self.class.name} must implement an 'each_iteration' method"
    end

    private
      def extract_previous_runs_metadata(arguments)
        options =
          if arguments.last.is_a?(Hash) && arguments.last.key?("sidekiq_iteration")
            arguments.pop["sidekiq_iteration"]
          else
            {}
          end

        @executions = options["executions"] || 0
        @cursor_position = options["cursor_position"]
        @times_interrupted = options["times_interrupted"] || 0
        @total_time = options["total_time"] || 0
      end

      def interruptible_perform(*arguments)
        @executions += 1
        @start_time = Time.now.utc

        enumerator = build_enumerator(*arguments, cursor: cursor_position)
        unless enumerator
          SidekiqIteration.logger.info("[SidekiqIteration::Iteration] `build_enumerator` returned nil. Skipping the job.")
          return
        end

        assert_enumerator!(enumerator)

        if executions == 1 && times_interrupted == 0
          on_start
        else
          on_resume
        end

        completed = catch(:abort) do
          iterate_with_enumerator(enumerator, arguments)
        end

        on_shutdown
        completed = handle_completed(completed)

        if @needs_reenqueue
          reenqueue_iteration_job
        elsif completed
          on_complete
          output_interrupt_summary
        end
      end

      def iterate_with_enumerator(enumerator, arguments)
        found_record = false
        @needs_reenqueue = false

        enumerator.each do |object_from_enumerator, index|
          found_record = true
          each_iteration(object_from_enumerator, *arguments)
          @cursor_position = index
          @current_run_iterations += 1

          throttle_condition = find_throttle_condition
          if throttle_condition
            @job_iteration_retry_backoff = throttle_condition.backoff
            @needs_reenqueue = true
            return false
          end
        end

        unless found_record
          SidekiqIteration.logger.info(
            "[SidekiqIteration::Iteration] Enumerator found nothing to iterate! " \
            "times_interrupted=#{times_interrupted} cursor_position=#{cursor_position}",
          )
        end

        adjust_total_time
        true
      end

      def reenqueue_iteration_job
        SidekiqIteration.logger.info("[SidekiqIteration::Iteration] Interrupting and re-enqueueing the job cursor_position=#{cursor_position}")

        adjust_total_time
        @times_interrupted += 1

        arguments = @arguments
        arguments.push(
          "sidekiq_iteration" => {
            "executions" => executions,
            "cursor_position" => cursor_position,
            "times_interrupted" => times_interrupted,
            "total_time" => total_time,
          },
        )
        self.class.perform_in(@job_iteration_retry_backoff, *arguments)
      end

      def adjust_total_time
        @total_time += (Time.now.utc.to_f - start_time.to_f).round(6)
      end

      def assert_enumerator!(enum)
        return if enum.is_a?(Enumerator)

        raise ArgumentError, <<~MSG
          #build_enumerator is expected to return Enumerator object, but returned #{enum.class}.
          Example:
             def build_enumerator(params, cursor:)
              enumerator_builder.active_record_on_records(
                Shop.find(params[:shop_id]).products,
                cursor: cursor
              )
            end
        MSG
      end

      def output_interrupt_summary
        SidekiqIteration.logger.info(
          format("[SidekiqIteration::Iteration] Completed iterating. times_interrupted=%d total_time=%.3f", times_interrupted, total_time),
        )
      end

      def find_throttle_condition
        self.class.throttle_conditions.find do |throttle_condition|
          throttle_condition.valid?(self)
        end
      end

      def handle_completed(completed)
        case completed
        when nil # someone aborted the job but wants to call the on_complete callback
          true
        when true # rubocop:disable Lint/DuplicateBranch
          true
        when false, :skip_complete_callback
          false
        when Array # can be used to return early from the enumerator
          reason, backoff = completed
          raise "Unknown reason: #{reason}" unless reason == :retry

          @job_iteration_retry_backoff = backoff
          @needs_reenqueue = true
          false
        else
          raise "Unexpected thrown value: #{completed.inspect}"
        end
      end
  end
end
