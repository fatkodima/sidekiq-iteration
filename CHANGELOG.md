## master (unreleased)

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
