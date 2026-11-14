# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  create_table :json_timed_events, force: true do |table|
    table.string :title
    table.datetime :starts_at, precision: 6
    table.timestamps null: false
  end
end

class JsonTimedEvent < ActiveRecord::Base
  has_paper_trail
end

# A serializer that writes JSON by way of PaperTrail's, as one that encrypts
# or compresses history does.
module WrappedJsonSerializer
  module_function

  def load(text) = PaperTrail::Serializers::JSON.load(text)
  def dump(object) = PaperTrail::Serializers::JSON.dump(object)
  def where_object_condition(...) = PaperTrail::Serializers::JSON.where_object_condition(...)

  def where_object_changes_condition(...)
    PaperTrail::Serializers::JSON.where_object_changes_condition(...)
  end
end

# JSON history keeps the digits of a time its encoder writes, and an
# unchanged time compares equal to the row only when the gem reads it at
# those digits.
RSpec.describe 'Times in JSON history written another way' do
  around do |example|
    serializer = PaperTrail.serializer
    example.run
  ensure
    PaperTrail.serializer = serializer
    ActiveSupport::JSON::Encoding.use_standard_json_time_format = true
  end

  before do
    PaperTrail::Version.delete_all
    JsonTimedEvent.delete_all
  end

  def changed_names
    event = JsonTimedEvent.create!(title: 'a', starts_at: Time.utc(2026, 3, 1, 12, 0, 0, 123_456))
    event.update!(title: 'b')
    event.update!(title: 'c')
    event = JsonTimedEvent.find(event.id)
    [PaperTrailDiff.compare(event.versions.last, event).attributes.keys,
     PaperTrailDiff.analyze(event).timeline.last.diff.attributes.keys]
  end

  it 'reads a serializer that wraps the JSON one at the digits it writes' do
    PaperTrail.serializer = WrappedJsonSerializer

    expect(changed_names).to eq([['title'], ['title']])
  end

  it "reads Active Support's legacy format at whole seconds" do
    PaperTrail.serializer = PaperTrail::Serializers::JSON
    ActiveSupport::JSON::Encoding.use_standard_json_time_format = false

    expect(changed_names).to eq([['title'], ['title']])
  end
end
