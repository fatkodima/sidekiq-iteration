# frozen_string_literal: true

module SidekiqIteration
  # @private
  class ActiveRecordEnumerator
    SQL_DATETIME_WITH_NSEC = "%Y-%m-%d %H:%M:%S.%N"

    def initialize(relation, columns: nil, batch_size: 100, cursor: nil)
      unless relation.is_a?(ActiveRecord::Relation)
        raise ArgumentError, "relation must be an ActiveRecord::Relation"
      end

      @primary_key = "#{relation.table_name}.#{relation.primary_key}"
      @columns = Array(columns&.map(&:to_s) || @primary_key)
      @primary_key_index = @columns.index(@primary_key) || @columns.index(relation.primary_key)
      @pluck_columns = if @primary_key_index
                         @columns
                       else
                         @columns + [@primary_key]
                       end
      @batch_size = batch_size
      @cursor = Array.wrap(cursor)
      raise ArgumentError, "Must specify at least one column" if @columns.empty?
      if relation.joins_values.present? && !@columns.all?(/\./)
        raise ArgumentError, "You need to specify fully-qualified columns if you join a table"
      end

      if relation.arel.orders.present? || relation.arel.taken.present?
        raise ArgumentError,
          "The relation cannot use ORDER BY or LIMIT due to the way how iteration with a cursor is designed. " \
          "You can use other ways to limit the number of rows, e.g. a WHERE condition on the primary key column."
      end

      @base_relation = relation.reorder(@columns.join(", "))
    end

    def records
      Enumerator.new(-> { records_size }) do |yielder|
        batches.each do |batch, _|
          batch.each do |record|
            yielder.yield(record, cursor_value(record))
          end
        end
      end
    end

    def batches
      Enumerator.new(-> { records_size }) do |yielder|
        while (batch = next_batch(load: true))
          yielder.yield(batch, cursor_value(batch.last))
        end
      end
    end

    def relations
      Enumerator.new(-> { relations_size }) do |yielder|
        while (batch = next_batch(load: false))
          yielder.yield(batch, unwrap_array(@cursor))
        end
      end
    end

    private
      def records_size
        @base_relation.count(:all)
      end

      def relations_size
        (records_size + @batch_size - 1) / @batch_size # ceiling division
      end

      def next_batch(load:)
        batch_relation = @base_relation.limit(@batch_size)
        if conditions.any?
          batch_relation = batch_relation.where(*conditions)
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

        # The primary key was plucked, but original cursor did not include it, so we should remove it
        cursor.pop unless @primary_key_index
        @cursor = Array.wrap(cursor)

        # Yields relations by selecting the primary keys of records in the batch.
        # Post.where(published: nil) results in an enumerator of relations like:
        # Post.where(published: nil, ids: batch_of_ids)
        relation = @base_relation.where(@primary_key => ids)
        relation.send(:load_records, records) if load
        relation
      end

      def pluck_columns(batch)
        columns =
          if batch.is_a?(Array)
            @pluck_columns.map { |column| column.to_s.split(".").last }
          else
            @pluck_columns
          end

        if columns.size == 1 # only the primary key
          column_values = batch.pluck(columns.first)
          return [column_values, column_values]
        end

        column_values = batch.pluck(*columns)
        primary_key_index = @primary_key_index || -1
        primary_key_values = column_values.map { |values| values[primary_key_index] }

        serialize_column_values!(column_values)
        [column_values, primary_key_values]
      end

      def cursor_value(record)
        positions = @columns.map do |column|
          attribute_name = column.to_s.split(".").last
          column_value(record[attribute_name])
        end

        unwrap_array(positions)
      end

      def conditions
        return [] if @cursor.empty?

        binds = []
        sql = build_starts_after_conditions(0, binds)
        [sql, *binds]
      end

      # (x, y) > (a, b) iff (x > a or (x = a and y > b))
      def build_starts_after_conditions(index, binds)
        column = @columns[index]

        if index < @cursor.size - 1
          binds << @cursor[index] << @cursor[index]
          "#{column} > ? OR (#{column} = ? AND (#{build_starts_after_conditions(index + 1, binds)}))"
        else
          binds << @cursor[index]
          if @columns.size == @cursor.size
            "#{column} > ?"
          else
            "#{column} >= ?"
          end
        end
      end

      def serialize_column_values!(column_values)
        column_values.map! { |values| values.map! { |value| column_value(value) } }
      end

      def column_value(value)
        if value.is_a?(Time)
          value.strftime(SQL_DATETIME_WITH_NSEC)
        else
          value
        end
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
