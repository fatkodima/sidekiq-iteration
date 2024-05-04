# Best practices

## Considerations when writing jobs

* Duration of `#each_iteration`: processing a single element from the enumerator built in `#build_enumerator` should take less than 25 seconds, or the duration set as a timeout for Sidekiq. It allows the job to be safely interrupted and resumed.
* Idempotency of `#each_iteration`: it should be safe to run `#each_iteration` multiple times for the same element from the enumerator. Read more in [this Sidekiq best practice](https://github.com/mperham/sidekiq/wiki/Best-Practices#2-make-your-job-idempotent-and-transactional). It's important if the job errors and you run it again, because the same element that errored the job may be processed again. It especially matters in the situation described above, when the iteration duration exceeds the timeout: if the job is re-enqueued, multiple elements may be processed again.

## Batch iteration

Regardless of the active record enumerator used in the task, `sidekiq-iteration` gem loads records in batches of 100 (by default).
The following two tasks produce equivalent database queries, however `RecordsJob` task allows for more frequent interruptions by doing just one thing in the `each_iteration` method.

```ruby
# bad
class BatchesJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(product_id, cursor:)
    active_record_batches_enumerator(
      Comment.where(product_id: product_id),
      cursor: cursor,
      batch_size: 5,
    )
  end

  def each_iteration(batch_of_comments, product_id)
    batch_of_comments.each(&:destroy)
  end
end

# good
class RecordsJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(product_id, cursor:)
    active_record_records_enumerator(
      Comment.where(product_id: product_id),
      cursor: cursor,
      batch_size: 5,
    )
  end

  def each_iteration(comment, product_id)
    comment.destroy
  end
end
```

## Max job runtime

If a job is supposed to have millions of iterations and you expect it to run for hours and days, it's still a good idea to sometimes interrupt the job even if there are no interruption signals coming from deploys or the infrastructure.

```ruby
SidekiqIteration.max_job_runtime = 5.minutes # nil by default
```

Use this accessor to tweak how often you'd like the job to interrupt itself.

### Per job max job runtime

For more granular control, `max_job_runtime` can be set **per-job class**. This allows both incremental adoption, as well as using a conservative global setting, and an aggressive setting on a per-job basis.

```ruby
class MyJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  self.max_job_runtime = 3.minutes

  # ...
end
```

This setting will be inherited by any child classes, although it can be further overridden.
