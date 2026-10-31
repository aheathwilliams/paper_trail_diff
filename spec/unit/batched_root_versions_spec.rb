# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::BatchedRootVersions do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # A create and two updates, at the given minutes past the start.
  def history(model = FilterArticle, minutes: [0, 1, 2])
    article = model.create!(title: 'Draft')
    %w[Review Published].each { |title| article.update!(title: title) }
    versions = FilterVersion.where(item_id: article.id).order(:id).to_a
    versions.zip(minutes) do |version, minute|
      version.update_columns(created_at: start_time + (minute * 60))
    end
    [article, *versions]
  end

  def at(minute)
    start_time + (minute * 60)
  end

  def select(records, within: nil, version_scope: nil, live_endpoints: nil, context_required: false, # rubocop:disable Metrics/ParameterLists
             windows: {})
    described_class.new(
      records, time_range: within && PaperTrailDiff::TimeRange.new(within),
               version_scope: version_scope, live_endpoints: live_endpoints,
               context_required: context_required,
               windows: windows.transform_values { |range| PaperTrailDiff::TimeRange.new(range) }
    ).call
  end

  def key(record)
    ['FilterArticle', record.id.to_s]
  end

  it 'selects nothing for no records' do
    expect(select([])).to eq({})
  end

  it "selects each record's whole history oldest first, keyed by base class and id" do
    article, *article_versions = history
    feature, *feature_versions = history(FilterFeature, minutes: [2, 0, 1])

    plans = select([article, feature])

    expect(plans.keys).to eq([key(article), key(feature)])
    expect(plans.fetch(key(article)).versions).to eq(article_versions)
    expect(plans.fetch(key(feature)).versions).to eq(feature_versions.rotate)
  end

  it "reads only the batch's own versions" do
    article, *article_versions = history
    FilterVersion.insert({ item_type: 'FilterNote', item_id: article.id, event: 'update',
                           created_at: at(1) })

    expect(select([article]).fetch(key(article)).versions).to eq(article_versions)
  end

  it 'gives a record with no versions an empty plan' do
    article, = history
    FilterVersion.delete_all

    expect(select([article]).fetch(key(article))).to be_empty
  end

  it 'selects the versions in a window and the next one to close on' do
    article, _created, reviewed, published = history
    other, other_created, = history(minutes: [5, 6, 7])

    plans = select([article, other], within: at(1)...at(2), context_required: true)

    expect(plans.fetch(key(article)).versions).to eq([reviewed, published])
    expect(plans.fetch(key(article)).context_version).to eq(published)
    expect(plans.fetch(key(article)).reconstruction_versions).to eq([reviewed, published])
    expect(plans.fetch(key(other)).versions).to eq([other_created])
    expect(plans.fetch(key(other)).mutations).to eq([])
  end

  it 'gives a record with nothing in the window an empty plan unless context is required' do
    article, = history

    expect(select([article], within: at(5)..at(6)).fetch(key(article))).to be_empty
  end

  describe 'with windows moved to transaction edges' do
    it "reads each moved root's versions from its own window" do
      article, created, reviewed, = history
      other, _other_created, other_reviewed, = history

      plans = select([article, other], within: at(0.5)..at(1.5),
                                       windows: { key(article) => at(0)...at(1) })

      expect(plans.fetch(key(article)).mutations).to eq([created])
      expect(plans.fetch(key(article)).context_version).to eq(reviewed)
      expect(plans.fetch(key(other)).mutations).to eq([other_reviewed])
    end

    it 'closes a moved window on the version after the shared window when none is in it' do
      article, created, reviewed, = history

      plan = select([article], within: at(0.5)...at(1),
                               windows: { key(article) => at(0)...at(0.75) })
             .fetch(key(article))

      expect(plan.mutations).to eq([created])
      expect(plan.context_version).to eq(reviewed)
    end

    it 'reads from the earliest of several moved starts' do
      article, created, = history
      other, = history

      plans = select([article, other], within: at(0.5)..at(0.75),
                                       windows: { key(article) => at(0)..at(0.75),
                                                  key(other) => at(0.25)..at(0.75) },
                                       context_required: true)

      expect(plans.fetch(key(article)).mutations).to eq([created])
      expect(plans.fetch(key(other)).mutations).to eq([])
    end

    it 'closes on the nearest version past a moved end, not one before its moved start' do
      article, = history(minutes: [0, 1.75, 2])
      _, *later = FilterVersion.where(item_id: article.id).order(:created_at).to_a
      other, = history(minutes: [5, 6, 7])

      plans = select([article, other], within: at(0.5)..at(2.5), context_required: true,
                                       windows: { key(article) => at(0.25)...at(1.5),
                                                  key(other) => at(0)..at(2.5) })

      expect(plans.fetch(key(article)).context_version).to eq(later.first)
    end

    it 'leaves a moved window with nothing in or after it empty' do
      article, = history

      plan = select([article], within: at(5)..at(6), windows: { key(article) => at(4)...at(5) })
             .fetch(key(article))

      expect(plan).to be_empty
    end

    it 'keeps an exclusive end when widening the read for a moved start' do
      article, created, reviewed, published = history

      plan = select([article], within: at(1)...at(2), windows: { key(article) => at(0)...at(2) })
             .fetch(key(article))

      expect(plan.mutations).to eq([created, reviewed])
      expect(plan.context_version).to eq(published)
    end

    it 'keeps an inclusive end when widening the read for a moved start' do
      article, created, reviewed, published = history

      plan = select([article], within: at(0.5)..at(1), windows: { key(article) => at(0)..at(1) })
             .fetch(key(article))

      expect(plan.mutations).to eq([created, reviewed])
      expect(plan.context_version).to eq(published)
    end
  end

  describe 'with a version scope' do
    it 'applies the scope once, to the window across every record in the batch' do
      article, _created, reviewed, published = history
      other, = history(minutes: [5, 6, 7])
      history(minutes: [0, 1, 1.5])
      latest = ->(versions) { versions.reorder(created_at: :desc).limit(1) }

      plans = select([article, other], within: at(0)..at(1.5), version_scope: latest)

      expect(plans.fetch(key(article)).mutations).to eq([reviewed])
      expect(plans.fetch(key(article)).context_version).to eq(published)
      expect(plans.fetch(key(other))).to be_empty
    end

    it 'bounds each selected version by the one after it, not by the next selected' do
      article, created, reviewed, published = history
      skip_review = ->(versions) { versions.where.not(id: reviewed.id) }

      plan = select([article], version_scope: skip_review).fetch(key(article))

      expect(plan.mutations).to eq([created, published])
      expect(plan.steps).to eq([[created, reviewed]])
    end
  end

  describe 'closing on current state' do
    it 'closes on the loaded record for each key, or the record itself' do
      article, *, published = history
      other, = history
      loaded = FilterArticle.find(article.id)

      plans = select([article, other], live_endpoints: { key(article) => loaded })

      expect(plans.fetch(key(article)).closing_record).to equal(loaded)
      expect(plans.fetch(key(article)).steps.last).to eq([published, loaded])
      expect(plans.fetch(key(other)).closing_record).to equal(other)
    end

    it 'does not close on a destroyed record' do
      article, = history
      article.destroy!
      FilterVersion.where(event: 'destroy').delete_all

      expect(select([article], live_endpoints: {}).fetch(key(article)).closing_record).to be_nil
    end

    it 'closes an empty window on the live record when context is required' do
      article, = history

      plans = select([article], within: at(5)..at(6), live_endpoints: {}, context_required: true)
      plan = plans.fetch(key(article))

      expect(plan.closing_record).to equal(article)
      expect(plan.versions).to eq([])
    end

    it 'cannot close a whole history with no versions on the live record' do
      article, = history
      FilterVersion.delete_all

      expect { select([article], live_endpoints: {}, context_required: true) }
        .to raise_error(PaperTrailDiff::IncompleteTimeRangeError)
    end
  end
end
