# frozen_string_literal: true

require_relative "active_record_enumerator"
require_relative "active_record_batch_enumerator"
require_relative "csv_enumerator"
require_relative "nested_enumerator"

module SidekiqIteration
  module Enumerators
    # Builds Enumerator object from a given array, using +cursor+ as an offset.
    #
    # @param array [Array]
    # @param cursor [Integer] offset to start iteration from
    #
    # @example
    #   array_enumerator(['build', 'enumerator', 'from', 'any', 'array'], cursor: cursor)
    #
    def array_enumerator(array, cursor:)
      raise ArgumentError, "array must be an Array" unless array.is_a?(Array)

      if defined?(ActiveRecord) && array.any?(ActiveRecord::Base)
        raise ArgumentError, "array cannot contain ActiveRecord objects"
      end

      drop = cursor ? cursor + 1 : 0
      array.each_with_index.drop(drop).to_enum { array.size }
    end

    # Builds Enumerator from Active Record Relation. Each Enumerator tick moves the cursor one row forward.
    #
    # @param scope [ActiveRecord::Relation] scope to iterate
    # @param cursor [Object] offset to start iteration from, usually an id
    # @option options :columns [Array<String, Symbol>] used to build the actual query for iteration,
    #   defaults to primary key
    # @option options :batch_size [Integer] (100) size of the batch
    #
    # +columns:+ argument is used to build the actual query for iteration. +columns+: defaults to primary key:
    #
    #   1) SELECT * FROM users ORDER BY id LIMIT 100
    #
    # When iteration is resumed, +cursor:+ and +columns:+ values will be used to continue from the point
    # where iteration stopped:
    #
    #   2) SELECT * FROM users WHERE id > $CURSOR ORDER BY id LIMIT 100
    #
    # +columns:+ can also take more than one column. In that case, +cursor+ will contain serialized values
    # of all columns at the point where iteration stopped.
    #
    # Consider this example with +columns: [:created_at, :id]+. Here's the query will use on the first iteration:
    #
    #   1) SELECT * FROM "products" ORDER BY created_at, id LIMIT 100
    #
    # And the query on the next iteration:
    #
    #   2) SELECT * FROM "products"
    #        WHERE (created_at > '$LAST_CREATED_AT_CURSOR'
    #          OR (created_at = '$LAST_CREATED_AT_CURSOR' AND (id > '$LAST_ID_CURSOR')))
    #        ORDER BY created_at, id LIMIT 100
    #
    # As a result of this query pattern, if the values in these columns change for the records in scope during
    # iteration, they may be skipped or yielded multiple times depending on the nature of the update and the
    # cursor's value. If the value gets updated to a greater value than the cursor's value, it will get yielded
    # again. Similarly, if the value gets updated to a lesser value than the curor's value, it will get skipped.
    #
    # @example
    #   def build_enumerator(cursor:)
    #     active_record_records_enumerator(User.all, cursor: cursor)
    #   end
    #
    #   def each_iteration(user)
    #     user.notify_about_something
    #   end
    #
    def active_record_records_enumerator(scope, cursor:, **options)
      ActiveRecordEnumerator.new(scope, cursor: cursor, **options).records
    end

    # Builds Enumerator from Active Record Relation and enumerates on batches of records.
    # Each Enumerator tick moves the cursor +batch_size+ rows forward.
    # @see #active_record_records_enumerator
    #
    # @example
    #   def build_enumerator(product_id, cursor:)
    #     active_record_batches_enumerator(
    #       Comment.where(product_id: product_id).select(:id),
    #       cursor: cursor,
    #       batch_size: 100
    #     )
    #   end
    #
    #   def each_iteration(batch_of_comments, product_id)
    #     comment_ids = batch_of_comments.map(&:id)
    #     CommentService.call(comment_ids: comment_ids)
    #   end
    #
    def active_record_batches_enumerator(scope, cursor:, **options)
      ActiveRecordEnumerator.new(scope, cursor: cursor, **options).batches
    end

    # Builds Enumerator from Active Record Relation and enumerates on batches, yielding Active Record Relations.
    # @see #active_record_records_enumerator
    #
    # @example
    #   def build_enumerator(product_id, cursor:)
    #     active_record_relations_enumerator(
    #       Product.find(product_id).comments,
    #       cursor: cursor,
    #       batch_size: 100,
    #     )
    #   end
    #
    #   def each_iteration(batch_of_comments, product_id)
    #     # batch_of_comments will be a Comment::ActiveRecord_Relation
    #     batch_of_comments.update_all(deleted: true)
    #   end
    #
    def active_record_relations_enumerator(scope, cursor:, **options)
      ActiveRecordBatchEnumerator.new(scope, cursor: cursor, **options).each
    end

    # Builds Enumerator from a CSV file.
    #
    # @param csv [CSV] an instance of CSV object
    # @param cursor [Integer] offset to start iteration from
    #
    # @example
    #   def build_enumerator(import_id, cursor:)
    #     import = Import.find(import_id)
    #     csv_enumerator(import.csv, cursor: cursor)
    #   end
    #
    #   def each_iteration(csv_row)
    #     # insert csv_row to database
    #   end
    #
    def csv_enumerator(csv, cursor:)
      CsvEnumerator.new(csv).rows(cursor: cursor)
    end

    # Builds Enumerator from a CSV file and enumerates on batches of records.
    #
    # @param csv [CSV] an instance of CSV object
    # @param cursor [Integer] offset to start iteration from
    # @option options :batch_size [Integer] (100) size of the batch
    #
    # @example
    #   def build_enumerator(import_id, cursor:)
    #     import = Import.find(import_id)
    #     csv_batches_enumerator(import.csv, cursor: cursor)
    #   end
    #
    #   def each_iteration(batch_of_csv_rows)
    #     # ...
    #   end
    #
    def csv_batches_enumerator(csv, cursor:, **options)
      CsvEnumerator.new(csv).batches(cursor: cursor, **options)
    end

    # Builds Enumerator for nested iteration.
    #
    # @param enums [Array<Proc>] an Array of Procs, each should return an Enumerator.
    #   Each proc from enums should accept the yielded items from the parent enumerators and the `cursor` as its arguments.
    #   Each proc's `cursor` argument is its part from the `build_enumerator`'s `cursor` array.
    # @param cursor [Array<Object>] array of offsets for each of the enums to start iteration from
    #
    # @example
    #   def build_enumerator(cursor:)
    #     nested_enumerator(
    #       [
    #         ->(cursor) { active_record_records_enumerator(Shop.all, cursor: cursor) },
    #         ->(shop, cursor) { active_record_records_enumerator(shop.products, cursor: cursor) },
    #         ->(_shop, product, cursor) { active_record_relations_enumerator(product.product_variants, cursor: cursor) }
    #       ],
    #       cursor: cursor
    #     )
    #   end
    #
    #   def each_iteration(product_variants_relation)
    #     # do something
    #   end
    #
    def nested_enumerator(enums, cursor:)
      NestedEnumerator.new(enums, cursor: cursor).each
    end
  end
end
