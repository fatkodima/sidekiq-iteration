## master (unreleased)

- Enforce explicitly passed to ActiveRecord enumerators `:columns` value to include a primary key

    Previously, the primary key column was added implicitly if it was not in the list.

    ```ruby
    # before
    active_record_records_enumerator(..., columns: [:updated_at])

    # after
    active_record_records_enumerator(..., columns: [:updated_at, :id])
    ```

- Accept single values as a `:columns` for ActiveRecord enumerators
- Add `around_iteration` hook

## 0.3.0 (2023-05-20)

- Allow a default retry backoff to be configured

    ```ruby
    SidekiqIteration.default_retry_backoff = 10.seconds
    ```

- Add ability to iterate Active Record enumerators in reverse order

    ```ruby
    active_record_records_enumerator(User.all, order: :desc)
    ```

## 0.2.0 (2022-11-11)

- Fix storing run metadata when the job fails for sidekiq < 6.5.2

- Make enumerators resume from the last cursor position

  This fixes `NestedEnumerator` to work correctly. Previously, each intermediate enumerator
  was resumed from the next cursor position, possibly skipping remaining inner items.

## 0.1.0 (2022-11-02)

- First release
