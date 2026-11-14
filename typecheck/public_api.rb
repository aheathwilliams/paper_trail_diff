# frozen_string_literal: true

# Checked, not executed: consuming the signatures catches missing keywords
# that checking only the implementation can overlook.
record = Object.new
window = Time.now..Time.now
activity = PaperTrailDiff.analyze(record, from: :first, to: record, activity: true,
                                          group: :transaction, snapshots: true)
activity.activity_timeline&.each do |step|
  step.source_boundary.whodunnit
  step.to_h(metadata: true, snapshots: true)
end
PaperTrailDiff.analyze(record, from: :first, to: record).timeline.each do |step|
  step.source_boundary.record
  step.to_h(metadata: true)
end
PaperTrailDiff.analyze(record, from: :first, to: record, activity: true,
                               group: :transaction, snapshots: true).to_h(metadata: true)
PaperTrailDiff.analyze_many([record], within: window, activity: true, group: :transaction,
                                      snapshots: true)
PaperTrailDiff.analyze_scope(record, limit: 10, within: window,
                                     activity: true, group: :transaction, snapshots: true,
                                     include_deleted: true)
PaperTrailDiff.compare_many([{ from: :first, to: record }])
PaperTrailDiff.report(record, since: window.begin, limit: 10,
                              include_deleted: true).deleted
PaperTrailDiff.report(record, since: window.begin, limit: 10).analyses
PaperTrailDiff.recorded_changes(record, ignore: [:updated_at, 'lock_version'])&.each_value(&:to_h)
