# Iteration: how it works

The main idea behind Iteration is to provide an API to describe jobs in an interruptible manner, in contrast with implementing one massive `#perform` method that is impossible to interrupt safely.

Exposing the enumerator and the action to apply allows us to keep a cursor and interrupt between iterations. Let's see what this looks like with an `ActiveRecord::Relation` (and `Enumerator`).

```ruby
class NotifyUsers
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

1. `build_enumerator` is called, which constructs `ActiveRecordEnumerator` from an ActiveRecord relation (`User.all`)
2. The first batch of records is loaded:

```sql
SELECT "users".* FROM "users" ORDER BY "users"."id" LIMIT 100
```

3. The job iterates over two records of the relation and then receives `SIGTERM` (graceful termination signal) caused by a deploy.
4. The signal handler sets a flag that makes `job_should_exit?` return `true`.
5. After the last iteration is completed, we will check `job_should_exit?` which now returns `true`.
6. The job stops iterating and pushes itself back to the queue, with the latest `cursor_position` value.
7. Next time when the job is taken from the queue, we'll load records starting from the last primary key that was processed:

```sql
SELECT "users".* FROM "users" WHERE "users"."id" > 2 ORDER BY "products"."id" LIMIT 100
```

## Signals

It's critical to know [UNIX signals](https://www.tutorialspoint.com/unix/unix-signals-traps.htm) in order to understand how interruption works. There are two main signals that Sidekiq use: `SIGTERM` and `SIGKILL`. `SIGTERM` is the graceful termination signal which means that the process should exit _soon_, not immediately. For Iteration, it means that we have time to wait for the last iteration to finish and to push job back to the queue with the last cursor position.
`SIGTERM` is what allows Iteration to work. In contrast, `SIGKILL` means immediate exit. It doesn't let the worker terminate gracefully, instead it will drop the job and exit as soon as possible.

Most of the deploy strategies (Heroku, Capistrano) send `SIGTERM` before shutting down a node, then wait for a timeout (usually from 30 seconds to a minute) to send `SIGKILL` if the process has not terminated yet.

Further reading: [Sidekiq signals](https://github.com/mperham/sidekiq/wiki/Signals).

## Enumerators

Iteration supports _any_ `Enumerator`. We expose helpers to build enumerators conveniently (`active_record_records_enumerator`), but it's up for a developer to implement a custom `Enumerator`.

Consider this example:

```ruby
class MyJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(cursor:)
    Enumerator.new do
      Redis.lpop("mylist") # or: Kafka.poll(timeout: 10.seconds)
    end
  end

  def each_iteration(element_from_redis)
    # ...
  end
end
```

Further reading: [ruby-doc](https://ruby-doc.org/core-3.1.2/Enumerator.html), [a great post about Enumerators](http://blog.arkency.com/2014/01/ruby-to-enum-for-enumerator/).
