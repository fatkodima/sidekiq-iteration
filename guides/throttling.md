# Throttling

The gem provides a throttling mechanism that can be used to throttle a job when a given condition is met.
If a job is throttled, it will be interrupted and retried after a backoff period has passed.
The default backoff is 30 seconds.

Specify the throttle condition as a block:

```ruby
class DeleteAccountsThrottledJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  throttle_on(backoff: 1.minute) do
    DatabaseStatus.unhealthy?
  end

  def build_enumerator(cursor:)
    active_record_relations_enumerator(Account.inactive, cursor: cursor)
  end

  def each_iteration(accounts)
    accounts.delete_all
  end
end
```

Note that it's up to you to define a throttling condition that makes sense for your app.
For example, `DatabaseStatus.healthy?` can check various MySQL metrics such as replication lag, DB threads, whether DB writes are available, etc.

Jobs can define multiple throttle conditions. Throttle conditions are inherited by descendants, and new conditions will be appended without impacting existing conditions.

The backoff can also be specified as a Proc:

```ruby
class DeleteAccountsThrottledJob
  throttle_on(backoff: -> { RandomBackoffGenerator.generate_duration } ) do
    DatabaseStatus.unhealthy?
  end
  # ...
end
```
