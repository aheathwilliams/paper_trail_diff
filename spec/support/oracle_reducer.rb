# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require_relative 'oracle_choices'

# Reduces a failing oracle example to a short history that fails the same way.
#
#   ORACLE_SEEDS=103 ORACLE_SHRINK=1 bundle exec rspec spec/oracle/shapes_history_spec.rb:251
#
# When an example under spec/oracle fails, the reducer runs it again, with its
# before and after hooks, building each history from an edited copy of the
# random choices that built it (Oracle::Choices). It first leaves out runs of
# steps, longest first, then sets each remaining choice to 0, the first
# operation or record. It keeps an edit when the run fails with the same first
# mismatch, its numbers and times aside, or with the same error, and repeats
# until no edit is kept or ORACLE_SHRINK_RUNS runs (default 300) are spent.
#
# The example then reports the shortest failing history: its failure, the
# versions it wrote, and a file that replays it,
#
#   ORACLE_REPLAY=tmp/oracle/shapes_history_spec-1-1.json \
#     bundle exec rspec 'spec/oracle/shapes_history_spec.rb[1:1]'
#
# followed by the original failure. Only the steps of a generator's `steps`
# loops are left out; what it does outside them, such as creating the root,
# always runs.
module Oracle
  # A generator's random source for the example that is running.
  def self.random(seed)
    session = Reducer.session
    session ? session.random(seed) : Choices.new(seed)
  end

  module Reducer
    DIRECTORY = 'tmp/oracle'

    class << self
      # The run in progress while the reducer drives an example.
      attr_accessor :session

      def around(example)
        replay = Replay.scripts_for(example)
        return example.run unless replay || reduce?

        attempt = Attempt.new(example)
        first = attempt.call(replay)
        return unless reduce? && first.failed? && first.scripts.any?

        limit = Integer(ENV.fetch('ORACLE_SHRINK_RUNS', 300))
        warn "oracle reducer: reducing the #{Script.steps(first.scripts)} steps of #{example.id}"
        reduction = Reduction.new(first, limit: limit) { |scripts| attempt.call(scripts) }
        Report.new(example, first, reduction.call).apply
      end

      def reduce?
        !ENV.fetch('ORACLE_SHRINK', '').empty?
      end

      # A label or message with its numbers and times taken out, so the same
      # mismatch matches across histories.
      def generalize(text)
        text.gsub(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)?/, 'TIME')
            .gsub(/\d+/, 'N')
      end
    end

    # The streams one run of an example drew from, and the failures it found.
    class Session
      attr_reader :failures

      def initialize(scripts)
        @scripts = scripts
        @streams = []
        @failures = []
      end

      def random(seed)
        replay = @scripts&.fetch(@streams.length, nil)
        Choices.new(seed, replay: replay).tap { |choices| @streams << choices }
      end

      def scripts
        @streams.map(&:script)
      end

      def labels
        @failures.flat_map(&:labels)
      end
    end

    Run = Struct.new(:scripts, :exception, :labels, keyword_init: true) do
      def failed?
        !exception.nil?
      end
    end

    # One run of the example, from the scripts given or from its seeds.
    class Attempt
      def initialize(example)
        @example = example
      end

      def call(scripts)
        reset_example
        session = Session.new(scripts)
        Reducer.session = session
        @example.run
        Run.new(scripts: session.scripts, exception: @example.exception, labels: session.labels)
      ensure
        Reducer.session = nil
      end

      private

      # Clears what the previous run left on the example, as rspec-retry does.
      def reset_example
        @example.example.display_exception = nil
        @example.example.example_group_instance&.send(:__init_memoized)
      end
    end

    # Whether a run fails as the original did.
    class Target
      def initialize(run)
        @label = run.labels.first&.then { |label| Reducer.generalize(label) }
        @error = signature(run.exception) unless @label
      end

      def matched_by?(run)
        return false unless run.failed?
        return run.labels.any? { |label| Reducer.generalize(label) == @label } if @label

        signature(run.exception) == @error
      end

      private

      # An expectation that reports no labels is known by where it failed; an
      # error by its class and the first line of its message.
      def signature(exception)
        if exception.is_a?(RSpec::Expectations::ExpectationNotMetError)
          [exception.class, exception.backtrace&.find { |line| line.include?('/spec/oracle/') }]
        else
          [exception.class, Reducer.generalize(exception.message.lines.first.to_s.strip)]
        end
      end
    end

    # The shortest failing scripts found from the first run's. The block runs
    # the example from a list of scripts and returns its Run.
    class Reduction
      attr_reader :best, :runs

      def initialize(first, limit:, log: $stderr, &run)
        @best = first
        @log = log
        @target = Target.new(first)
        @run = run
        @tried = Set[first.scripts.hash]
        @runs = 0
        @limit = limit
      end

      def call
        loop do
          before = @best.scripts
          leave_out_steps
          zero_draws
          break if @best.scripts == before || spent?
        end
        self
      end

      private

      def spent?
        @runs >= @limit
      end

      # Each loop, outermost first, losing runs of steps from its end: a
      # mismatch usually needs a few early steps, and leaving out later ones
      # keeps the earlier ones as they were.
      def leave_out_steps
        index = 0
        while (path = Script.loop_paths(@best.scripts)[index]) && !spent?
          leave_out(path)
          index += 1
        end
      end

      def leave_out(path)
        size = [length(path) / 2, 1].max
        while size.positive? && !spent?
          start = length(path) - size
          while start >= 0 && !spent?
            keep_if_failing(Script.without(@best.scripts, path, start, size))
            start = [start, length(path)].min - size
          end
          size /= 2
        end
      end

      # Each remaining draw as 0: the first operation of a list, the first
      # record, the lowest number.
      def zero_draws
        index = 0
        while (path = Script.draw_paths(@best.scripts)[index]) && !spent?
          value = Script.at(@best.scripts, path)
          zero = value.is_a?(Float) ? 0.0 : 0
          keep_if_failing(Script.replace(@best.scripts, path, zero)) unless value == zero
          index += 1
        end
      end

      def length(path)
        steps = Script.at(@best.scripts, path)
        steps.is_a?(Array) ? steps.length : 0
      end

      # Runs the scripts, and keeps them if the run fails as the original did.
      def keep_if_failing(scripts)
        return if spent? || !@tried.add?(scripts.hash)

        @runs += 1
        run = @run.call(scripts)
        return unless @target.matched_by?(run)

        @best = run
        @log.puts "oracle reducer: #{Script.steps(run.scripts)} steps still fail (run #{@runs})"
      end
    end

    # Paths into a list of scripts: a stream's index, then the index of an item
    # in its step, then of a step in that loop, and so on.
    module Script
      module_function

      # Every loop, outermost first.
      def loop_paths(scripts)
        paths(scripts) { |item| item.is_a?(Array) }
      end

      # Every draw, in the order it was made.
      def draw_paths(scripts)
        paths(scripts) { |item| item.is_a?(Numeric) }
      end

      def paths(scripts, &wanted)
        scripts.each_with_index.flat_map { |items, stream| paths_in(items, [stream], &wanted) }
      end

      def paths_in(items, path, &wanted)
        items.each_with_index.flat_map do |item, index|
          here = path + [index]
          found = yield(item) ? [here] : []
          next found unless item.is_a?(Array)

          found + item.each_with_index.flat_map do |step, number|
            paths_in(step, here + [number], &wanted)
          end
        end
      end

      def at(scripts, path)
        path.inject(scripts) { |node, index| node.is_a?(Array) ? node[index] : nil }
      end

      def without(scripts, path, start, size)
        edit(scripts, path) { |steps| steps[0...start] + (steps[(start + size)..] || []) }
      end

      def replace(scripts, path, value)
        edit(scripts, path[0...-1]) { |items| items.dup.tap { |copy| copy[path.last] = value } }
      end

      # A copy of the scripts with the node at the path replaced by the
      # block's value.
      def edit(node, path, &block)
        return yield(node) if path.empty?

        node.dup.tap { |copy| copy[path.first] = edit(node[path.first], path.drop(1), &block) }
      end

      def steps(scripts)
        loop_paths(scripts).sum { |path| at(scripts, path).length }
      end
    end

    # A reduced example's scripts, kept to run it again.
    module Replay
      module_function

      def scripts_for(example)
        path = ENV.fetch('ORACLE_REPLAY', '')
        return if path.empty?

        saved = JSON.parse(File.read(path))
        saved.fetch('scripts') if saved.fetch('example') == example.id
      end

      def save(example, scripts)
        FileUtils.mkdir_p(DIRECTORY)
        name = File.basename(example.metadata.fetch(:file_path), '.rb')
        place = example.id[/\[(.*)\]\z/, 1].to_s.tr(':', '-')
        path = File.join(DIRECTORY, "#{name}-#{place}.json")
        File.write(path, JSON.generate('example' => example.id, 'scripts' => scripts))
        path
      end

      def command(example, path)
        settings = %w[ORACLE_SEEDS PAPER_TRAIL_DIFF_SERIALIZER].filter_map do |name|
          "#{name}=#{ENV.fetch(name)}" if ENV.key?(name)
        end
        location = example.id.delete_prefix('./')
        line = [*settings, "ORACLE_REPLAY=#{path}", "bundle exec rspec '#{location}'"].join(' ')
        database = ' with the same PAPER_TRAIL_DIFF_DATABASE_URL' if
          ENV.key?('PAPER_TRAIL_DIFF_DATABASE_URL')
        "#{line}#{database}"
      end
    end

    # Replaces the example's failure with the reduced history's, followed by
    # the original.
    class Report
      LISTED_VERSIONS = 60

      def initialize(example, first, reduction)
        @example = example
        @first = first
        @reduction = reduction
      end

      def apply
        final = Attempt.new(@example).call(@reduction.best.scripts)
        path = Replay.save(@example, @reduction.best.scripts)
        failure = final.exception || @first.exception
        @example.example.display_exception = nil
        @example.example.set_exception(failure.exception(message(final, path)))
      end

      private

      def message(final, path)
        lines = [summary, "Replay it: #{Replay.command(@example, path)}"]
        if final.failed?
          lines += ['', 'Versions in the database when it ended, by transaction:', *versions,
                    '', 'Its failure:', final.exception.message]
        else
          lines << 'The reduced history passed when run again, so the failure may be intermittent.'
        end
        [*lines, '', 'The original failure:', @first.exception.message].join("\n")
      end

      def summary
        from = Script.steps(@first.scripts)
        to = Script.steps(@reduction.best.scripts)
        "ORACLE_SHRINK reduced #{from} generated steps to #{to} in #{@reduction.runs} runs."
      end

      def versions
        listed = PaperTrail::Version.order(:id).limit(LISTED_VERSIONS + 1).to_a
        groups = listed.first(LISTED_VERSIONS).chunk_while do |left, right|
          left.transaction_id == right.transaction_id
        end
        lines = groups.flat_map { |group| transaction(group) }
        lines << '  ...' if listed.length > LISTED_VERSIONS
        lines
      rescue StandardError => e
        ["  (could not list versions: #{e.class}: #{e.message})"]
      end

      def transaction(versions)
        first = versions.first
        ["  transaction #{first.transaction_id.inspect} (#{first.whodunnit || 'no whodunnit'}):",
         *versions.map { |version| "    #{version.id} #{describe(version)}"[0, 240] }]
      end

      def describe(version)
        changes = changes(version).filter_map do |name, (from, to)|
          change(version, name, from, to) unless from == to
        end
        [version.event, version.item_type, version.item_id, changes.join(', ')].join(' ').strip
      end

      def change(version, name, from, to)
        return "#{name}: #{to.inspect}" if version.event == 'create'

        "#{name}: #{from.inspect} -> #{to.inspect}"
      end

      def changes(version)
        (version.changeset || {}).except('id', 'created_at', 'updated_at')
      rescue StandardError
        {}
      end
    end
  end
end

RSpec.configure do |config|
  config.around(:example, file_path: %r{/spec/oracle/}) do |example|
    Oracle::Reducer.around(example)
  end
end
