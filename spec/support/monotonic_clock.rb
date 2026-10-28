# frozen_string_literal: true

# Makes `Time.now` strictly increasing, in whole microseconds, for the test
# process.
#
# The specs read the wall clock to build windows around the versions they just
# wrote, and assume that a later call returns a later time. A wall clock does
# not promise that: WSL2 and other virtualized hosts step it backwards by
# hundreds of milliseconds when they resynchronize, which put a just-written
# version after a window's end, or a window's start after its end, at random.
#
# Every reader -- ActiveRecord timestamps, PaperTrail's created_at, and windows
# the specs or the gem build from `Time.now` -- goes through this one clock, so
# they agree with each other however the host clock moves. Readings land on
# microsecond boundaries because that is what the test databases store; two
# distinct readings can therefore never collapse into one stored timestamp.
module MonotonicTestClock
  MICROSECONDS = 1_000_000
  # How far ahead an externally assigned timestamp may pull the clock. Enough
  # to cover a host clock step; a fixture dated years ahead is left alone.
  MAX_ADVANCE = 5 * MICROSECONDS

  @mutex = Mutex.new
  @last = nil

  class << self
    # Returns `reading`, moved forward if needed to the first microsecond after
    # every earlier result. The zone of the reading is kept.
    def next_after(reading)
      @mutex.synchronize do
        micros = (reading.to_r * MICROSECONDS).floor
        micros = @last + 1 if @last && micros <= @last
        @last = micros
        reading + (Rational(micros, MICROSECONDS) - reading.to_r)
      end
    end

    # Ensures later readings follow `time`, for timestamps assigned elsewhere
    # that may have run slightly ahead of the clock.
    def advance_past(time)
      @mutex.synchronize do
        micros = (time.to_r * MICROSECONDS).floor
        next unless @last && micros > @last && micros - @last <= MAX_ADVANCE

        @last = micros
      end
    end
  end

  # Prepended to Time's singleton class.
  module Now
    def now(...)
      MonotonicTestClock.next_after(super)
    end
  end
end

Time.singleton_class.prepend(MonotonicTestClock::Now)
