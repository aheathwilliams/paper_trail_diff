# frozen_string_literal: true

require 'open3'

# The demo is the first thing a new user runs, and it is the only documentation
# that has to work with no application around it. Running it for real is the
# only way to know it still does.
RSpec.describe 'examples/demo.rb' do
  let(:script) { File.expand_path('../../examples/demo.rb', __dir__) }

  # The demo saves its versions microseconds apart, so a step back of the
  # host clock reorders them; it runs on the specs' clock (docs/testing.md).
  it 'runs standalone and reports who changed what' do
    lib = File.expand_path('../../lib', __dir__)
    clock = File.expand_path('../support/monotonic_clock', __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-I', lib, '-r', clock, script, chdir: File.expand_path('../..', __dir__)
    )

    expect(stderr).to eq('')
    expect(status).to be_success
    # Attribution across a nested record is the thing worth demonstrating, so
    # it is the thing worth asserting.
    expect(stdout).to include('Jon     changed Comment')
    expect(stdout).to include('Priya   changed Comment')
    expect(stdout).to include('title: "Apollo Notes" -> "Apollo Notes — Draft"')
    expect(stdout).to include('Jon made 1 change(s)')
  end
end
