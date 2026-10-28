# frozen_string_literal: true

# Checked, not executed: consuming the signatures catches missing keywords
# that checking only the implementation can overlook.
record = Object.new
window = Time.now..Time.now
PaperTrailDiff.activity_timeline(record, from: :first, to: record,
                                         group: :transaction, snapshots: true).each do |step|
  step.source_boundary.whodunnit
  step.to_h(metadata: true, snapshots: true)
end
PaperTrailDiff.timeline(record, from: :first, to: record).each do |step|
  step.source_boundary.record
  step.to_h(metadata: true)
end
PaperTrailDiff.analyze(record, from: :first, to: record, activity: true,
                               group: :transaction, snapshots: true).to_h(metadata: true)
PaperTrailDiff.analyze_many([record], within: window, close_on: :current,
                                      activity: true, group: :transaction, snapshots: true,
                                      allow_expensive: false)
PaperTrailDiff.analyze_scope(record, limit: 10, within: window, close_on: :current,
                                     activity: true, group: :transaction, snapshots: true,
                                     historical_filter: { status: 'published' },
                                     max_filter_versions: 500, include_deleted: true,
                                     allow_expensive: false)
PaperTrailDiff.compare_many([{ from: :first, to: record }], allow_expensive: true)
PaperTrailDiff.report(record, since: window.begin, limit: 10,
                              historical_filter: { status: 'published' },
                              max_filter_versions: 500, include_deleted: true,
                              allow_expensive: false).deleted
PaperTrailDiff.report(record, since: window.begin, limit: 10,
                              historical_filter: ->(_state) { true },
                              allow_expensive: true).analyses
