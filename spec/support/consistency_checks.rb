# frozen_string_literal: true

# Checks that every route to the same answer agrees on seeded, generated
# histories. The bugs these catch are the ones a hand-written example misses:
# a schema or serializer variant one code path handles and another does not,
# or a batch method drifting from the single-record method it should equal.
module ConsistencyChecks
  SEEDS = (1..6)

  # A seeded mix of root edits, child creates, edits and deletes, and root
  # checkpoints. `children:` is nil for a root-only history.
  class History
    ROOT_OPERATIONS = %i[edit_root checkpoint].freeze
    CHILD_OPERATIONS = %i[create_child edit_child destroy_child].freeze

    def initialize(root_class, seed:, children: nil, child_attribute: :body, steps: 9, # rubocop:disable Metrics/ParameterLists
                   attributes: {})
      @root_class = root_class
      @attributes = attributes
      @random = Random.new(seed)
      @children = children
      @child_attribute = child_attribute
      @steps = steps
      @live_children = []
    end

    def build
      root = @root_class.create!(title: 'title 0', **@attributes)
      @steps.times { |index| apply(root, index) }
      root.reload
    end

    private

    def apply(root, index)
      operations = @children ? ROOT_OPERATIONS + CHILD_OPERATIONS : ROOT_OPERATIONS
      send(operations.sample(random: @random), root, index)
    end

    def edit_root(root, index)
      root.update!(title: "title #{index + 1}")
    end

    def checkpoint(root, _index)
      @root_class.transaction { @root_class.find(root.id).paper_trail.save_with_version }
    end

    def create_child(root, index)
      @live_children << root.public_send(@children).create!(@child_attribute => "new #{index}")
    end

    def edit_child(_root, index)
      pick&.update!(@child_attribute => "edit #{index}")
    end

    def destroy_child(_root, _index)
      child = pick
      @live_children.delete(child)&.destroy!
    end

    def pick
      @live_children.sample(random: @random)
    end
  end

  def diffs(analysis)
    [analysis.diff.to_h, analysis.timeline.map { |step| step.diff.to_h }]
  end

  def identity(record)
    PaperTrailDiff::Endpoint.identity(record)
  end

  # Whole history through current state: every method that can answer it must
  # give the same net diff and root timeline.
  def expect_whole_history_consistent(root, associations:)
    options = { associations: associations }
    single = PaperTrailDiff.analyze(root, **options)
    activity = PaperTrailDiff.analyze(root, **options, activity: true, snapshots: true)
    batch = PaperTrailDiff.analyze_many([root], **options).fetch(identity(root))
    timeline = PaperTrailDiff.timeline(root, **options)
    first = root.versions.reorder(created_at: :asc, id: :asc).first
    compared = PaperTrailDiff.compare(first, root, **options)

    expect(diffs(batch)).to eq(diffs(single))
    expect(diffs(activity)).to eq(diffs(single))
    expect(timeline.map { |step| step.diff.to_h }).to eq(diffs(single).last)
    expect(compared.to_h).to eq(single.diff.to_h)
    expect_chained(activity.activity_timeline, ends_at: single.to_snapshot)
  end

  # Each activity step starts exactly where the previous one ended, and the
  # last ends at the analysis's final state.
  def expect_chained(steps, ends_at:)
    steps.each_cons(2) do |previous, following|
      expect(following.from_snapshot&.to_h).to eq(previous.to_snapshot&.to_h)
    end
    expect(steps.last&.to_snapshot&.to_h).to eq(ends_at&.to_h)
  end

  # A random window between two recorded times: single, batch, and scoped
  # analysis must agree, in both checkpoint and activity modes.
  def expect_window_consistent(root, associations:, scope:, random:)
    times = root.class.paper_trail.version_class.order(:created_at).pluck(:created_at)
    first, last = times.sample(2, random: random).sort
    window = first..last
    [false, true].each do |activity|
      options = { within: window, associations: associations, activity: activity }
      single = PaperTrailDiff.analyze(root, **options)
      batch = PaperTrailDiff.analyze_many([root], **options).fetch(identity(root))
      scoped = PaperTrailDiff.analyze_scope(scope, limit: 10, **options).analyses[identity(root)]

      expect(diffs(batch)).to eq(diffs(single)), "window #{window}, activity: #{activity}"
      # Activity selects a root whenever its analysis has something to report,
      # including changes to its associations alone.
      if activity && !single.diff.empty?
        expect(scoped).not_to be_nil, "window #{window}: activity selected nothing to report"
      end
      next unless scoped

      expect(diffs(scoped)).to eq(diffs(single)), "window #{window}, activity: #{activity}"
    end
  end
end
