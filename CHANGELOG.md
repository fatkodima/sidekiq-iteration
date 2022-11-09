## master (unreleased)

- Fix storing run metadata when the job fails for sidekiq < 6.5.2

- Make enumerators resume from the last cursor position

  This fixes `NestedEnumerator` to work correctly. Previously, each intermediate enumerator
  was resumed from the next cursor position, possibly skipping remaining inner items.

## 0.1.0 (2022-11-02)

- First release
