# frozen_string_literal: true

module SidekiqIteration
  # @private
  class ActiveRecordCursor
    include Comparable

    attr_reader :position, :reached_end

    def initialize(relation, columns = nil, position = nil)
      columns ||= "#{relation.table_name}.#{relation.primary_key}"
      @columns = Array.wrap(columns)
      raise ArgumentError, "Must specify at least one column" if @columns.empty?

      self.position = Array.wrap(position)
      if relation.joins_values.present? && !@columns.all?(/\./)
        raise ArgumentError, "You need to specify fully-qualified columns if you join a table"
      end

      if relation.arel.orders.present? || relation.arel.taken.present?
        raise ArgumentError,
          "The relation cannot use ORDER BY or LIMIT due to the way how iteration with a cursor is designed. " \
          "You can use other ways to limit the number of rows, e.g. a WHERE condition on the primary key column."
      end

      @base_relation = relation.reorder(@columns.join(", "))
      @reached_end = false
    end

    def <=>(other)
      if reached_end == other.reached_end
        position <=> other.position
      else
        reached_end ? 1 : -1
      end
    end

    def position=(position)
      raise ArgumentError, "Cursor position cannot contain nil values" if position.any?(&:nil?)

      @position = position
    end

    def next_batch(batch_size)
      return if @reached_end

      relation = @base_relation.limit(batch_size)

      if (conditions = self.conditions).any?
        relation = relation.where(*conditions)
      end

      records = relation.uncached do
        relation.to_a
      end

      update_from_record(records.last) if records.any?
      @reached_end = records.size < batch_size

      records if records.any?
    end

    private
      def conditions
        i = @position.size - 1
        column = @columns[i]
        conditions = if @columns.size == @position.size
                       "#{column} > ?"
                     else
                       "#{column} >= ?"
                     end
        while i > 0
          i -= 1
          column = @columns[i]
          conditions = "#{column} > ? OR (#{column} = ? AND (#{conditions}))"
        end
        ret = @position.reduce([conditions]) { |params, value| params << value << value }
        ret.pop
        ret
      end

      def update_from_record(record)
        self.position = @columns.map do |column|
          method = column.to_s.split(".").last
          record.send(method)
        end
      end
  end
end
