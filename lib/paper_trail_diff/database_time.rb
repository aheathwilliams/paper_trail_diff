# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads a date, or text, given for a datetime column as the database keeps
  # it: in Active Record's default time zone, not Time.zone.
  #
  # Active Record leaves a date assigned to a datetime column on the instance
  # as it was given when time zone aware attributes are off, or when
  # `update_columns` writes it, and PaperTrail stores it from there. The
  # database keeps midnight in its own zone, and `where` sends text or a date
  # to the database as it is. Read through the attribute instead, a date
  # would be midnight in Time.zone, or not a time at all.
  module DatabaseTime
    # A date as JSON writes one, with no time.
    DATE_TEXT = /\A\d{4}-\d{2}-\d{2}\z/
    # The same date in stored text: YAML writes it as a bare value at the
    # end of its line, JSON as quoted text.
    STORED_DATE = /[ "]\d{4}-\d{2}-\d{2}(?:"|$)/
    private_constant :DATE_TEXT, :STORED_DATE

    # A stored value of a datetime column, with a date in it read as
    # midnight where the database keeps it. A change's values are a pair.
    #: (untyped) -> untyped
    def self.stored(value)
      return value.map { |item| stored(item) } if value.instance_of?(Array)

      date = value.instance_of?(String) ? written_date(value) : value
      date.instance_of?(Date) ? midnight(date) : value
    end

    # A date or text given for a datetime column, as the database reads it
    # when `where` sends it: in its own time zone, unless the text names its
    # offset. Anything else, and text that names no time, is returned as it
    # is.
    #: (untyped) -> untyped
    def self.cast(value)
      return midnight(value) if value.instance_of?(Date)
      return value unless value.instance_of?(String)

      parsed = local? ? Time.parse(value) : Support.constant('ActiveSupport::TimeZone')['UTC'].parse(value)
      parsed || value
    rescue ArgumentError
      value
    end

    # Whether a version's stored attributes hold a date with no time for a
    # model with a datetime column, which only then is read again.
    #: (untyped, untyped) -> bool
    def self.stored_date?(object, model)
      return false if TimeOfDay.datetime_columns(model).empty?
      return STORED_DATE.match?(object) if object.instance_of?(String)

      object.respond_to?(:each_value) &&
        object.each_value.any? { |value| value.instance_of?(String) && DATE_TEXT.match?(value) }
    end

    # A Date; the packaged signatures name only core types.
    #: (untyped) -> Time
    def self.midnight(date)
      clock = Time #: untyped
      if local?
        clock.local(date.year, date.month,
                    date.day)
      else
        clock.utc(date.year, date.month, date.day)
      end
    end
    private_class_method :midnight

    #: () -> bool
    def self.local?
      Support.constant('ActiveRecord').default_timezone == :local
    end
    private_class_method :local?

    #: (String) -> untyped
    def self.written_date(text)
      Date.iso8601(text) if DATE_TEXT.match?(text)
    rescue ArgumentError
      nil
    end
    private_class_method :written_date
  end
end
