# frozen_string_literal: true

module Oracle
  # A generator's random source. It keeps every draw, so a history can be built
  # again with some of its steps left out (see spec/support/oracle_reducer.rb).
  #
  # Built from a seed, it hands out exactly what `Random.new(seed)` would, so a
  # seed builds the same history it always has. `Array#sample(random:)` and
  # `Array#shuffle(random:)` draw through `rand(Integer)`.
  #
  # A generator runs each loop of steps as `steps(count) { |index| ... }`
  # rather than `count.times`. The draws are kept as a script: an Array holding
  # an Integer or Float for each draw and, for each loop, an Array with one
  # Array of draws per step. Built from a script instead, `steps` runs the
  # steps the script's loop holds, each with its own draws, so leaving a step
  # out does not shift the draws of the steps after it. A draw the script has
  # no value for is 0: the first item of a list, the first operation.
  class Choices
    # What was drawn: from the seed, or from the script being replayed as far
    # as it reached.
    attr_reader :script

    def initialize(seed, replay: nil)
      @random = Random.new(seed)
      @replay = replay && [[replay, 0]]
      @script = []
      @record = [@script]
    end

    # As Random#rand: a Float with no limit, an Integer below an Integer
    # limit, or one in an Integer range. A range draw is kept as its offset.
    def rand(limit = nil)
      check!(limit)
      value = if @replay then replayed(limit)
              elsif limit.nil? then @random.rand
              else @random.rand(limit)
              end
      @record.last << (limit.is_a?(Range) ? value - limit.begin : value)
      value
    end

    # Runs `count` steps, or as many as the script being replayed holds here.
    def steps(count)
      kept = @replay && replayed_steps
      draws = []
      @record.last << draws
      (kept ? kept.length : count).times do |index|
        draws << (step = [])
        within(step, kept&.fetch(index)) { yield index }
      end
    end

    private

    def check!(limit)
      return if limit.nil? || (limit.is_a?(Integer) && limit.positive?)
      return if limit.is_a?(Range) && limit.begin.is_a?(Integer) && limit.end.is_a?(Integer)

      raise ArgumentError, "Oracle::Choices cannot replay rand(#{limit.inspect})"
    end

    def within(step, kept)
      @record.push(step)
      @replay&.push([kept, 0])
      yield
    ensure
      @record.pop
      @replay&.pop
    end

    def replayed(limit)
      kept = next_draw
      case limit
      when nil then kept.is_a?(Float) ? kept : 0.0
      when Integer then index(kept, limit)
      else limit.begin + index(kept, limit.size)
      end
    end

    # A whole number below `count` from a kept draw, which may be missing or
    # may have been drawn for something else.
    def index(kept, count)
      value = kept.is_a?(Float) ? (kept * count).floor : kept.to_i
      value.clamp(0, count - 1)
    end

    # The next kept draw of the current step, unless a loop comes first.
    def next_draw
      frame = @replay.last
      kept = frame.fetch(0)[frame.fetch(1)]
      return unless kept.is_a?(Numeric)

      frame[1] += 1
      kept
    end

    # The steps of the next loop in the current step, skipping draws the
    # replay did not make, or none.
    def replayed_steps
      frame = @replay.last
      items = frame.fetch(0)
      found = (frame.fetch(1)...items.length).find { |position| items[position].is_a?(Array) }
      return [] unless found

      frame[1] = found + 1
      items[found]
    end
  end
end
