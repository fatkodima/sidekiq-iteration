# frozen_string_literal: true

require "test_helper"

module SidekiqIteration
  class DocumentationTest < TestCase
    def test_documentation_correctly_written
      assert_empty(`bundle exec yard --no-save --no-output --no-stats`)
    end
  end
end
