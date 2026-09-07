# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'bounded through reconstruction' do
  it 'reconstructs the requested collection source without loading unrelated joins' do
    author = TrackedAuthor.create!(name: 'Through author')
    article = author.articles.create!(title: 'Before')
    comment = article.comments.create!(body: 'Before')
    author.update!(name: 'After')
    version = author.versions.order(:id).last
    comment.update!(body: 'After')
    statements = []
    callback = ->(*args) { statements << args.last.fetch(:sql) }

    result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      PaperTrailDiff.analyze(author, from: version, to: author, associations: [:comments])
    end

    comments = result.from_snapshot.associations.fetch('comments').records
    expect(comments.map { |snapshot| snapshot.attributes.fetch('body') }).to eq(['Before'])
    expect(statements.grep(/tracked_authorships/i)).to be_empty
  end
end
