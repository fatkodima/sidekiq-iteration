# frozen_string_literal: true

require "test_helper"

module SidekiqIteration
  class NestedEnumeratorTest < TestCase
    test "accepts only callables as enums" do
      assert_raises_with_message(ArgumentError, "enums must contain only procs/lambdas") do
        build_enumerator(outer: [[1, 2, 3].each])
      end
    end

    test "raises when cursor is not of the same size as enums" do
      assert_raises_with_message(ArgumentError, "cursor should have one item per enum") do
        build_enumerator(cursor: [Product.first.id])
      end
    end

    test "yields enumerator when called without a block" do
      enum = build_enumerator
      assert enum.is_a?(Enumerator)
      assert_nil enum.size
    end

    test "yields every nested record with their cursor position" do
      comments = Comment.order(:product_id, :id).map do |comment|
        [comment, [comment.product_id, comment.id]]
      end

      enum = build_enumerator
      enum.each_with_index do |(comment, cursor), index|
        expected_comment, expected_cursor = comments[index]
        assert_equal(expected_comment, comment)
        assert_equal(expected_cursor, cursor)
      end
    end

    test "cursor can be used to resume" do
      enum = build_enumerator
      _first_comment, first_cursor = enum.next
      second_comment, second_cursor = enum.next

      enum = build_enumerator(cursor: first_cursor)
      assert_equal([second_comment, second_cursor], enum.first)
    end

    test "doesn't yield anything if contains empty enum" do
      enum = ->(cursor, _product) { records_enumerator(Comment.none, cursor: cursor) }
      enum = build_enumerator(inner: enum)
      assert_empty(enum.to_a)
    end

    test "works with single level nesting" do
      enum = build_enumerator(inner: nil)
      products = Product.order(:id).to_a

      enum.each_with_index do |(product, cursor), index|
        assert_equal(products[index], product)
        assert_equal([products[index].id], cursor)
      end
    end

    private
      def build_enumerator(
        outer: ->(cursor) { records_enumerator(Product.all, cursor: cursor) },
        inner: ->(product, cursor) { records_enumerator(product.comments, cursor: cursor) },
        cursor: nil
      )
        NestedEnumerator.new([outer, inner].compact, cursor: cursor).each
      end

      def records_enumerator(scope, cursor: nil)
        ActiveRecordEnumerator.new(scope, cursor: cursor).records
      end
  end
end
