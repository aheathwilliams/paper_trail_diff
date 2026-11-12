# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::RootVersionSelection do
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # The record, then its create and four updates a minute apart.
  def history
    article = FilterArticle.create!(title: 'Draft')
    %w[Review Edited Published Archived].each { |title| article.update!(title: title) }
    versions = FilterVersion.where(item_id: article.id).order(:id).to_a
    versions.each_with_index do |version, index|
      version.update_columns(created_at: Time.utc(2032, 1, 1, 12) + (index * 60))
    end
    [article, *versions]
  end

  # The record's destroy, a minute after its last update.
  def destroy(article)
    article.destroy!
    version = FilterVersion.where(item_id: article.id).order(:id).last
    version.tap { version.update_columns(created_at: Time.utc(2032, 1, 1, 12, 5)) }
  end

  def select(in_range, selected: in_range, after: nil, windowed: false, **options)
    described_class.new(in_range: in_range, selected: selected, after_range: after,
                        windowed: windowed, **options).call
  end

  def described(plan)
    { versions: plan.versions, steps: plan.steps, context: plan.context_version,
      replayed: plan.reconstruction_versions, closing: plan.closing_record,
      mutations: plan.mutations, destroy: plan.closes_on_destroy }
  end

  describe 'without a filter' do
    it 'pairs adjacent versions, in time order whatever order they come in' do
      _article, created, reviewed, edited = history

      plan = select([edited, created, reviewed], selected: [reviewed, edited, created])

      expect(described(plan)).to eq(
        versions: [created, reviewed, edited], steps: [[created, reviewed], [reviewed, edited]],
        context: nil, replayed: [created, reviewed, edited], closing: nil,
        mutations: [created, reviewed, edited], destroy: false
      )
    end

    it 'keeps a lone version that nothing reveals' do
      _article, created, = history

      expect(described(select([created]))).to include(versions: [created], steps: [])
    end

    it 'reveals the last version from the one after the range, as context' do
      _article, created, reviewed, edited = history

      plan = select([created, reviewed], after: edited, windowed: true)

      expect(described(plan)).to include(
        versions: [created, reviewed, edited], steps: [[created, reviewed], [reviewed, edited]],
        context: edited, mutations: [created, reviewed]
      )
    end

    it 'reveals the last version from the live record when nothing came after' do
      article, created, reviewed = history

      plan = select([created, reviewed], live_endpoint: article, windowed: true)

      expect(described(plan)).to include(
        versions: [created, reviewed], steps: [[created, reviewed], [reviewed, article]],
        context: nil, closing: article, mutations: [created, reviewed]
      )
    end

    it 'prefers the version after the range to the live record' do
      article, created, reviewed = history

      plan = select([created], after: reviewed, live_endpoint: article)

      expect([plan.steps, plan.closing_record]).to eq([[[created, reviewed]], nil])
    end

    it 'refuses a window with nothing after it, unless its last version is a destroy' do
      article, created, reviewed = history
      destroyed = destroy(article)

      expect { select([created, reviewed], windowed: true) }
        .to raise_error(PaperTrailDiff::IncompleteTimeRangeError, described_class::INCOMPLETE)
      expect(select([created, reviewed]).closes_on_destroy).to be(false)
      expect(described(select([reviewed, destroyed], windowed: true)))
        .to include(steps: [[reviewed, destroyed]], destroy: true)
    end
  end

  describe 'with a filter' do
    # The step of a selected version ends where it was revealed, not at the
    # next selected version, so an edit reads the same whatever follows it.
    it 'bounds each selected version by the one right after it' do
      _article, created, reviewed, edited, published = history

      plan = select([published, edited, created, reviewed], selected: [edited, created])

      expect(described(plan)).to eq(
        versions: [created, reviewed, edited, published],
        steps: [[created, reviewed], [edited, published]], context: published,
        replayed: [created, reviewed, edited, published], closing: nil,
        mutations: [created, edited], destroy: false
      )
    end

    # The versions in range are in order, so the one after each selected
    # version is found by a search rather than by passing every version.
    it 'finds the version after each selected one with a search' do
      versions = Array.new(256) do |index|
        FilterVersion.new(id: index + 1, event: 'update', created_at: Time.utc(2032, 1, 1) + index)
      end
      selected = versions.each_slice(2).map(&:first)
      allow(PaperTrailDiff::Support).to receive(:compare_versions).and_call_original

      plan = select(versions, selected: selected)

      expect(plan.steps).to eq(versions.each_slice(2).to_a)
      expect(PaperTrailDiff::Support).to have_received(:compare_versions).at_most(256 * 8).times
    end

    # Outside a window, the range ends at its last version, so nothing in it
    # reveals that version's own change.
    it 'leaves out of the steps a last selected version nothing reveals' do
      _article, created, reviewed, edited = history

      plan = select([created, reviewed, edited], selected: [created, edited])

      expect(described(plan)).to include(versions: [created, reviewed],
                                         steps: [[created, reviewed]],
                                         mutations: [created, edited], destroy: false)
      expect(described(select([created, reviewed, edited], selected: [edited])))
        .to include(versions: [], steps: [], replayed: [], mutations: [edited])
    end

    it 'reveals the last selected version from the version after it, wherever it lies' do
      article, created, reviewed, edited, published = history

      in_range = select([created, reviewed, edited], selected: [reviewed])
      after = select([created, reviewed], selected: [created], after: published)
      past = select([created, reviewed, edited], selected: [edited], after: published)
      live = select([created, reviewed, edited], selected: [edited], live_endpoint: article)

      expect(described(in_range)).to include(steps: [[reviewed, edited]], context: edited,
                                             versions: [reviewed, edited], mutations: [reviewed])
      expect(described(after)).to include(steps: [[created, reviewed]], context: reviewed)
      expect(described(past)).to include(steps: [[edited, published]], context: published,
                                         versions: [edited, published])
      expect(described(live)).to include(steps: [[edited, article]], context: nil,
                                         closing: article, versions: [edited])
    end

    # A forward replay that skipped the versions left out would carry a
    # stale state into the next reported step.
    it 'replays every version between the first boundary and the last' do
      _article, created, reviewed, edited, published, archived = history

      plan = select([created, reviewed, edited, published], selected: [created, published],
                                                            after: archived)

      expect(described(plan)).to include(
        versions: [created, reviewed, published, archived],
        steps: [[created, reviewed], [published, archived]],
        replayed: [created, reviewed, edited, published, archived], context: archived
      )
      expect(select([created, reviewed, edited, published, archived], selected: [reviewed])
               .reconstruction_versions).to eq([reviewed, edited])
    end

    it 'names a version once when one step ends where the next begins' do
      _article, created, reviewed, edited, published = history

      plan = select([created, reviewed, edited, published], selected: [created, reviewed])

      expect(described(plan)).to include(versions: [created, reviewed, edited],
                                         replayed: [created, reviewed, edited])
    end

    it 'keeps a selected destroy as a boundary, closing a window on it' do
      article, created, reviewed = history
      destroyed = destroy(article)

      plan = select([created, reviewed, destroyed], selected: [created, destroyed], windowed: true)

      expect(described(plan)).to include(
        versions: [created, reviewed, destroyed], steps: [[created, reviewed]],
        mutations: [created, destroyed], destroy: true
      )
    end

    it 'replays every version in range as a whole plan, reporting the selected ones' do
      _article, created, reviewed, edited = history

      plan = select([created, reviewed, edited], selected: [reviewed], whole: true)

      expect(described(plan)).to include(
        versions: [created, reviewed, edited], steps: [[created, reviewed], [reviewed, edited]],
        mutations: [reviewed]
      )
    end
  end

  describe 'with nothing selected' do
    it 'plans nothing unless a context is needed' do
      _article, created, = history

      expect(described(select([created], selected: [], after: created)))
        .to eq(described(PaperTrailDiff::RootVersionPlan.empty))
    end

    it 'reads the context from the version after the range' do
      article, created, reviewed = history

      plan = select([created], selected: [], after: reviewed, windowed: true,
                               context_required: true, live_endpoint: article)

      expect(described(plan)).to include(versions: [reviewed], context: reviewed, mutations: [])
    end

    it 'closes a window on the live record when nothing came after it' do
      article, created, = history

      plan = select([created], selected: [], windowed: true,
                               context_required: true, live_endpoint: article)

      expect(described(plan)).to include(versions: [], closing: article)
    end

    it 'refuses a range of versions when a context is needed and there is none to read' do
      article, created, = history

      expect { select([created], selected: [], context_required: true, live_endpoint: article) }
        .to raise_error(PaperTrailDiff::IncompleteTimeRangeError, described_class::INCOMPLETE)
    end

    # The root was gone before the window began.
    it 'reads nothing for a window with no version after it and no live record' do
      _article, created, = history

      plan = select([created], selected: [], context_required: true, windowed: true)

      expect([plan.empty?, plan.closing_record]).to eq([true, nil])
    end
  end
end
