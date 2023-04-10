# Argument Semantics

`sidekiq-iteration` defines the `perform` method, required by `sidekiq`, to allow for iteration.

The call sequence is usually 3 methods:

`perform -> build_enumerator -> each_iteration`

In that sense `sidekiq-iteration` works like a framework (it calls your code) rather than like a library (that you call). When using jobs with parameters, the following rules of thumb are good to keep in mind.

## Jobs without arguments

Jobs without arguments do not pass anything into either `build_enumerator` or `each_iteration` except for the `cursor` which `sidekiq-iteration` persists by itself:

```ruby
class ArglessJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(cursor:)
    # ...
  end

  def each_iteration(single_object_yielded_from_enumerator)
    # ...
  end
end
```

To enqueue the job:

```ruby
ArglessJob.perform_async
```

## Jobs with positional arguments

Jobs with positional arguments will have those arguments available to both `build_enumerator` and `each_iteration`:

```ruby
class ArgumentativeJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(arg1, arg2, arg3, cursor:)
    # ...
  end

  def each_iteration(single_object_yielded_from_enumerator, arg1, arg2, arg3)
    # ...
  end
end
```

To enqueue the job:

```ruby
ArgumentativeJob.perform_async(_arg1 = "One", _arg2 = "Two", _arg3 = "Three")
```

## Jobs with keyword arguments

Jobs with keyword arguments will have the keyword arguments available to both `build_enumerator` and `each_iteration`, but these arguments come packaged into a Hash in both cases. You will need to `fetch` or `[]` your parameter from the `Hash` you get passed in:

```ruby
class ParameterizedJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(kwargs, cursor:)
    name = kwargs.fetch("name")
    email = kwargs.fetch("email")
    # ...
  end

  def each_iteration(object_yielded_from_enumerator, kwargs)
    name = kwargs.fetch("name")
    email = kwargs.fetch("email")
    # ...
  end
end
```

To enqueue the job:

```ruby
ParameterizedJob.perform_async("name" => "Jane", "email" => "jane@host.example")
```

## Jobs with both positional and keyword arguments

Jobs with keyword arguments will have the keyword arguments available to both `build_enumerator` and `each_iteration`, but these arguments come packaged into a Hash in both cases. You will need to `fetch` or `[]` your parameter from the `Hash` you get passed in. Positional arguments get passed first and "unsplatted" (not combined into an array), the `Hash` containing keyword arguments comes after:

```ruby
class HighlyConfigurableGreetingJob
  include Sidekiq::Job
  include SidekiqIteration::Iteration

  def build_enumerator(subject_line, kwargs, cursor:)
    name = kwargs.fetch("sender_name")
    email = kwargs.fetch("sender_email")
    # ...
  end

  def each_iteration(object_yielded_from_enumerator, subject_line, kwargs)
    name = kwargs.fetch("sender_name")
    email = kwargs.fetch("sender_email")
    # ...
  end
end
```

To enqueue the job:

```ruby
HighlyConfigurableGreetingJob.perform_async(_subject_line = "Greetings everybody!", "sender_name" => "Jane", "sender_email" => "jane@host.example")
```

## Returning (yielding) from enumerators

When defining a custom enumerator (see the [custom enumerator guide](custom-enumerator.md)) you need to yield two positional arguments from it: the object that will be the value for the current iteration (like a single ActiveModel instance, a single number...) and the value you want to be persisted as the `cursor` value should `sidekiq-iteration` decide to interrupt you after this iteration. Calling the enumerator with that cursor should return the next object after the one returned in this iteration. That new `cursor` value does not get passed to `each_iteration`:

```ruby
Enumerator.new do |yielder|
  # In this case `cursor` is an Integer
  cursor.upto(99999) do |offset|
    yielder.yield(fetch_record_at(offset), offset)
  end
end
```
