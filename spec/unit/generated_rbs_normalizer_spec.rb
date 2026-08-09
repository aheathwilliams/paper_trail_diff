# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../../script/normalize_generated_rbs', __dir__)

RSpec.describe GeneratedRbsNormalizer do
  it 'sorts adjacent instance variables without moving declarations across methods' do
    input = <<~RBS
      class Example
        @zebra: String

        @alpha: Integer

        def call: () -> void

        @later: bool
      end
    RBS

    expect(described_class.normalize(input)).to eq(<<~RBS)
      class Example
        @alpha: Integer

        @zebra: String

        def call: () -> void

        @later: bool
      end
    RBS
  end
end
