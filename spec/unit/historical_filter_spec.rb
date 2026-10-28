# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::HistoricalFilter do
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  def filter(predicate, within: nil, limit: 10, max_versions: 100, model: FilterArticle)
    time_range = within && PaperTrailDiff::TimeRange.new(within)
    described_class.new(model, predicate: predicate, time_range: time_range,
                               limit: limit, max_versions: max_versions)
  end

  def matches(predicate, articles, **options)
    filter(predicate, **options).call(articles.map { |article| article.id.to_s })
  end

  def record_version(article, event, object, **attributes)
    FilterVersion.create!(item_type: 'FilterArticle', item_id: article.id, event: event,
                          object: object&.to_yaml, created_at: Time.now, **attributes)
  end

  # Selects run while the block runs, and versions loaded per query.
  def queries(&block)
    selects = []
    loaded = []
    count_select = lambda do |*, payload|
      selects << payload[:sql] if payload[:sql].start_with?('SELECT') && payload[:name] != 'SCHEMA'
    end
    count_loaded = lambda do |*, payload|
      loaded << payload[:record_count] if payload[:class_name] == 'FilterVersion'
    end
    ActiveSupport::Notifications.subscribed(count_select, 'sql.active_record') do
      ActiveSupport::Notifications.subscribed(count_loaded, 'instantiation.active_record', &block)
    end
    [selects, loaded]
  end

  # Draft until `edited`, Review until `published`, then Published.
  def history(model = FilterArticle)
    article = model.create!(title: 'Draft')
    created = Time.now
    article.update!(title: 'Review')
    edited = Time.now
    article.update!(title: 'Published')
    published = Time.now
    [article, created, edited, published]
  end

  describe 'with an attribute hash' do
    it 'matches the state at the start of the window' do
      article, created, edited, = history

      expect(matches({ title: 'Draft' }, [article], within: created..edited))
        .to eq([article.id.to_s])
    end

    it 'matches the state after the last change, read from the next version' do
      article, created, edited, = history

      expect(matches({ 'title' => 'Review' }, [article], within: created..edited))
        .to eq([article.id.to_s])
      expect(matches({ title: 'Published' }, [article], within: created..edited)).to eq([])
    end

    it 'matches the state after the last change, read from the live row' do
      article, _created, edited, published = history

      expect(matches({ title: 'Published' }, [article], within: edited..published))
        .to eq([article.id.to_s])
      expect(matches({ title: 'Published' }, [article], within: published..Time.now))
        .to eq([article.id.to_s])
    end

    it 'checks the live row too, and needs every attribute to agree there' do
      article, _created, _edited, published = history

      expect(matches({ title: 'Other' }, [article], within: published..Time.now)).to eq([])
      expect(matches({ title: 'Published', views: 1 }, [article], within: published..Time.now))
        .to eq([])
    end

    it 'reads the live row past its default scope' do
      article, _created, _edited, published = history
      article.update_column(:hidden, 1)

      expect(matches({ title: 'Published' }, [article], within: published..Time.now))
        .to eq([article.id.to_s])
    end

    it 'matches only the states held, when every attribute agrees' do
      article, created, edited, = history

      expect(matches({ title: 'Draft', views: 0 }, [article], within: created..edited))
        .to eq([article.id.to_s])
      expect(matches({ title: 'Draft', views: 1 }, [article], within: created..edited)).to eq([])
    end

    it 'reads every version when there is no window' do
      article, = history

      expect(matches({ title: 'Draft' }, [article])).to eq([article.id.to_s])
      expect(matches({ title: 'Published' }, [article])).to eq([article.id.to_s])
    end

    it 'has no state after a destroy in the window' do
      article = FilterArticle.create!(title: 'Draft')
      start = Time.now
      article.destroy!

      expect(matches({ title: 'Draft' }, [article], within: start..Time.now))
        .to eq([article.id.to_s])
      expect(matches({ title: 'Other' }, [article], within: start..Time.now)).to eq([])
    end

    it 'has no state after a destroy, even if the row comes back outside PaperTrail' do
      article = FilterArticle.create!(title: 'Draft')
      start = Time.now
      # The destroy has the lower id but the later time, so time decides.
      record_version(article, 'update', { 'id' => article.id, 'title' => 'Draft' }, id: 1000)
      record_version(article, 'destroy', { 'id' => article.id, 'title' => 'Draft' }, id: 999)
      finish = Time.now
      PaperTrail.request(enabled: false) { article.update!(title: 'Restored') }

      expect(matches({ title: 'Restored' }, [article], within: start..finish)).to eq([])
    end

    it 'casts recorded values to the column type' do
      article = FilterArticle.create!(title: 'Draft')
      start = Time.now
      record_version(article, 'update', { 'id' => article.id, 'title' => 'Draft', 'views' => '3' })

      expect(matches({ views: 3 }, [article], within: start..Time.now)).to eq([article.id.to_s])
    end

    it 'keeps candidates in the order given, and looks past ones that do not match' do
      first, = history
      second, = history
      other = FilterArticle.create!(title: 'Other')

      expect(matches({ title: 'Published' }, [second, other, first]))
        .to eq([second.id.to_s, first.id.to_s])
    end

    it 'accepts an indifferent-access hash' do
      article, = history

      predicate = { 'title' => 'Draft' }.with_indifferent_access

      expect(matches(predicate, [article])).to eq([article.id.to_s])
    end

    it 'keeps its own copy of the expected values' do
      article, = history
      title = +'Draft'
      copied = filter({ title: title })
      title.replace('Other')

      expect(copied.call([article.id.to_s])).to eq([article.id.to_s])
    end

    it 'reads an STI subclass from its base class history' do
      feature, created, edited, = history(FilterFeature)

      expect(matches({ title: 'Draft' }, [feature], model: FilterFeature)).to eq([feature.id.to_s])
      expect(matches({ title: 'Review' }, [feature], within: created..edited, model: FilterFeature))
        .to eq([feature.id.to_s])
    end

    it 'reads only the candidates own versions' do
      article, created, edited, = history
      neighbour, = history
      # Another model's version for the same id, the first thing after the window.
      FilterVersion.insert({ item_type: 'FilterNote', item_id: article.id, event: 'update',
                             object: { 'id' => article.id, 'title' => 'Ghost' }.to_yaml,
                             created_at: edited })

      expect(matches({ title: 'Ghost' }, [article], within: created...edited)).to eq([])
      # Its own update in the window and the next one; nothing of the neighbour's.
      expect(matches({ title: 'Draft' }, [article], within: created..edited, max_versions: 2))
        .to eq([article.id.to_s])
      expect(neighbour.versions.count).to eq(3)
    end
  end

  describe 'with a callable' do
    it 'calls it with a detached copy of each recorded state' do
      article, created, edited, = history
      seen = []
      predicate = lambda do |state|
        seen << state
        state.title[/Rev/]
      end

      expect(matches(predicate, [article], within: created..edited)).to eq([article.id.to_s])
      expect(seen.map(&:title)).to eq(%w[Draft Review])
      expect(seen).to all(be_new_record)
    end

    it 'calls it with the live record when only the live row matches' do
      article, _created, edited, published = history

      published_now = ->(state) { state.title == 'Published' }

      expect(matches(published_now, [article], within: edited..published))
        .to eq([article.id.to_s])
      expect(matches(->(_state) { false }, [article], within: published..Time.now)).to eq([])
    end

    it 'treats a truthy result as a match and a falsy one as none' do
      article, _created, edited, published = history

      expect(matches(->(state) { state.title.length }, [article], within: edited..published))
        .to eq([article.id.to_s])
      expect(matches(->(_state) {}, [article], within: edited..published)).to eq([])
    end

    it 'skips a version with no state before it' do
      article = FilterArticle.create!(title: 'Draft')

      expect(matches(lambda(&:nil?), [article])).to eq([])
    end
  end

  describe 'configuration' do
    it 'requires a callable or an attribute hash of known columns' do
      expect { filter('title') }.to raise_error(
        PaperTrailDiff::ConfigurationError,
        'historical_filter: must respond to call or be an attribute hash'
      )
      expect { filter({ colour: 'red', size: 1, title: 'x' }) }.to raise_error(
        PaperTrailDiff::ConfigurationError, 'unknown historical attributes: colour, size'
      )
    end

    it 'requires a positive Integer version budget' do
      [0, -1, 1.5, nil].each do |budget|
        expect { filter({ title: 'x' }, max_versions: budget) }.to raise_error(
          PaperTrailDiff::ConfigurationError, 'max_filter_versions: must be a positive Integer'
        )
      end
      expect(filter({ title: 'x' }, max_versions: 1)).to be_a(described_class)
    end
  end

  describe 'limits' do
    it 'stops at more matching roots than the limit' do
      articles = [history.first, history.first]

      expect(matches({ title: 'Draft' }, articles, limit: 2).length).to eq(2)
      expect { matches({ title: 'Draft' }, articles, limit: 1) }.to raise_error(
        PaperTrailDiff::BatchLimitExceededError,
        'historical_filter: matched more than 1 roots; narrow the window ' \
        'or the filter, or raise limit: to the population you intend to analyze'
      )
    end

    it 'stops at more versions than the budget, counting the version after the window' do
      article, created, edited, = history
      message = 'historical_filter: exceeds max_filter_versions: 1; ' \
                'narrow the window or explicitly increase the version budget'

      # The window holds the first update; the second update closes it.
      expect(matches({ title: 'Draft' }, [article], within: created..edited, max_versions: 2))
        .to eq([article.id.to_s])
      expect { matches({ title: 'Draft' }, [article], within: created..edited, max_versions: 1) }
        .to raise_error(PaperTrailDiff::FilterLimitExceededError, message)
    end

    it 'never loads more than one version past the remaining budget' do
      early = FilterArticle.create!(title: 'Draft')
      early.update!(title: 'Review')
      late = FilterArticle.create!(title: 'Draft')
      4.times { |index| late.update!(title: "Edit #{index}") }
      # 250 candidates fit in one batch, so `late` is read in a second one.
      fillers = Array.new(249) { |index| (10_000 + index).to_s }
      candidates = [early.id.to_s] + fillers + [late.id.to_s]
      error = nil

      _, loaded = queries do
        filter({ title: 'x' }, max_versions: 4).call(candidates)
      rescue PaperTrailDiff::FilterLimitExceededError => e
        error = e
      end

      expect(error).not_to be_nil
      expect(loaded).to eq([2, 3])
    end

    it 'skips the closing queries when nothing is left to look up' do
      destroyed = FilterArticle.create!(title: 'Draft')
      start = Time.now
      destroyed.destroy!
      article, created, edited, = history

      gone, = queries { matches({ title: 'Draft' }, [destroyed], within: start..Time.now) }
      closed, = queries { matches({ title: 'Draft' }, [article], within: created..edited) }

      expect(gone.length).to eq(1)
      expect(closed.length).to eq(2)
    end

    it 'loads only the candidates live rows' do
      article, _created, _edited, published = history
      history

      loaded = []
      count = lambda do |*, payload|
        loaded << payload[:record_count] if payload[:class_name] == 'FilterArticle'
      end
      ActiveSupport::Notifications.subscribed(count, 'instantiation.active_record') do
        matches({ title: 'Published' }, [article], within: published..Time.now)
      end

      expect(loaded).to eq([1])
    end

    it 'counts versions across every batch of candidates' do
      articles = Array.new(2) { history.first }

      expect { matches({ title: 'Draft' }, articles, max_versions: 5) }
        .to raise_error(PaperTrailDiff::FilterLimitExceededError)
      expect(matches({ title: 'Draft' }, articles, max_versions: 6).length).to eq(2)
    end
  end

  describe 'unreadable history' do
    it 'rejects an attribute the version did not record' do
      article, = history
      version = article.versions.where.not(object: nil).reorder(:id).first

      expect { matches({ hidden: 0 }, [article]) }.to raise_error(
        PaperTrailDiff::ConfigurationError,
        "historical_filter: hidden was not recorded in version #{version.id}"
      )
    end

    it 'rejects a version whose state cannot be read directly' do
      article = FilterArticle.create!(title: 'Draft')
      FilterVersion.create!(item_type: 'FilterArticle', item_id: article.id, event: 'update',
                            object: 'just text'.to_yaml, created_at: Time.now)

      expect { matches({ title: 'Draft' }, [article]) }.to raise_error(
        PaperTrailDiff::ConfigurationError,
        'historical_filter: cannot read recorded attributes directly; use a bounded callable'
      )
    end
  end
end
