# frozen_string_literal: true

require "active_record"
require "sqlite3"
require "minitest/autorun"
require "sidekiq/testing"
require "logger"
require "sidekiq-iteration"

# This connection will do for database-independent bug reports.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

logger =
  if ENV["VERBOSE"]
    Logger.new($stdout)
  else
    Logger.new("debug.log", 1, 100 * 1024 * 1024) # 100 mb
  end

ActiveRecord::Base.logger = logger
ActiveRecord::Migration.verbose = false
Sidekiq.logger = logger

ActiveRecord::Schema.define do
  create_table :products do |t|
    t.string :name
    t.timestamps
  end
end

class Product < ActiveRecord::Base
  has_many :comments
end

def insert_fixtures
  now = Time.now
  products = 10.times.map { |i| { name: "Apple #{i}", created_at: now - i, updated_at: now - i } }
  Product.insert_all!(products)
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
    old_logger = Sidekiq.logger
    log = StringIO.new
    logger = Logger.new(log)

    Sidekiq.logger = logger

    begin
      yield

      log.rewind
      assert_match(message, log.read)
    ensure
      Sidekiq.logger = old_logger
    end
  end
end
