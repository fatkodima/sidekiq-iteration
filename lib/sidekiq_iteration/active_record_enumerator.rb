# frozen_string_literal: true

module SidekiqIteration
  # @private
  class ActiveRecordEnumerator
    SQL_DATETIME_WITH_NSEC = "%Y-%m-%d %H:%M:%S.%6N"

    def initialize(relation, columns: nil, batch_size: 100, order: :asc, cursor: nil)
      unless relation.is_a?(ActiveRecord::Relation)
        raise ArgumentError, "relation must be an ActiveRecord::Relation"
      end

      if relation.arel.orders.present? || relation.arel.taken.present?
        raise ArgumentError,
          "The relation cannot use ORDER BY or LIMIT due to the way how iteration with a cursor is designed. " \
          "You can use other ways to limit the number of rows, e.g. a WHERE condition on the primary key column."
      end

      @relation = relation
      @primary_key = relation.primary_key
      columns = Array(columns || @primary_key).map(&:to_s)

      if (Array(order) - [:asc, :desc]).any?
        raise ArgumentError, ":order must be :asc or :desc or an array consisting of :asc or :desc, got #{order.inspect}"
      end

      if order.is_a?(Array) && order.size != columns.size
        raise ArgumentError, ":order must include a direction for each batching column"
      end

      @primary_key_index = primary_key_index(columns, relation)
      if @primary_key_index.nil? || (composite_primary_key? && @primary_key_index.any?(nil))
        raise ArgumentError, ":columns must include a primary key columns"
      end

      @batch_size = batch_size
      @order = batch_order(columns, order)
      @cursor = Array(cursor)

      if @cursor.present? && @cursor.size != columns.size
        raise ArgumentError, ":cursor must include values for all the columns from :columns"
      end

      if columns.any?(/\W/)
        arel_columns = columns.map.with_index do |column, i|
          arel_column(column).as("cursor_column_#{i + 1}")
        end
        @cursor_columns = arel_columns.map { |column| column.right.to_s }

        relation =
          if relation.select_values.empty?
            relation.select(@relation.arel_table[Arel.star], arel_columns)
          else
            relation.select(arel_columns)
          end
      else
        @cursor_columns = columns
      end

      @columns = columns
      ordering = @columns.zip(@order).to_h
      @base_relation = relation.reorder(ordering)
      @iteration_count = 0
    end

    def records
      Enumerator.new(-> { records_size }) do |yielder|
        batches.each do |batch, _| # rubocop:disable Style/HashEachMethods
          batch.each do |record|
            increment_iteration
            yielder.yield(record, cursor_value(record))
          end
        end
      end
    end

    def batches
      Enumerator.new(-> { records_size }) do |yielder|
        while (batch = next_batch(load: true))
          increment_iteration
          yielder.yield(batch, cursor_value(batch.first))
        end
      end
    end

    def relations
      Enumerator.new(-> { relations_size }) do |yielder|
        while (batch = next_batch(load: false))
          increment_iteration
          yielder.yield(batch, unwrap_array(@cursor))
        end
      end
    end

    private
      def primary_key_index(columns, relation)
        indexes = Array(@primary_key).map do |pk_column|
          columns.index do |column|
            column == pk_column ||
              (column.include?(relation.table_name) && column.include?(pk_column))
          end
        end

        if composite_primary_key?
          indexes
        else
          indexes.first
        end
      end

      def batch_order(columns, order)
        if order.is_a?(Array)
          order
        else
          [order] * columns.size
        end
      end

      def arel_column(column)
        if column.include?(".")
          Arel.sql(column)
        else
          @relation.arel_table[column]
        end
      end

      def records_size
        @base_relation.count(:all)
      end

      def relations_size
        (records_size + @batch_size - 1) / @batch_size # ceiling division
      end

      def next_batch(load:)
        batch_relation = @base_relation.limit(@batch_size)
        if @cursor.present?
          batch_relation = apply_cursor(batch_relation)
        end

        records = nil
        cursor_values, ids = batch_relation.uncached do
          if load
            records = batch_relation.records
            pluck_columns(records)
          else
            pluck_columns(batch_relation)
          end
        end

        cursor = cursor_values.last
        return unless cursor.present?

        @cursor = Array(cursor)

        # Yields relations by selecting the primary keys of records in the batch.
        # Post.where(published: nil) results in an enumerator of relations like:
        # Post.where(published: nil, ids: batch_of_ids)
        relation = @base_relation.where(@primary_key => ids)
        relation.send(:load_records, records) if load
        relation
      end

      def pluck_columns(batch)
        if @cursor_columns.size == 1 # only the primary key
          column_values = batch.pluck(@cursor_columns.first)
          return [column_values, column_values]
        end

        column_values = batch.pluck(*@cursor_columns)
        primary_key_values =
          if composite_primary_key?
            column_values.map { |values| values.values_at(*@primary_key_index) }
          else
            column_values.map { |values| values[@primary_key_index] }
          end

        column_values = serialize_column_values(column_values)
        [column_values, primary_key_values]
      end

      def cursor_value(record)
        positions = @cursor_columns.map do |column|
          column_value(record[column])
        end

        unwrap_array(positions)
      end

      # (x, y) >= (a, b) iff (x > a or (x = a and y >= b))
      # (x, y) <= (a, b) iff (x < a or (x = a and y <= b))
      def apply_cursor(relation)
        arel_columns = @columns.map { |column| arel_column(column) }
        cursor_positions = arel_columns.zip(@cursor, cursor_operators)

        where_clause = nil
        cursor_positions.reverse_each.with_index do |(arel_column, value, operator), index|
          where_clause =
            if index == 0
              arel_column.public_send(operator, value)
            else
              arel_column.public_send(operator, value).or(
                arel_column.eq(value).and(where_clause),
              )
            end
        end

        relation.where(where_clause)
      end

      def serialize_column_values(column_values)
        column_values.map { |values| values.map { |value| column_value(value) } }
      end

      def column_value(value)
        if value.is_a?(Time)
          value.strftime(SQL_DATETIME_WITH_NSEC)
        else
          value
        end
      end

      def cursor_operators
        # Start from the record pointed by cursor when just starting.
        @columns.zip(@order).map do |column, order|
          if column == @columns.last
            if order == :asc
              first_iteration? ? :gteq : :gt
            else
              first_iteration? ? :lteq : :lt
            end
          else
            order == :asc ? :gt : :lt
          end
        end
      end

      def increment_iteration
        @iteration_count += 1
      end

      def first_iteration?
        @iteration_count == 0
      end

      def composite_primary_key?
        @primary_key.is_a?(Array)
      end

      def unwrap_array(array)
        if array.size == 1
          array.first
        else
          array
        end
      end
  end
end
