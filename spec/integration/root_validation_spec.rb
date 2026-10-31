# frozen_string_literal: true

require_relative '../support/core_database'

# The methods that read one record's history, or many records', take
# records of versioned models; anything else is named in the error.
RSpec.describe 'Checking the records a method reads the history of' do
  before do
    PaperTrail::Version.delete_all
    CoreComment.delete_all
    CoreArticle.delete_all
  end

  let(:article) { CoreArticle.create!(title: 'Draft', internal_note: 'note') }

  def single_record_methods
    {
      timeline: ->(value) { PaperTrailDiff.timeline(value) },
      activity_timeline: ->(value) { PaperTrailDiff.activity_timeline(value) },
      analyze: ->(value) { PaperTrailDiff.analyze(value) },
      analyze_many: ->(value) { PaperTrailDiff.analyze_many([article, value]) }
    }
  end

  {
    'nil' => [-> {}, 'expected a record, got nil'],
    'a model class' => [-> { CoreArticle }, 'expected a record, got the class CoreArticle'],
    'a relation' => [-> { CoreArticle.all }, 'expected a record, got ActiveRecord::Relation'],
    'a version' => [-> { article.versions.first }, 'expected a record, got PaperTrail::Version'],
    'a record of an unversioned model' => [
      -> { CoreComment.create!(article: article, body: 'Unversioned') },
      'CoreComment is not versioned, so it has no history: add has_paper_trail to it'
    ]
  }.each do |input, (value, message)|
    it "names #{input} in every method" do
      given = instance_exec(&value)

      single_record_methods.each_value do |method|
        expect { method.call(given) }.to raise_error(PaperTrailDiff::InvalidEndpointError, message)
      end
    end
  end

  it 'still reads a versioned record' do
    article.update!(title: 'Final')

    steps = PaperTrailDiff.timeline(article)

    expect(steps.map { |step| step.diff.attributes.keys }).to include(['title'])
  end
end
