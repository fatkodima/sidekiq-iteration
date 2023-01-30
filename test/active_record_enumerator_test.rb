# frozen_string_literal: true

require "test_helper"

module SidekiqIteration
  class ActiveRecordEnumeratorTest < TestCase
    SQL_TIME_FORMAT = "%Y-%m-%d %H:%M:%S.%6N"

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
      assert_equal(10, enum.size)

      products = Product.order(:id).take(4).each_slice(2).to_a

      enum.first(2).each_with_index do |(element, cursor), index|
        assert_equal([products[index], products[index].last.id], [element, cursor])
      end
    end

    test "#batches doesn't yield anything if the relation is empty" do
      enum = build_enumerator(relation: Product.none).batches
      assert_empty(enum.to_a)
    end

    test "#relations yields relations with the last record's cursor position" do
      enum = build_enumerator.relations
      assert_equal(5, enum.size)

      product_batches = Product.order(:id).take(4).in_groups_of(2).map { |products| [products, products.last.id] }

      enum.first(2).each_with_index do |(batch, cursor), index|
        assert_kind_of(ActiveRecord::Relation, batch)
        assert_equal(product_batches[index], [batch, cursor])
      end
    end

    test "#relations yields unloaded relations" do
      enum = build_enumerator.relations
      relation, = enum.first

      assert_not(relation.loaded?)
    end

    test "#relations yields relations that preserve the existing conditions (like ActiveRecord::Batches)" do
      enum = build_enumerator(relation: Product.where("name LIKE 'Apple%'")).relations
      relation, = enum.first
      assert_includes(relation.to_sql, "Apple")
    end

    test "#relations doesn't yield anything if the relation is empty" do
      enum = build_enumerator(relation: Product.none).relations

      assert_empty(enum.to_a)
    end

    test "#relations one query performed per batch, plus an additional one for the empty cursor" do
      enum = build_enumerator.relations
      num_batches = 0
      queries = track_queries do
        enum.each { num_batches += 1 }
      end

      assert_equal num_batches + 1, queries.size
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

    test "columns configured with primary key only queries primary key column once" do
      queries = track_queries do
        enum = build_enumerator(columns: [:updated_at, :id]).relations
        enum.first
      end
      assert_match(/\ASELECT "products"."updated_at", "products"."id" FROM/i, queries.first)
    end

    test "order is configurable" do
      enum = build_enumerator(order: :desc).batches
      product_batches = Product.order(id: :desc).take(4).in_groups_of(2).map { |products| [products, products.last.id] }

      enum.first(2).each_with_index do |(batch, cursor), index|
        assert_equal(product_batches[index], [batch, cursor])
      end
    end

    test "raises on invalid order" do
      error = assert_raises(ArgumentError) do
        build_enumerator(order: :invalid)
      end
      assert_equal ":order must be :asc or :desc, got :invalid", error.message
    end

    test "can be resumed" do
      one, two, three, four = Product.order(:id).take(4)
      enum = build_enumerator(cursor: one.id).batches

      assert_equal([[one, two], two.id], enum.first)
      assert_equal([[three, four], four.id], enum.first)
    end

    test "can be resumed on multiple columns" do
      enum = build_enumerator(columns: [:created_at, :id]).batches
      products = Product.order(:created_at, :id).take(2)

      cursor = [products.last.created_at.strftime(SQL_TIME_FORMAT), products.last.id]
      assert_equal([products, cursor], enum.first)

      enum = build_enumerator(columns: [:created_at, :id], cursor: cursor).batches
      products = Product.order(:created_at, :id).offset(1).take(2)

      cursor = [products.last.created_at.strftime(SQL_TIME_FORMAT), products.last.id]
      assert_equal([products, cursor], enum.first)
    end

    private
      def build_enumerator(relation: Product.all, batch_size: 2, columns: nil, order: :asc, cursor: nil)
        ActiveRecordEnumerator.new(relation, batch_size: batch_size, columns: columns, order: order, cursor: cursor)
      end

      def track_queries(&block)
        queries = []
        query_cb = ->(*, payload) { queries << payload[:sql] }
        ActiveSupport::Notifications.subscribed(query_cb, "sql.active_record", &block)
        queries
      end
  end
end
