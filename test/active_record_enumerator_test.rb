# frozen_string_literal: true

require "test_helper"

module SidekiqIteration
  class ActiveRecordEnumeratorTest < TestCase
    SQL_TIME_FORMAT = "%Y-%m-%d %H:%M:%S.%N"

    test "#records yields every record with their cursor position" do
      enum = build_enumerator.records
      assert_equal(Product.count, enum.size)

      products = Product.order(:id).take(3)
      enum.first(3).each_with_index do |(element, cursor), index|
        product = products[index]
        assert_equal([product, product.id], [element, cursor])
      end
    end

    test "#records doesn't yield anything if the relation is empty" do
      enum = build_enumerator(relation: Product.none).records

      assert_empty(enum.to_a)
      assert_equal(0, enum.size)
    end

    test "#batches yields batches of records with the last record's cursor position" do
      enum = build_enumerator.batches
      products = Product.order(:id).take(4).each_slice(2).to_a

      enum.first(2).each_with_index do |(element, cursor), index|
        assert_equal([products[index], products[index].last.id], [element, cursor])
      end
    end

    test "#batches doesn't yield anything if the relation is empty" do
      enum = build_enumerator(relation: Product.none).batches
      assert_empty(enum.to_a)
    end

    test "batch size is configurable" do
      enum = build_enumerator(batch_size: 4).batches
      products = Product.order(:id).take(4)

      assert_equal([products, products.last.id], enum.first)
    end

    test "columns are configurable" do
      enum = build_enumerator(columns: [:updated_at]).batches
      products = Product.order(:updated_at).take(2)

      assert_equal([products, products.last.updated_at.strftime(SQL_TIME_FORMAT)], enum.first)
    end

    test "multiple columns" do
      enum = build_enumerator(columns: [:updated_at, :id]).batches
      products = Product.order(:updated_at, :id).take(2)

      assert_equal([products, [products.last.updated_at.strftime(SQL_TIME_FORMAT), products.last.id]], enum.first)
    end

    test "can be resumed" do
      first, middle, last = Product.order(:id).take(3)
      enum = build_enumerator(cursor: first.id).batches

      assert_equal([[middle, last], last.id], enum.first)
    end

    test "can be resumed on multiple columns" do
      enum = build_enumerator(columns: [:created_at, :id]).batches
      products = Product.order(:created_at, :id).take(2)

      cursor = [products.last.created_at.strftime(SQL_TIME_FORMAT), products.last.id]
      assert_equal([products, cursor], enum.first)

      enum = build_enumerator(columns: [:created_at, :id], cursor: cursor).batches
      products = Product.order(:created_at, :id).offset(2).take(2)

      cursor = [products.last.created_at.strftime(SQL_TIME_FORMAT), products.last.id]
      assert_equal([products, cursor], enum.first)
    end

    test "#size returns the number of items in the relation" do
      enum = build_enumerator

      assert_equal(10, enum.size)
    end

    private
      def build_enumerator(relation: Product.all, batch_size: 2, columns: nil, cursor: nil)
        ActiveRecordEnumerator.new(relation, batch_size: batch_size, columns: columns, cursor: cursor)
      end
  end
end
