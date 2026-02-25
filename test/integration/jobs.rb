# frozen_string_literal: true

class IterationJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(cursor:)
    array_enumerator([0, 1, 2, 3], cursor: cursor)
  end

  def each_iteration(num)
    stop_after_num = Sidekiq.redis do |conn|
      conn.get("stop_after_num")
    end

    if stop_after_num && num == stop_after_num.to_i
      Process.kill("TERM", Process.pid)
    end
    sleep(0.01)
  end
end

class FailingIterationJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  sidekiq_options retry: 3
  sidekiq_retry_in { 0 }

  def on_start
    Sidekiq.redis do |conn|
      conn.incr("on_start_called")
    end
  end

  def on_complete
    Sidekiq.redis do |conn|
      conn.incr("on_complete_called")
    end
  end

  def build_enumerator(cursor:)
    array_enumerator(10.times.to_a, cursor: cursor)
  end

  def each_iteration(num)
    @called ||= 0
    if @called > 2
      Process.kill("TERM", Process.pid)
      raise
    end

    Sidekiq.redis do |conn|
      conn.rpush("records_performed", num)
    end
    @called += 1
  end
end

class FailingJob
  include Sidekiq::Job

  def perform
    Process.kill("TERM", Process.pid)
    raise
  end
end

class TerminateJob
  include Sidekiq::Job

  def perform
    Process.kill("TERM", Process.pid)
  end
end
