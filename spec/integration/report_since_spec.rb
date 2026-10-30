# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'Checking the start of a report' do
  [nil, (Time.utc(2032)..Time.utc(2033))].each do |since|
    it "names `since` for #{since.inspect}" do
      expect { PaperTrailDiff.report(CoreArticle.all, since: since, limit: 5) }
        .to raise_error(PaperTrailDiff::InvalidTimeRangeError,
                        '`since` must be a time, date, or string; for a range, pass it as ' \
                        '`within:` to analyze_scope')
    end
  end
end
