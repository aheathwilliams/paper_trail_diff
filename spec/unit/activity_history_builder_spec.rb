# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::ActivityHistoryBuilder do
  let(:filter) { instance_double(PaperTrailDiff::ActivityTreeFilter) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
    allow(PaperTrailDiff::ActivityTreeFilter).to receive(:new).and_return(filter)
    allow(PaperTrailDiff::ActivitySnapshotSequence).to receive(:new).and_return(:sequence)
  end

  # Four versions of one article, the second of them standing in for a
  # child's, with the snapshot each event shows.
  def history
    article = FilterArticle.create!(title: 'Draft')
    %w[Review Edited Final].each { |title| article.update!(title: title) }
    versions = FilterVersion.where(item_id: article.id).order(:id).to_a
    events = versions.each_with_index.map do |version, index|
      PaperTrailDiff::ActivityEvent.new(version: version,
                                        branches: (['comments'] if index == 1))
    end
    snapshots = %w[Draft Review Edited Final].map do |title|
      PaperTrailDiff::RecordSnapshot.new(type: 'FilterArticle', id: article.id,
                                         attributes: { title: title }, associations: {})
    end
    [events, snapshots]
  end

  # The tree filter's stream: each event, its snapshot, and whether it is
  # kept.
  def stream(*triples)
    triples.each_with_object(allow(filter).to(receive(:call).with(:sequence))) do |triple, stub|
      stub.and_yield(*triple)
    end
  end

  def build(events, reported: ->(_event) { true }, view: PaperTrailDiff::ActivityView.new,
            **options)
    root = PaperTrailDiff::RecordReference.new(type: 'FilterArticle',
                                               id: events.first.version.item_id)
    builder = described_class.new(events.map(&:version), events, :snapshotter,
                                  view: view, include_step: reported, root: root, **options)
    builder.call
  end

  def ends(steps)
    steps.map { |step| [step.from_boundary.version_id, step.to_boundary.version_id] }
  end

  it 'steps from each kept event to the next, keeping the snapshots of root events' do
    events, snapshots = history
    stream(*events.zip(snapshots).map { |event, snapshot| [event, snapshot, true] })

    result = build(events)

    ids = events.map { |event| event.version.id }
    expect(ends(result.steps)).to eq(ids.each_cons(2).to_a)
    expect(result.steps.first.diff.to_h)
      .to eq(PaperTrailDiff::Engine.compare(*snapshots.first(2)).to_h)
    expect(result.root_snapshots).to eq(
      events.zip(snapshots).filter_map do |event, snapshot|
        [PaperTrailDiff::Support.row_key(event.version), snapshot] if event.root?
      end.to_h
    )
    expect([result.first_snapshot, result.last_snapshot, result.last_event_snapshot])
      .to eq([snapshots.first, snapshots.last, snapshots.last])
    expect([result.last_boundary.version_id, result.last_event]).to eq([ids.last, events.last])
  end

  it 'reports only the steps reported events open, from the first of them' do
    events, snapshots = history
    stream(*events.zip(snapshots).map { |event, snapshot| [event, snapshot, true] })

    result = build(events, reported: ->(event) { !event.equal?(events.first) })

    later = events.drop(1).map { |event| event.version.id }

    expect(ends(result.steps)).to eq(later.each_cons(2).to_a)
    expect(result.first_snapshot).to equal(snapshots[1])
  end

  # A left-out event bounds nothing, but a reported step it would have
  # opened still moves the reported end past it.
  it 'moves the end past a left-out event whose step would be reported' do
    events, snapshots = history
    stream([events[0], snapshots[0], true], [events[1], snapshots[1], false],
           [events[2], snapshots[2], true], [events[3], snapshots[3], true])

    result = build(events, reported: ->(event) { event.equal?(events[1]) })
    unmoved = build(events, reported: ->(_event) { false })

    expect(result.steps).to eq([])
    expect(result.last_snapshot).to equal(snapshots[2])
    expect([result.last_boundary.version_id, result.last_event_snapshot])
      .to eq([events[3].version.id, snapshots[3]])
    expect(unmoved.last_snapshot).to be_nil
  end

  it 'keeps the snapshots on steps only when the view retains them' do
    events, snapshots = history
    stream([events[0], snapshots[0], true], [events[1], snapshots[1], true])

    retaining = PaperTrailDiff::ActivityView.new(snapshots: true)
    kept = build(events.first(2), view: retaining).steps.sole
    dropped = build(events.first(2)).steps.sole

    expect([kept.from_snapshot, kept.to_snapshot]).to eq(snapshots.first(2))
    expect([dropped.from_snapshot, dropped.to_snapshot]).to eq([nil, nil])
  end

  it "reads each boundary's recorded changes with the reader for root or child versions" do
    events, snapshots = history
    stream(*events.first(2).zip(snapshots).map { |event, snapshot| [event, snapshot, true] })
    view = instance_double(PaperTrailDiff::ActivityView, retain?: false)
    allow(view).to receive(:recorded_reader).and_return(nil)

    build(events.first(2), view: view)

    expect(view).to have_received(:recorded_reader).with(root: true).ordered
    expect(view).to have_received(:recorded_reader).with(root: false).ordered
  end

  it 'filters the sequence of what it was given, closing as it was told' do
    events, = history
    stream

    result = build(events, current: :current, closing: :closing)

    expect(PaperTrailDiff::ActivityTreeFilter)
      .to have_received(:new).with(events, closing: :closing)
    expect(PaperTrailDiff::ActivitySnapshotSequence)
      .to have_received(:new).with(events.map(&:version), events, :snapshotter,
                                   current: :current)
    expect([result.steps, result.first_snapshot, result.last_boundary]).to eq([[], nil, nil])
  end
end
