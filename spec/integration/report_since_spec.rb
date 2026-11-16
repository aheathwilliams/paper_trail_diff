# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'Checking the start of a report' do
  it 'names `since` for a range' do
    since = Time.utc(2032)..Time.utc(2033)
    expect { PaperTrailDiff.report(CoreArticle.all, since: since, limit: 5) }
      .to raise_error(PaperTrailDiff::InvalidTimeRangeError,
                      '`since` must be a time, date, or string; for a range, pass it as ' \
                      '`within:`')
  end

  it 'asks for a window when since: is nil' do
    expect { PaperTrailDiff.report(CoreArticle.all, since: nil, limit: 5) }
      .to raise_error(PaperTrailDiff::InvalidTimeRangeError,
                      'report takes one of `since:` or `within:`')
  end
end
