# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::PreparedChildCandidates do
  let(:comments) { TrackedArticle.reflect_on_association(:comments) }
  let(:candidates) { described_class.new(nil) }
  # The owners of each read, in order.
  let(:owners_read) { [] }

  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
    allow(PaperTrailDiff::ActivityChildCandidateLoader).to receive(:new)
      .and_wrap_original do |original, model, owners, *rest|
        owners_read << owners
        original.call(model, owners, *rest)
      end
  end

  # An article with one comment, edited once.
  def article
    TrackedArticle.create!(title: 'Draft').tap do |created|
      created.comments.create!(body: 'First').update!(body: 'Edited')
    end
  end

  it "keys each owner's recorded rows and live children by its id" do
    first = article
    second = article
    comment = first.comments.first

    historical, live = candidates.call(TrackedArticle, [first.id, second.id], comments)

    expect(historical.keys).to contain_exactly(first.id.to_s, second.id.to_s)
    expect(historical.fetch(first.id.to_s).map { |row| row.first(2) })
      .to eq([[first.id, comment.id]] * 2)
    expect(live).to eq(first.id.to_s => [comment.id], second.id.to_s => [second.comments.first.id])
  end

  it 'reads each owner once, and later only the owners not read yet' do
    first = article
    second = article

    candidates.call(TrackedArticle, [first.id], comments)
    candidates.call(TrackedArticle, [first.id.to_s], comments)
    _historical, live = candidates.call(TrackedArticle, [first.id, second.id], comments)

    expect(owners_read).to eq([[first.id], [second.id]])
    expect(live.keys).to eq([first.id.to_s, second.id.to_s])
  end

  it 'reads the owners the block names with the first one not read yet' do
    first = article
    second = article
    third = article

    candidates.call(TrackedArticle, [first.id], comments)
    candidates.call(TrackedArticle, [second.id], comments) { [first.id, third.id] }
    candidates.call(TrackedArticle, [third.id], comments) { raise 'not asked' }

    expect(owners_read).to eq([[first.id], [third.id, second.id]])
  end

  it 'reads each owner from its start' do
    owner = article
    start_at = Time.now.utc

    described_class.new(start_at).call(TrackedArticle, [owner.id], comments)

    expect(PaperTrailDiff::ActivityChildCandidateLoader).to have_received(:new)
      .with(TrackedArticle, [owner.id], comments, start_at)
  end

  it 'keeps the owners of each class and association apart' do
    owner = article

    candidates.call(TrackedArticle, [owner.id], comments)
    candidates.call(TrackedArticle, [owner.id],
                    TrackedArticle.reflect_on_association(:limited_comments))
    candidates.call(stub_const('TrackedSpecialArticle', Class.new(TrackedArticle)), [owner.id],
                    comments)

    expect(owners_read).to eq([[owner.id]] * 3)
  end
end
