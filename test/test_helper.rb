# frozen_string_literal: true

require "active_record"
require "sqlite3"
require "minitest/autorun"
require "sidekiq/testing"
require "logger"
require "sidekiq-iteration"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

logger =
  if ENV["VERBOSE"]
    Logger.new($stdout)
  else
    Logger.new("debug.log", 1, 100 * 1024 * 1024) # 100 mb
  end

ActiveRecord::Base.logger = logger
ActiveRecord::Migration.verbose = false

Sidekiq.configure_client do |config|
  config.logger = nil
end

ActiveRecord::Schema.define do
  create_table :products do |t|
    t.string :name
    t.timestamps
  end

  create_table :comments do |t|
    t.string :content
    t.belongs_to :product
  end

  create_table :orders, primary_key: [:shop_id, :id] do |t|
    t.integer :shop_id
    t.integer :id
  end
end

class Product < ActiveRecord::Base
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :product
end

class Order < ActiveRecord::Base
end

def insert_fixtures
  products = 10.times.map do |i|
    time = (10 - i - 1).seconds.ago
    { id: i + 1, name: "Apple #{i + 1}", created_at: time, updated_at: time }
  end
  Product.insert_all!(products)

  comments = Product.order(:id).limit(3).map.with_index do |product, index|
    comments_count = index + 1
    comments_count.times.map { |i| { content: "#{product.name} comment ##{i + 1}", product_id: product.id } }
  end.flatten

  Comment.insert_all!(comments)

  orders = [
    { shop_id: 3, id: 2 },
    { shop_id: 2, id: 1 },
    { shop_id: 3, id: 4 },
    { shop_id: 1, id: 3 },
    { shop_id: 3, id: 5 },
  ]
  Order.insert_all!(orders)
end

insert_fixtures

class TestCase < Minitest::Test
  def setup
    Sidekiq.redis(&:flushdb)
    Sidekiq::Testing.fake!
  end

  def teardown
    Sidekiq::Worker.clear_all
  end

  def self.test(name, &block)
    test_name = "test_#{name.gsub(/\s+/, '_')}"
    raise "#{test_name} is already defined in #{self}" if method_defined?(test_name)

    define_method(test_name, &block)
  end

  alias assert_not refute
  alias assert_not_nil refute_nil
  alias assert_not_empty refute_empty

  def assert_raises_with_message(exception_class, message, &block)
    error = assert_raises(exception_class, &block)
    assert_match message, error.message
  end

  def assert_logged(message)
    old_logger = SidekiqIteration.logger
    log = StringIO.new
    logger = Logger.new(log)

    SidekiqIteration.logger = logger

    begin
      yield

      log.rewind
      assert_match(message, log.read)
    ensure
      SidekiqIteration.logger = old_logger
    end
  end
end

SidekiqIteration.default_retry_backoff = 10.seconds
