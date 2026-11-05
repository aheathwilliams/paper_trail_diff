# frozen_string_literal: true

# PaperTrail writes history with its YAML serializer unless told otherwise, and
# so do the suites. `PAPER_TRAIL_DIFF_SERIALIZER=json` runs them with its JSON
# serializer instead. An example that switches serializers puts back whatever
# was set, and one tagged `history: :yaml` is about YAML history and keeps it.
module HistorySerializer
  JSON_COLUMN_TYPES = %i[json jsonb].freeze

  module_function

  def json?
    ENV.fetch('PAPER_TRAIL_DIFF_SERIALIZER', 'yaml') == 'json'
  end

  # Fractional digits a version class's history keeps for times, or nil when
  # it keeps them whole. Active Support's JSON encoder, which both PaperTrail's
  # JSON serializer and a json object column go through, keeps milliseconds by
  # default.
  def time_digits(version_class = PaperTrail::Version)
    json_columns = %w[object object_changes].any? do |name|
      JSON_COLUMN_TYPES.include?(version_class.columns_hash[name]&.type)
    end
    json = json_columns || PaperTrail.serializer.equal?(PaperTrail::Serializers::JSON)
    ActiveSupport::JSON::Encoding.time_precision if json
  end

  # A live row's attributes as its history can hold them, which is how the gem
  # compares a live row with history. A model without versions has none.
  def as_stored(record, attributes)
    model = record.class
    return attributes unless model.respond_to?(:paper_trail_options) && model.paper_trail_options

    digits = time_digits(model.paper_trail.version_class)
    return attributes unless digits

    attributes.transform_values do |value|
      next value unless value.is_a?(Time)

      value.change(nsec: value.nsec - (value.nsec % (10**(9 - digits))))
    end
  end

  def with(serializer)
    original = PaperTrail.serializer
    PaperTrail.serializer = serializer
    yield
  ensure
    PaperTrail.serializer = original
  end
end

RSpec.configure do |config|
  if HistorySerializer.json?
    config.before(:suite) { PaperTrail.serializer = PaperTrail::Serializers::JSON }
  end

  config.around(history: :yaml) do |example|
    HistorySerializer.with(PaperTrail::Serializers::YAML) { example.run }
  end
end
