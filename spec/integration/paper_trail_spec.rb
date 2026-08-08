# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe PaperTrailDiff do
  before do
    PaperTrail::Version.delete_all
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
    end

    it 'returns an empty frozen array for equal boundaries' do
      article, _create, draft, = create_history

      result = described_class.timeline(article, from: draft, to: draft)

      expect(result).to eq([])
      expect(result).to be_frozen
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
  end
end
