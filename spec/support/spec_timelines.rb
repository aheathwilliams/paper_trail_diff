# frozen_string_literal: true

# The step lists `analyze` returns, by the names the specs read them under.
module SpecTimelines
  module_function

  def timeline(record, **options)
    PaperTrailDiff.analyze(record, **options).timeline
  end

  def activity_timeline(record, **options)
    PaperTrailDiff.analyze(record, activity: true, **options).activity_timeline
  end
end
