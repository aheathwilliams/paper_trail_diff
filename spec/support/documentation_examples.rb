# frozen_string_literal: true

module DocumentationExamples
  Example = Struct.new(:source, :line, keyword_init: true)
  EXECUTABLE_BLOCK = /
    <!--\ executable:(?<session>[a-z0-9_-]+)\ -->
    \s*```ruby\r?\n
    (?<source>.*?)
    ```
  /mx

  module_function

  def load(path, session:)
    contents = File.read(path)
    examples = contents.to_enum(:scan, EXECUTABLE_BLOCK).filter_map do
      match = Regexp.last_match
      next unless match[:session] == session

      Example.new(
        source: match[:source],
        line: contents[0...match.begin(:source)].count("\n") + 1
      )
    end
    raise "no executable #{session.inspect} examples in #{path}" if examples.empty?

    examples
  end

  def evaluate(path, session:, context:)
    load(path, session: session).map do |example|
      context.eval(example.source, path, example.line)
    end
  end
end
