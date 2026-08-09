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
