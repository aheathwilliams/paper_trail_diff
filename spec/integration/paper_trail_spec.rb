# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe PaperTrailDiff do
  before do
    PaperTrail::Version.delete_all
    CoreComment.delete_all
    CoreArticle.delete_all
  end

  def create_history
    article = CoreArticle.create!(
      title: 'Draft',
      internal_note: 'stable',
      created_at: Time.utc(2026, 1, 1),
      updated_at: Time.utc(2026, 1, 1)
    )
    article.update!(title: 'Published', updated_at: Time.utc(2026, 1, 2))
    article.update!(title: 'Draft', updated_at: Time.utc(2026, 1, 3))
    article.update!(internal_note: 'changed', updated_at: Time.utc(2026, 1, 4))
    [article, *article.versions.reload.to_a]
  end

  def instantiated_record_count(&block)
    count = 0
    callback = proc do |_name, _start, _finish, _id, payload|
      count += payload[:record_count].to_i
    end
    ActiveSupport::Notifications.subscribed(callback, 'instantiation.active_record', &block)
    count
  end

  def timestamp_versions(versions, start_at: Time.utc(2030, 1, 1))
    versions.each_with_index.map do |version, index|
      timestamp = start_at + (index * 3600)
      version.update_columns(created_at: timestamp)
      timestamp
    end
  end

  describe '.compare' do
    it 'reifies endpoints and compares scalar attributes' do
      _article, _create, draft, published, = create_history

      result = described_class.compare(draft, published)

      expect(result.to_h).to eq(
        record_presence_change: nil,
        attributes: { 'title' => { from: 'Draft', to: 'Published' } },
        associations: {}
      )
    end

    it 'compares a version with an explicit current record endpoint in either direction' do
      article, _create, _draft, _published, current_before = create_history

      forward = described_class.compare(current_before, article)
      reverse = described_class.compare(article, current_before)

      expect(forward.attributes.fetch('internal_note').to_h)
        .to eq(from: 'stable', to: 'changed')
      expect(reverse.attributes.fetch('internal_note').to_h)
        .to eq(from: 'changed', to: 'stable')
    end

    it 'rejects two versions given in reverse chronological order' do
      article, _create, draft, published, = create_history

      expect { described_class.compare(published, draft) }
        .to raise_error(PaperTrailDiff::ReversedEndpointsError, /chronological order/)

      # Swapping reads the same difference in the other direction.
      expect(described_class.compare(draft, published).attributes.fetch('title').to_h)
        .to eq(from: 'Draft', to: 'Published')
      # A current-record endpoint is self-evidently live, so either side is fine.
      expect { described_class.compare(article, draft) }.not_to raise_error
      expect { described_class.compare(draft, draft) }.not_to raise_error
    end

    it 'rejects a reversed pair in a batched comparison' do
      _article, _create, draft, published, = create_history

      expect do
        described_class.compare_many([{ from: published, to: draft }])
      end.to raise_error(PaperTrailDiff::ReversedEndpointsError, /chronological order/)
    end

    it 'resolves :first and :last endpoints for a whole batch' do
      endpoints = 3.times.map do |index|
        article = CoreArticle.create!(title: "Draft #{index}", internal_note: 'stable')
        article.update!(title: "Published #{index}")
        article
      end

      symbolic = described_class.compare_many(
        endpoints.map { |article| { from: :first, to: article } }
      )
      explicit = described_class.compare_many(
        endpoints.map { |article| { from: article.versions.reload.first, to: article } }
      )

      expect(symbolic.transform_values(&:to_h)).to eq(explicit.transform_values(&:to_h))
    end

    it 'answers an unresolvable or unanchored boundary symbol explicitly' do
      article = CoreArticle.create!(title: 'Draft', internal_note: 'stable')
      article.update!(title: 'Published')
      untracked = PaperTrail.request(enabled: false) do
        CoreArticle.create!(title: 'Untracked', internal_note: 'none')
      end

      # No recorded history is an empty result, not a failure.
      results = described_class.compare_many(
        [{ from: :first, to: article }, { from: :first, to: untracked }]
      )
      expect(results.fetch(PaperTrailDiff::Endpoint.identity(untracked))).to be_empty
      expect(results.fetch(PaperTrailDiff::Endpoint.identity(article))).not_to be_empty

      # A symbol carries no identity, so something must anchor it.
      expect { described_class.compare_many([{ from: :first, to: :last }]) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /name a record/)
      expect { described_class.compare_many([{ from: :beginning, to: article }]) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /unsupported boundary/)
    end

    it 'rejects invalid and mismatched current record endpoints' do
      article, _create, draft, = create_history
      other = CoreArticle.create!(title: 'Other', internal_note: 'other')
      article.title = 'Unsaved'

      expect { described_class.compare(draft, article) }
        .to raise_error(PaperTrailDiff::InvalidEndpointError, /unsaved/)
      expect { described_class.compare(draft, CoreArticle.new) }
        .to raise_error(PaperTrailDiff::InvalidEndpointError, /persisted/)
      expect { described_class.compare(draft, other) }
        .to raise_error(PaperTrailDiff::VersionMismatchError, /same PaperTrail item/)
      expect { described_class.compare(draft, Object.new) }
        .to raise_error(PaperTrailDiff::InvalidEndpointError, /version or persisted record/)

      other.destroy!
      expect { described_class.compare(other, other) }
        .to raise_error(PaperTrailDiff::InvalidEndpointError, /not destroyed/)

      missing = CoreArticle.create!(title: 'Missing', internal_note: 'missing')
      CoreArticle.where(id: missing.id).delete_all
      expect { described_class.compare(missing, missing) }
        .to raise_error(PaperTrailDiff::InvalidEndpointError, /reloaded/)
    end

    it 'normalizes associations between live endpoints without requiring PT-AT' do
      article, = create_history
      article.comments.create!(body: 'Current comment')

      result = described_class.compare(
        article,
        CoreArticle.find(article.id),
        associations: ['comments.article']
      )

      expect(result).to be_empty
    end

    it 'lets ignore replace the default noise fields' do
      _article, _create, draft, published, = create_history

      all_fields = described_class.compare(draft, published, ignore: [])
      without_title = described_class.compare(draft, published, ignore: %i[updated_at title])

      expect(all_fields.attributes.keys).to contain_exactly('title', 'updated_at')
      expect(without_title).to be_empty
    end

    it 'reports only net endpoint state after a reverted change' do
      _article, _create, draft, _published, reverted = create_history

      expect(described_class.compare(draft, reverted)).to be_empty
    end

    it 'represents a create version reifying to nil as a record presence change' do
      _article, create_version, first_record_state, = create_history

      result = described_class.compare(create_version, first_record_state)

      expect(result.record_presence_change.from).to be_nil
      expect(result.record_presence_change.to).to be_a(PaperTrailDiff::RecordSnapshot)
      expect(result.record_presence_change.to.type).to eq('CoreArticle')
      expect(result.attributes).to be_empty
      expect(result.associations).to be_empty
    end

    it 'rejects versions belonging to different records' do
      _article, _create, first_version, = create_history
      other = CoreArticle.create!(title: 'Other', internal_note: 'other')

      expect { described_class.compare(first_version, other.versions.first) }
        .to raise_error(PaperTrailDiff::VersionMismatchError, /same PaperTrail item/)
    end

    it 'validates option element types' do
      _article, _create, draft, published, = create_history

      expect { described_class.compare(draft, published, ignore: nil) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /ignore/)
      expect { described_class.compare(draft, published, associations: [nil]) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /associations/)
    end

    it 'raises clearly when associations are requested without PT-AT loaded' do
      _article, _create, draft, published, = create_history

      expect { described_class.compare(draft, published, associations: ['comments.replies']) }
        .to raise_error(
          PaperTrailDiff::AssociationTrackingUnavailableError,
          /must be loaded and enabled/
        )
    end
  end

  describe '.compare_many' do
    it 'matches individual comparisons and batches current root loading' do
      endpoints = 3.times.map do |index|
        article = CoreArticle.create!(title: "Draft #{index}", internal_note: 'stable')
        article.update!(title: "Published #{index}")
        [article.versions.reload.last, article]
      end
      comparisons = endpoints.map { |from, to| { from: from, to: to } }
      expected = endpoints.to_h do |from, to|
        [PaperTrailDiff::Endpoint.identity(from), described_class.compare(from, to).to_h]
      end
      sql = []
      callback = proc do |_name, _start, _finish, _id, payload|
        sql << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
      end

      results = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.compare_many(comparisons)
      end

      expect(results.transform_values(&:to_h)).to eq(expected)
      expect(sql.grep(/FROM "core_articles"/).length).to eq(1)
      expect(results).to be_frozen
      expect(results.keys).to all(be_frozen)
    end

    it 'preloads the selected live association once for the whole batch' do
      articles = 3.times.map do |index|
        article = CoreArticle.create!(title: "Article #{index}", internal_note: 'stable')
        article.comments.create!(body: "Comment #{index}")
        article
      end
      comparisons = articles.map { |article| { 'from' => article, 'to' => article } }
      sql = []
      callback = proc do |_name, _start, _finish, _id, payload|
        sql << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
      end

      results = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.compare_many(comparisons, associations: [:comments])
      end

      expect(results.values).to all(be_empty)
      expect(sql.grep(/FROM "core_articles"/).length).to eq(1)
      expect(sql.grep(/FROM "core_comments"/).length).to eq(1)
    end

    it 'reuses fully preloaded endpoints without live-record queries' do
      articles = 3.times.map do |index|
        article = CoreArticle.create!(title: "Preloaded #{index}", internal_note: 'stable')
        article.comments.create!(body: "Comment #{index}")
        article
      end
      preloaded = CoreArticle.where(id: articles.map(&:id)).preload(:comments).to_a
      comparisons = preloaded.map { |article| { from: article, to: article } }
      sql = []
      callback = proc do |_name, _start, _finish, _id, payload|
        sql << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
      end

      results = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.compare_many(
          comparisons,
          associations: [:comments],
          reload_live_endpoints: false
        )
      end
      single = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.compare(
          preloaded.first,
          preloaded.first,
          associations: [:comments],
          reload_live_endpoints: false
        )
      end

      expect(results.values).to all(be_empty)
      expect(single).to be_empty
      expect(sql).to be_empty
    end

    it 'rejects missing preloads and invalid reload options' do
      article = CoreArticle.create!(title: 'Not preloaded', internal_note: 'stable')
      current = CoreArticle.find(article.id)

      expect do
        described_class.compare(
          current,
          current,
          associations: [:comments],
          reload_live_endpoints: false
        )
      end.to raise_error(
        PaperTrailDiff::UnloadedAssociationError,
        /not preloaded: comments/
      )
      expect do
        described_class.compare_many([], reload_live_endpoints: nil)
      end.to raise_error(PaperTrailDiff::ConfigurationError, /must be true or false/)
    end

    it 'emits namespaced runtime notifications without endpoint objects' do
      article = CoreArticle.create!(title: 'Instrumented', internal_note: 'stable')
      events = []
      callback = proc do |name, started, finished, _id, payload|
        events << { name: name, duration: finished - started, payload: payload }
      end

      ActiveSupport::Notifications.subscribed(callback, /\.paper_trail_diff\z/) do
        described_class.compare_many([{ from: article, to: article }])
      end

      comparison = events.find { |event| event.fetch(:name) == 'compare_many.paper_trail_diff' }
      loading = events.find { |event| event.fetch(:name) == 'load_live_endpoints.paper_trail_diff' }
      expect(comparison.fetch(:payload)).to eq(
        comparison_count: 1,
        association_paths: [],
        reload_live_endpoints: true
      )
      expect(loading.fetch(:payload)).to eq(
        endpoint_count: 1,
        model_types: ['CoreArticle'],
        reload_live_endpoints: true
      )
      expect(events.map { |event| event.fetch(:duration) }).to all(be >= 0)
    end

    it 'validates the batch shape, unique identities, and reloadability' do
      article = CoreArticle.create!(title: 'Valid', internal_note: 'stable')
      comparison = { from: article, to: article }

      expect(described_class.compare_many([])).to eq({})
      expect(described_class.compare_many([])).to be_frozen
      expect { described_class.compare_many(nil) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /must be an array/)
      expect { described_class.compare_many([{ from: article }]) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /exactly from: and to:/)
      expect { described_class.compare_many([comparison, comparison]) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /identities must be unique/)

      CoreArticle.where(id: article.id).delete_all
      expect { described_class.compare_many([comparison]) }
        .to raise_error(PaperTrailDiff::InvalidEndpointError, /reloaded/)
    end
  end

  describe '.analyze_many' do
    def windowed_articles(count)
      articles = count.times.map do |index|
        article = CoreArticle.create!(title: "Draft #{index}", internal_note: 'stable')
        article.update!(title: "Published #{index}")
        article
      end
      start_at = PaperTrail::Version.order(:id).first.created_at
      cutoff = PaperTrail::Version.order(:id).last.created_at
      articles.each_with_index { |article, i| article.update!(title: "Final #{i}") }
      [articles, start_at..cutoff]
    end

    it 'matches analyzing each root separately over the same window' do
      articles, window = windowed_articles(3)

      batched = described_class.analyze_many(articles, within: window)
      separately = articles.to_h do |article|
        [PaperTrailDiff::Endpoint.identity(article),
         described_class.analyze(article, within: window)]
      end

      expect(batched.keys).to eq(separately.keys)
      expect(batched.transform_values(&:to_h)).to eq(separately.transform_values(&:to_h))
      expect(batched).to be_frozen
    end

    it 'returns an empty analysis for a root with no versions in the window' do
      articles, window = windowed_articles(2)
      untracked = PaperTrail.request(enabled: false) do
        CoreArticle.create!(title: 'Untracked', internal_note: 'none')
      end

      results = described_class.analyze_many(articles + [untracked], within: window)
      empty = results.fetch(PaperTrailDiff::Endpoint.identity(untracked))

      expect(results.length).to eq(3)
      expect(empty.timeline).to eq([])
      expect(empty.diff).to be_empty
    end

    it 'rejects duplicate roots and non-record input' do
      articles, window = windowed_articles(1)

      expect { described_class.analyze_many(articles * 2, within: window) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /unique/)
      expect { described_class.analyze_many(articles.first, within: window) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /must be an array/)
      expect { described_class.analyze_many([Object.new], within: window) }
        .to raise_error(PaperTrailDiff::InvalidEndpointError)
    end
  end

  describe '.timeline' do
    it 'returns every adjacent step including both sides of a revert' do
      article, _create, draft, published, reverted = create_history

      steps = described_class.timeline(article, from: draft, to: reverted)

      expect(steps).to be_frozen
      expect(steps.length).to eq(2)
      expect(steps.map { |step| step.diff.attributes.fetch('title').to_h }).to eq(
        [
          { from: 'Draft', to: 'Published' },
          { from: 'Published', to: 'Draft' }
        ]
      )
      expect(steps.first.to_h).to include(
        from_version_id: draft.id,
        to_version_id: published.id
      )
      expect(steps.first.from_boundary.record.to_h).to eq(
        type: 'CoreArticle', id: article.id.to_s
      )
      expect(steps.first.from_boundary).to be_version
      expect(steps.first.from_boundary).not_to be_current
      expect(steps.first.from_boundary.event).to eq('update')
      expect(steps.first).not_to be_empty
    end

    it 'exposes immutable version metadata through the shared boundary protocol' do
      article = CoreArticle.create!(title: 'Draft', internal_note: 'stable')
      PaperTrail.request(whodunnit: 'developer-7') do
        article.update!(title: 'Published')
      end
      from_version, to_version = article.versions.reload.to_a

      step = described_class.timeline(
        article,
        from: from_version,
        to: to_version
      ).fetch(0)

      expect(step.from_boundary.event).to eq('create')
      expect(step.from_boundary.whodunnit).to be_nil
      expect(step.to_boundary.event).to eq('update')
      expect(step.to_boundary.whodunnit).to eq('developer-7')
      expect(step.from_boundary).to be_frozen
      expect(step.to_boundary).to be_frozen
      expect(step.from_boundary.to_h.keys)
        .to eq(%i[kind version_id item_type item_id recorded_at])
    end

    it 'returns an empty frozen array for equal boundaries' do
      article, _create, draft, = create_history

      result = described_class.timeline(article, from: draft, to: draft)

      expect(result).to eq([])
      expect(result).to be_frozen
    end

    it 'shares empty and boundary readers across both step types' do
      _article, _create, draft, published, = create_history
      diff = PaperTrailDiff::Diff.new
      step = PaperTrailDiff::Step.new(
        from_version: draft,
        to_version: published,
        diff: diff
      )
      activity_step = PaperTrailDiff::ActivityStep.new(
        from_boundary: step.from_boundary,
        to_boundary: step.to_boundary,
        diff: diff
      )

      expect(step).to be_empty
      expect(activity_step).to be_empty
      expect(activity_step.from_boundary).to equal(step.from_boundary)
      expect(activity_step.to_boundary).to equal(step.to_boundary)
    end

    it 'rejects missing and reversed boundaries' do
      article, create_version, draft, published, = create_history
      other = CoreArticle.create!(title: 'Other', internal_note: 'other')

      expect { described_class.timeline(article, from: other.versions.first, to: published) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /`from`/)
      expect { described_class.timeline(article, from: published, to: create_version) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /must not follow/)
      expect { described_class.timeline(Object.new, from: draft, to: published) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /version history/)
    end

    it 'loads only the requested slice of a long root history' do
      article = CoreArticle.create!(title: 'Version 0', internal_note: 'stable')
      100.times { |index| article.update!(title: "Version #{index + 1}") }
      versions = article.versions.to_a

      instantiated = instantiated_record_count do
        steps = described_class.timeline(
          article,
          from: versions.fetch(-3),
          to: versions.fetch(-1)
        )
        expect(steps.length).to eq(2)
      end

      expect(instantiated).to be < 10
    end

    it 'selects timestamped mutations and one trailing reconstruction boundary' do
      article, create_version, draft, published, reverted = create_history
      times = timestamp_versions([create_version, draft, published, reverted])

      steps = described_class.timeline(article, within: times.fetch(1)...times.fetch(3))

      expect(steps.map(&:from_version)).to eq([draft, published])
      expect(steps.map(&:to_version)).to eq([published, reverted])
      expect(steps.map { |step| step.diff.attributes.fetch('title').to_h }).to eq(
        [
          { from: 'Draft', to: 'Published' },
          { from: 'Published', to: 'Draft' }
        ]
      )
    end

    it 'replaces configured relation ordering when selecting the trailing boundary' do
      article, create_version, draft, published, reverted = create_history
      times = timestamp_versions([create_version, draft, published, reverted])
      descending = article.versions.reorder(id: :desc)
      allow(article).to receive(:versions).and_return(descending)

      steps = described_class.timeline(article, within: times.fetch(1)...times.fetch(2))

      expect(steps.map(&:from_version)).to eq([draft])
      expect(steps.map(&:to_version)).to eq([published])
      expect(steps.first.diff.attributes.fetch('title').to_h)
        .to eq(from: 'Draft', to: 'Published')
    end

    it 'includes every tied timestamp through an inclusive end' do
      article, create_version, draft, published, reverted = create_history
      start_at = Time.utc(2030, 2, 1)
      timestamp_versions([create_version], start_at: start_at - 3600)
      timestamp_versions([draft, published], start_at: start_at)
      published.update_columns(created_at: start_at)
      timestamp_versions([reverted], start_at: start_at + 3600)

      steps = described_class.timeline(
        article,
        within: start_at..start_at
      )

      expect(steps.map(&:from_version)).to eq([draft, published])
      expect(steps.last.to_version).to eq(reverted)
    end

    it 'resolves symbolic boundaries to the record own earliest and latest versions' do
      article, create_version, _draft, _published, reverted = create_history

      symbolic = described_class.timeline(article, from: :first, to: :last)
      explicit = described_class.timeline(article, from: create_version, to: reverted)

      expect(symbolic.map(&:to_h)).to eq(explicit.map(&:to_h))
      # Resolved independently of the order the versions association happens to
      # use, which a caller is free to change.
      allow(article).to receive(:versions).and_return(article.versions.reorder(id: :desc))
      expect(described_class.timeline(article, from: :first, to: :last).map(&:to_h))
        .to eq(explicit.map(&:to_h))
    end

    it 'treats a record with no versions as an empty history rather than an error' do
      bare = PaperTrail.request(enabled: false) do
        CoreArticle.create!(title: 'Untracked', internal_note: 'none')
      end

      expect(bare.versions).to be_empty
      expect(described_class.timeline(bare, from: :first, to: :last)).to eq([])
      expect(described_class.activity_timeline(bare, from: :first, to: :last)).to eq([])
      analysis = described_class.analyze(bare, from: :first, to: :last, activity: true)
      expect(analysis.timeline).to eq([])
      expect(analysis.activity_timeline).to eq([])
      expect(analysis.diff).to be_empty
    end

    it 'rejects an unknown boundary symbol and a reversed symbolic range' do
      article, = create_history

      expect { described_class.timeline(article, from: :beginning, to: :last) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /unsupported boundary/)
      expect { described_class.timeline(article, from: :last, to: :first) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /must not follow/)
      window = Time.utc(2030, 1, 1)..Time.utc(2030, 1, 2)
      expect { described_class.timeline(article, from: :first, within: window) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /cannot be combined/)
    end

    it 'accepts a window that closes on the record being destroyed' do
      article, create_version, draft, published, reverted = create_history
      article.destroy!
      destroy_version = PaperTrail::Version
                        .where(item_type: 'CoreArticle', item_id: article.id).order(:id).last
      times = timestamp_versions(
        [create_version, draft, published, reverted, destroy_version]
      )

      steps = described_class.timeline(article, within: times.first..times.last)
      selected = [create_version, draft, published, reverted, destroy_version]

      # No later root version can ever exist, so demanding one would reject this
      # window permanently. The checkpoint timeline still reports edits only.
      expect(steps.map { |step| [step.from_version.id, step.to_version.id] })
        .to eq(selected.each_cons(2).map { |from, to| [from.id, to.id] })
      expect(steps.map { |step| step.to_boundary.kind }).to all(eq(:version))
    end

    it 'returns no steps when a time range contains no root versions' do
      article, create_version, draft, published, reverted = create_history
      times = timestamp_versions([create_version, draft, published, reverted])

      steps = described_class.timeline(
        article,
        within: (times.first - 7200)...(times.first - 3600)
      )

      expect(steps).to eq([])
      expect(steps).to be_frozen
    end

    it 'rejects invalid, mixed, and historically incomplete time ranges' do
      article, create_version, draft, published, reverted = create_history
      times = timestamp_versions([create_version, draft, published, reverted])

      expect { described_class.timeline(article) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /provide both/)
      expect do
        described_class.timeline(
          article,
          from: draft,
          to: published,
          within: times.fetch(1)...times.fetch(2)
        )
      end.to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /cannot be combined/)
      expect { described_class.timeline(article, within: 1..2) }
        .to raise_error(PaperTrailDiff::InvalidTimeRangeError, /time-like/)
      expect { described_class.timeline(article, within: times.fetch(2)..times.fetch(1)) }
        .to raise_error(PaperTrailDiff::InvalidTimeRangeError, /must not follow/)
      expect { described_class.timeline(article, within: times.last..times.last) }
        .to raise_error(PaperTrailDiff::IncompleteTimeRangeError, /later root version/)
    end
  end

  describe '.activity_timeline' do
    it 'matches the root timeline when no descendant paths are selected' do
      article, _create, draft, _published, reverted = create_history

      activity = described_class.activity_timeline(article, from: draft, to: reverted)
      timeline = described_class.timeline(article, from: draft, to: reverted)

      expect(activity.map { |step| step.diff.to_h }).to eq(timeline.map { |step| step.diff.to_h })
      expect(activity.first.from_boundary.to_h).to include(
        kind: :version,
        version_id: draft.id,
        item_type: 'CoreArticle'
      )
      expect(activity).to be_frozen
    end

    it 'adds an explicit current boundary without requiring another root version' do
      article, _create, _draft, _published, current_before = create_history

      steps = described_class.activity_timeline(article, from: current_before, to: article)
      step = steps.fetch(0)

      expect(step.from_boundary.kind).to eq(:version)
      expect(step.to_boundary.to_h).to include(
        kind: :current,
        version_id: nil,
        item_type: 'CoreArticle',
        item_id: article.id
      )
      expect(step.to_boundary).to be_current
      expect(step.to_boundary).not_to be_version
      expect(step.to_boundary.record.to_h).to eq(
        type: 'CoreArticle', id: article.id
      )
      expect(step.to_boundary.event).to be_nil
      expect(step.to_boundary.whodunnit).to be_nil
      expect(step).not_to be_empty
      expect(step.diff.attributes.fetch('internal_note').to_h)
        .to eq(from: 'stable', to: 'changed')
      expect(step.to_h.keys).to eq(%i[from to diff])
    end

    it 'closes a destroyed root with an explicit removal step' do
      article, create_version, = create_history
      final_state = article.attributes.slice('title', 'internal_note')
      article.destroy!
      destroy_version = PaperTrail::Version
                        .where(item_type: 'CoreArticle', item_id: article.id).order(:id).last

      steps = described_class.activity_timeline(
        article, from: create_version, to: destroy_version
      )
      removal = steps.last

      # The boundary built from the destroy version still holds the record,
      # because a version records the state before its own event.
      expect(removal.from_boundary.to_h).to include(
        kind: :version, version_id: destroy_version.id, item_type: 'CoreArticle'
      )
      # Identity matches the version boundary it follows, not the current-record
      # boundary, so the two ends of the removal step agree.
      expect(removal.to_boundary.to_h).to include(
        kind: :destroyed, version_id: destroy_version.id, item_type: 'CoreArticle',
        item_id: destroy_version.item_id
      )
      expect(removal.to_boundary.item_id).to eq(removal.from_boundary.item_id)
      expect(removal.to_boundary).to be_destroyed
      expect(removal.to_boundary).not_to be_version
      expect(removal.to_boundary).not_to be_current
      expect(removal.to_boundary.event).to eq('destroy')
      # The removed snapshot is the state the record held when it was deleted.
      change = removal.diff.record_presence_change
      expect(change.to).to be_nil
      expect(change.from.attributes).to include(final_state)
      expect(removal).not_to be_empty
    end

    it 'closes a destroyed root only once, and leaves a live history unchanged' do
      article, create_version, _draft, _published, reverted = create_history

      live = described_class.activity_timeline(article, from: create_version, to: reverted)
      expect(live.map { |step| step.to_boundary.kind }).to all(eq(:version))

      article.destroy!
      destroy_version = PaperTrail::Version
                        .where(item_type: 'CoreArticle', item_id: article.id).order(:id).last
      destroyed = described_class.activity_timeline(
        article, from: create_version, to: destroy_version
      )
      analysis = described_class.analyze(
        article, from: create_version, to: destroy_version, activity: true
      )

      expect(destroyed.count { |step| step.to_boundary.destroyed? }).to eq(1)
      # `analyze` must not disagree with the standalone timeline.
      expect(analysis.activity_timeline.map(&:to_h)).to eq(destroyed.map(&:to_h))
      # The endpoint diff and root timeline keep their `compare` semantics.
      expect(analysis.timeline.map { |step| step.to_boundary.kind }).to all(eq(:version))
    end

    it 'closes a destroyed root selected by a time window' do
      article, create_version, draft, published, reverted = create_history
      article.destroy!
      destroy_version = PaperTrail::Version
                        .where(item_type: 'CoreArticle', item_id: article.id).order(:id).last
      times = timestamp_versions(
        [create_version, draft, published, reverted, destroy_version]
      )

      covering = described_class.activity_timeline(article, within: times.first..times.last)
      trailing_only = described_class.activity_timeline(
        article, within: times.first..times.fetch(3)
      )

      expect(covering.last.to_boundary).to be_destroyed
      expect(covering.count { |step| step.to_boundary.destroyed? }).to eq(1)
      expect(covering.last.diff.record_presence_change.to).to be_nil
      # In the shorter window the destroy is only reconstruction context, so it
      # must not be reported as a selected mutation.
      expect(trailing_only.map { |step| step.to_boundary.kind }).to all(eq(:version))
    end

    it 'rejects an unsaved current boundary and a non-version starting boundary' do
      article, _create, _draft, _published, current_before = create_history
      article.title = 'Unsaved'

      expect do
        described_class.activity_timeline(article, from: current_before, to: article)
      end.to raise_error(PaperTrailDiff::InvalidEndpointError, /unsaved/)

      article.restore_attributes
      expect do
        described_class.activity_timeline(article, from: article, to: article)
      end.to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /root PaperTrail version/)
    end
  end

  describe '.analyze' do
    it 'builds the endpoint diff and timeline from the same selected history' do
      article, _create, draft, published, reverted = create_history

      result = described_class.analyze(article, from: draft, to: reverted)

      expect(result).to be_frozen
      expect(result.diff).to be_empty
      expect(result.timeline.map(&:from_version)).to eq([draft, published])
      expect(result.timeline.map(&:to_version)).to eq([published, reverted])
      expect(result.to_h.keys).to eq(%i[diff timeline])
    end

    it 'optionally includes an activity timeline built by the same adapter' do
      article, _create, draft, _published, reverted = create_history

      result = described_class.analyze(
        article,
        from: draft,
        to: reverted,
        activity: true
      )

      expect(result.activity_timeline).to be_frozen
      expect(result.activity_timeline.map { |step| step.diff.to_h })
        .to eq(result.timeline.map { |step| step.diff.to_h })
      expect(result.to_h.keys).to eq(%i[diff timeline activity_timeline])
    end

    it 'builds endpoint and timeline results for a wall-clock range' do
      article, create_version, draft, published, reverted = create_history
      times = timestamp_versions([create_version, draft, published, reverted])

      result = described_class.analyze(
        article,
        within: times.fetch(1)...times.fetch(3),
        activity: true
      )

      expect(result.diff).to be_empty
      expect(result.timeline.map(&:from_version)).to eq([draft, published])
      expect(result.activity_timeline.map { |step| step.from_boundary.version_id })
        .to eq([draft.id, published.id])
    end
  end

  describe '.association_paths' do
    it 'validates the model and maximum depth' do
      expect { described_class.association_paths(Object.new) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /ActiveRecord/)
      expect { described_class.association_paths(CoreArticle, max_depth: 0) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /positive integer/)
    end
  end

  describe '.diagnose' do
    it 'returns a clean immutable report when no associations are selected' do
      _article, _create, draft, published, = create_history

      report = described_class.diagnose(draft, published)

      expect(report).to be_frozen
      expect(report).to be_ok
      expect(report.to_h).to eq(ok: true, issues: [])
    end

    it 'reports unavailable association tracking without raising' do
      _article, _create, draft, published, = create_history

      report = described_class.diagnose(draft, published, associations: [:comments])

      expect(report).not_to be_ok
      expect(report.errors.map(&:code)).to eq([:association_tracking_unavailable])
      expect(report.warnings).to be_empty
    end

    it 'rejects endpoints from different records' do
      _article, _create, draft, = create_history
      other = CoreArticle.create!(title: 'Other', internal_note: 'other')

      expect { described_class.diagnose(draft, other.versions.first) }
        .to raise_error(PaperTrailDiff::VersionMismatchError, /same PaperTrail item/)
    end
  end
end
