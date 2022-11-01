# Sidekiq Iteration

Meet Iteration, an extension for [Sidekiq](https://github.com/mperham/sidekiq) that makes your jobs interruptible and resumable, saving all progress that the job has made (aka checkpoint for jobs).

## Background

Imagine the following job:

```ruby
class SimpleJob
  include Sidekiq::Job

  def perform
    User.find_each do |user|
      user.notify_about_something
    end
  end
end
```

The job would run fairly quickly when you only have a hundred `User` records. But as the number of records grows, it will take longer for a job to iterate over all Users. Eventually, there will be millions of records to iterate and the job will end up taking hours or even days.

With frequent deploys and worker restarts, it would mean that a job will be either lost or restarted from the beginning. Some records (especially those in the beginning of the relation) will be processed more than once.

Cloud environments are also unpredictable, and there's no way to guarantee that a single job will have reserved hardware to run for hours and days. What if AWS diagnosed the instance as unhealthy and will restart it in 5 minutes? All job progress will be lost.

Software that is designed for high availability [must be resilient](https://12factor.net/disposability) to interruptions that come from the infrastructure. That's exactly what Iteration brings to Sidekiq.

## Getting started

Add this line to your application's Gemfile:

```ruby
gem 'sidekiq-iteration'
```

And then execute:

    $ bundle

In the job, include `SidekiqIteration::Iteration` module and start describing the job with two methods (`build_enumerator` and `each_iteration`) instead of `perform`:

```ruby
class NotifyUsersJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(cursor:)
    active_record_records_enumerator(User.all, cursor: cursor)
  end

  def each_iteration(user)
    user.notify_about_something
  end
end
```

`each_iteration` will be called for each `User` model in `User.all` relation. The relation will be ordered by primary key, exactly like `find_each` does.
Iteration hooks into Sidekiq out of the box to support graceful interruption. No extra configuration is required.

## Examples

### Job with custom arguments

```ruby
class ArgumentsJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(arg1, arg2, cursor:)
    active_record_records_enumerator(User.all, cursor: cursor)
  end

  def each_iteration(user, arg1, arg2)
    user.notify_about_something
  end
end

ArgumentsJob.perform_async(arg1, arg2)
```

### Job with custom lifecycle callbacks

```ruby
class NotifyUsersJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def on_start
    # Will be called when the job starts iterating. Called only once, for the first time.
  end

  def on_resume
    # Called when the job resumes iterating.
  end

  def on_shutdown
    # Called each time the job is interrupted.
    # This can be due to throttling, `max_job_runtime` configuration, or sidekiq restarting.
  end

  def on_complete
    # Called when the job finished iterating.
  end

  # ...
end
```

### Iterating over batches of Active Record objects

```ruby
class BatchesJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(product_id, cursor:)
    active_record_batches_enumerator(
      Comment.where(product_id: product_id).select(:id),
      cursor: cursor,
      batch_size: 100,
    )
  end

  def each_iteration(batch_of_comments, product_id)
    comment_ids = batch_of_comments.map(&:id)
    CommentService.call(comment_ids: comment_ids)
  end
end
```

### Iterating over batches of Active Record Relations

```ruby
class BatchesAsRelationJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(product_id, cursor:)
    active_record_relations_enumerator(
      Product.find(product_id).comments,
      cursor: cursor,
      batch_size: 100,
    )
  end

  def each_iteration(batch_of_comments, product_id)
    # batch_of_comments will be a Comment::ActiveRecord_Relation
    batch_of_comments.update_all(deleted: true)
  end
end
```

### Iterating over arrays

```ruby
class ArrayJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(cursor:)
    array_enumerator(['build', 'enumerator', 'from', 'any', 'array'], cursor: cursor)
  end

  def each_iteration(array_element)
    # use array_element
  end
end
```

### Iterating over CSV

```ruby
class CsvJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(import_id, cursor:)
    import = Import.find(import_id)
    csv_enumereator(import.csv, cursor: cursor)
  end

  def each_iteration(csv_row)
    # insert csv_row to database
  end
end
```

### Nested iteration

```ruby
class NestedIterationJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(cursor:)
    nested_enumerator(
      [
        ->(cursor) { active_record_records_enumerator(Shop.all, cursor: cursor) },
        ->(shop, cursor) { active_record_records_enumerator(shop.products, cursor: cursor) },
        ->(_shop, product, cursor) { active_record_relations_enumerator(product.product_variants, cursor: cursor) }
      ],
      cursor: cursor
    )
  end

  def each_iteration(product_variants_relation)
    # do something
  end
end
```

## Guides

* [Iteration: how it works](guides/iteration-how-it-works.md)
* [Best practices](guides/best-practices.md)
* [Writing custom enumerator](guides/custom-enumerator.md)
* [Throttling](guides/throttling.md)

For more detailed documentation, see [rubydoc](https://rubydoc.info/gems/sidekiq-iteration).

## API

Iteration job must respond to `build_enumerator` and `each_iteration` methods. `build_enumerator` must return [`Enumerator`](https://ruby-doc.org/core-3.1.2/Enumerator.htmll) object that respects the `cursor` value.

## FAQ

**Why can't I just iterate in `#perform` method and do whatever I want?** You can, but then your job has to comply with a long list of requirements, such as the ones above. This creates leaky abstractions more easily, when instead we can expose a more powerful abstraction for developers without exposing the underlying infrastructure.

**What happens when my job is interrupted?** A checkpoint will be persisted to Redis after the current `each_iteration`, and the job will be re-enqueued. Once it's popped off the queue, the worker will work off from the next iteration.

**What happens with retries?** An interruption of a job does not count as a retry. The iteration of job that caused the job to fail will be retried and progress will continue from there on.

**What happens if my iteration takes a long time?** We recommend that a single `each_iteration` should take no longer than 30 seconds. In the future, this may raise an exception.

**Why is it important that `each_iteration` takes less than 30 seconds?** When the job worker is scheduled for restart or shutdown, it gets a notice to finish remaining unit of work. To guarantee that no progress is lost we need to make sure that `each_iteration` completes within a reasonable amount of time.

**What do I do if each iteration takes a long time, because it's doing nested operations?** If your `each_iteration` is complex, we recommend enqueuing another job, which will run your nested business logic. If `each_iteration` performs some other iterations, like iterating over child records, consider using [nested iterations](#nested-iteration).

**My job has a complex flow. How do I write my own Enumerator?** See [the guide on Custom Enumerators](guides/custom-enumerator.md) for details.

## Credits

Thanks to [`job-iteration` gem](https://github.com/Shopify/job-iteration) for the original implementation and inspiration.

## Development

After checking out the repo, run `bundle install` to install dependencies and start Redis. Run `bundle exec rake` to run the linter and tests. This project uses multiple Gemfiles to test against multiple versions of Sidekiq; you can run the tests against the specific version with `BUNDLE_GEMFILE=gemfiles/sidekiq_6.gemfile bundle exec rake test`.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/fatkodima/sidekiq-iteration.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
