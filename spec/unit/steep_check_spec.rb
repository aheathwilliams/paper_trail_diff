# frozen_string_literal: true

require_relative '../../script/steep_check'

RSpec.describe SteepCheck do
  it 'checks the captured diagnostics as well as the subprocess exit status' do
    response = ['No type error detected.', 'FATAL: checker crashed', double(exitstatus: 0)]
    allow(Open3).to receive(:capture3).with('bundle', 'exec', 'steep', 'check')
                                      .and_return(response)
    allow($stdout).to receive(:print)
    allow($stderr).to receive(:print)

    expect(described_class.call).to be(false)
    expect($stderr).to have_received(:print).with('FATAL: checker crashed')
  end

  it 'fails when Steep logs an internal exception but exits successfully' do
    output = "FATAL: Unexpected error: Unexpected self_type: untyped\nNo type error detected."

    expect(described_class.successful?(0, output)).to be(false)
  end

  it 'also requires a successful process exit' do
    expect(described_class.successful?(1, 'Detected 1 problem')).to be(false)
    expect(described_class.successful?(nil, '')).to be(false)
    expect(described_class.successful?(0, 'No type error detected.')).to be(true)
  end
end
