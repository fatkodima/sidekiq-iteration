# Custom Enumerator

Iteration leverages the [`Enumerator`](https://ruby-doc.org/core-3.1.2/Enumerator.html) pattern from the Ruby standard library, which allows us to use almost any resource as a collection to iterate.

## Cursorless Enumerator

Consider a custom Enumerator that takes items from a Redis list. Because a Redis list is essentially a queue, we can ignore the cursor:

```ruby
class ListJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(*)
    @redis = Redis.new
    Enumerator.new do |yielder|
      loop do
        item = @redis.lpop(key)
        break unless item

        yielder.yield(item, nil)
      end
    end
  end

  def each_iteration(item)
    # ...
  end
end
```

## Enumerator with cursor

But what about iterating based on a cursor? Consider this Enumerator that wraps third party API (Stripe) for paginated iteration:

```ruby
class StripeListEnumerator
  # @param resource [Stripe::APIResource] The type of Stripe object to request
  # @param params [Hash] Query parameters for the request
  # @param options [Hash] Request options, such as API key or version
  # @param cursor [String]
  def initialize(resource, params: {}, options: {}, cursor:)
    pagination_params = {}
    pagination_params[:starting_after] = cursor unless cursor.nil?

    # The following line makes a request, consider adding your rate limiter here.
    @list = resource.public_send(:list, params.merge(pagination_params), options)
  end

  def to_enumerator
    to_enum(:each).lazy
  end

  private

  # We yield our enumerator with the object id as the index so it is persisted
  # as the cursor on the job. This allows us to properly set the
  # `starting_after` parameter for the API request when resuming.
  def each
    loop do
      @list.each do |item, _index|
        yield item, item.id
      end

      # The following line makes a request, consider adding your rate limiter here.
      @list = @list.next_page

      break if @list.empty?
    end
  end
end
```

```ruby
class StripeJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(params, cursor:)
    StripeListEnumerator.new(
      Stripe::Refund,
      params: { charge: "ch_123" },
      options: { api_key: "sk_test_123", stripe_version: "2018-01-18" },
      cursor: cursor
    ).to_enumerator
  end

  def each_iteration(stripe_refund, _params)
    # ...
  end
end
```

## Notes

We recommend that you read the implementation of the other enumerators that come with the library (`CsvEnumerator`, `ActiveRecordEnumerator`) to gain a better understanding of building Enumerator objects.

Code that is written after the `yield` in a custom enumerator is not guaranteed to execute. In the case that a job is forced to exit (`max_job_runtime` is reached or sidekiq is topping), then the job is re-enqueued during the yield and the rest of the code in the enumerator does not run.
