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
                                      activity: true, group: :transaction, snapshots: true)
PaperTrailDiff.analyze_scope(record, limit: 10, within: window, close_on: :current,
                                     activity: true, group: :transaction, snapshots: true)
