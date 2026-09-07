# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'bounded historical filtering' do
  before do
    PaperTrail::Version.delete_all
    CoreArticle.delete_all
  end

  def report(filter, budget: 100)
    PaperTrailDiff.analyze_scope(
      CoreArticle, limit: 10, within: (Time.now.utc - 3600)..(Time.now.utc + 60),
                   close_on: :current, historical_filter: filter, max_filter_versions: budget
    )
  end

  it 'rejects a nonmatching population before reconstructing beyond the version budget' do
    5.times { CoreArticle.create!(title: 'Other', internal_note: 'stable') }
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)

    expect { report(->(_state) { false }, budget: 3) }
      .to raise_error(PaperTrailDiff::FilterLimitExceededError, /max_filter_versions: 3/)
  end

  it 'applies the version budget across candidate batches, not separately per batch' do
    251.times { CoreArticle.create!(title: 'Other', internal_note: 'stable') }

    expect { report({ title: 'Missing' }, budget: 250) }
      .to raise_error(PaperTrailDiff::FilterLimitExceededError)
  end

  it 'does not reify nonmatching states for an attribute hash' do
    5.times do
      article = CoreArticle.create!(title: 'Other', internal_note: 'stable')
      article.update!(title: 'Still other')
    end
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)

    expect(report({ title: 'Missing' }).analyses).to be_empty
  end

  it 'preserves pre-event semantics and includes matching deleted identities' do
    moved = CoreArticle.create!(title: 'Match', internal_note: 'stable')
    moved.update!(title: 'Now different')
    final = CoreArticle.create!(title: 'Other', internal_note: 'stable')
    final.update!(title: 'Match')
    deleted = CoreArticle.create!(title: 'Match', internal_note: 'stable')
    deleted.destroy!

    result = report({ title: 'Match' })

    expect(result.roots.map(&:id)).to eq([moved.id])
    expect(result.unreachable).to eq([PaperTrailDiff::Endpoint.identity(deleted)])
  end

  it 'rejects unknown or unrecorded attributes instead of treating them as nil' do
    article = CoreArticle.create!(title: 'First', internal_note: 'stable')
    article.update!(title: 'Last')
    version = article.versions.order(:id).last
    attributes = version.object_deserialized.except('internal_note')
    version.update_column(:object, PaperTrail.serializer.dump(attributes))

    expect do
      report({ unknown: nil })
    end.to raise_error(PaperTrailDiff::ConfigurationError, /unknown/)
    expect { report({ internal_note: nil }) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /was not recorded/)
  end

  it 'rejects invalid filters and unbounded budgets before scanning' do
    expect { report(false) }.to raise_error(PaperTrailDiff::ConfigurationError, /must respond/)
    expect do
      report({}, budget: nil)
    end.to raise_error(PaperTrailDiff::ConfigurationError, /positive/)
  end
end
