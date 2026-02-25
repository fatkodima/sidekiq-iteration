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
        assert_equal(product, element)
        assert_equal(product.id, cursor)
      end
    end

    test "#records doesn't yield anything if the relation is empty" do
      enum = build_enumerator(relation: Product.none).records

      assert_empty(enum.to_a)
      assert_equal(0, enum.size)
    end

    test "#records iterates over relation with composite primary key" do
      enum = build_enumerator(relation: Order.all).records
      orders = Order.order(:shop_id, :id).to_a
      assert_equal(orders.size, enum.size)

      enum.each_with_index do |(element, cursor), index|
        order = orders[index]
        assert_equal(order, element)

        # Need to use `order[:id]` (or `order.id_value`) because `order.id`
        # returns a primary key value (not a value of an `id` column).
        assert_equal([order.shop_id, order[:id]], cursor)
      end
    end

    test "#batches yields batches of records with the first record's cursor position" do
      enum = build_enumerator.batches
      assert_equal(10, enum.size)

      products = Product.order(:id).take(4).each_slice(2).to_a

      enum.first(2).each_with_index do |(element, cursor), index|
        assert_equal([products[index], products[index].first.id], [element, cursor])
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

      assert_equal([products, products.first.id], enum.first)
    end

    test "paginates using integer conditionals for primary key when no columns are defined" do
      enum = build_enumerator(batch_size: 1).records
      queries = track_queries do
        enum.take(2)
      end
      assert queries.any?(/"products"\."id" > 1/)
    end

    test "single column as array" do
      enum = build_enumerator(columns: [:id]).batches
      products = Product.order(:id).take(2)

      assert_equal([products, products.first.id], enum.first)
    end

    test "single column as symbol" do
      enum = build_enumerator(columns: :id).batches
      products = Product.order(:id).take(2)

      assert_equal([products, products.first.id], enum.first)
    end

    test "raises when columns does not include primary key" do
      assert_raises_with_message(ArgumentError, ":columns must include a primary key columns") do
        build_enumerator(columns: :updated_at).batches
      end
    end

    test "raises when columns does not include all columns of the composite primary key" do
      assert_raises_with_message(ArgumentError, ":columns must include a primary key columns") do
        build_enumerator(relation: Order.all, columns: :id).batches
      end
    end

    test "multiple columns" do
      enum = build_enumerator(columns: [:updated_at, :id]).batches
      products = Product.order(:updated_at, :id).take(2)

      assert_equal([products, [products.first.updated_at.strftime(SQL_TIME_FORMAT), products.first.id]], enum.first)
    end

    test "columns configured with primary key only queries primary key column once" do
      queries = track_queries do
        enum = build_enumerator(columns: [:updated_at, :id]).relations
        enum.first
      end
      assert_match(/\ASELECT "products"."updated_at", "products"."id" FROM/i, queries.first)
    end

    test "namespaced columns on a join relation" do
      relation = Product.joins(:comments)
      enum = build_enumerator(relation: relation, columns: [:id, "comments.id"]).records
      records = enum.to_a.map(&:first)
      expected_ids = relation.order(:id, "comments.id").ids
      assert_equal(expected_ids, records.map(&:id))
    end

    test ":order with single direction" do
      enum = build_enumerator(order: :desc).batches
      product_batches = Product.order(id: :desc).take(4).in_groups_of(2).map { |products| [products, products.first.id] }

      enum.first(2).each_with_index do |(batch, cursor), index|
        assert_equal(product_batches[index], [batch, cursor])
      end
    end

    test ":order with multiple directions" do
      enum = build_enumerator(relation: Order.all, order: [:asc, :desc]).records
      orders = Order.order(shop_id: :asc, id: :desc).to_a
      assert_equal(orders.size, enum.size)

      enum.each_with_index do |(element, cursor), index|
        order = orders[index]
        assert_equal(order, element)
        assert_equal([order.shop_id, order[:id]], cursor)
      end
    end

    test "raises on invalid order" do
      assert_raises_with_message(ArgumentError, ":order must be :asc or :desc") do
        build_enumerator(order: :invalid)
      end

      assert_raises_with_message(ArgumentError, ":order must be :asc or :desc") do
        build_enumerator(order: [:asc, :invalid])
      end
    end

    test "raises on mismatched order array size" do
      assert_raises_with_message(ArgumentError, ":order must include a direction for each batching column") do
        build_enumerator(order: [:asc, :desc])
      end
    end

    test "can be resumed" do
      one, two, three, four = Product.order(:id).take(4)
      enum = build_enumerator(cursor: one.id).batches

      queries = track_queries do
        assert_equal([[one, two], one.id], enum.first)
      end
      assert queries.any?(/"products"\."id" >= 1/)

      assert_equal([[three, four], three.id], enum.first)
    end

    test "can be resumed on multiple columns" do
      enum = build_enumerator(columns: [:created_at, :id]).batches
      products = Product.order(:created_at, :id).take(2)

      cursor = [products.first.created_at.strftime(SQL_TIME_FORMAT), products.first.id]
      assert_equal([products, cursor], enum.first)

      enum = build_enumerator(columns: [:created_at, :id], cursor: cursor).batches
      cursor = [products.first.created_at.strftime(SQL_TIME_FORMAT), products.first.id]
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
