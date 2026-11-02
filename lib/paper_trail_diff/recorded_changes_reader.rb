# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Decodes what each version recorded at most once per request, and only when
  # a boundary's changes are read. A version many roots share in a batch, such
  # as an author's, is one decode however many steps name it, and a step the
  # caller never reads costs none.
  class RecordedChangesReader
    #: (Array[String]) -> void
    def initialize(ignore)
      @ignore = ignore
      @changes = {} #: Hash[Array[untyped], Hash[String, ValueChange]?]
      @lock = Mutex.new
    end

    # What `version` recorded, as PaperTrailDiff.recorded_changes returns it.
    #: (untyped) -> Hash[String, ValueChange]?
    def call(version)
      key = [version.class.name, version.id]
      @lock.synchronize do
        @changes.fetch(key) { @changes[key] = RecordedChanges.call(version, ignore: @ignore) }
      end
    end

    # @rbs @ignore: Array[String]
    # @rbs @changes: Hash[Array[untyped], Hash[String, ValueChange]?]
    # @rbs @lock: Thread::Mutex

    # One boundary's recorded changes, read when first asked for. It lets go of
    # the version once read, so a result keeps only what was decoded.
    class Pending
      #: (RecordedChangesReader, untyped) -> void
      def initialize(reader, version)
        @reader = reader
        @version = version
        @read = false
        @lock = Mutex.new
      end

      #: () -> Hash[String, ValueChange]?
      def value
        @lock.synchronize do
          unless @read
            @value = @reader.call(@version)
            @read = true
            @version = nil
          end
          @value
        end
      end

      # @rbs @reader: RecordedChangesReader
      # @rbs @version: untyped
      # @rbs @read: bool
      # @rbs @value: Hash[String, ValueChange]?
      # @rbs @lock: Thread::Mutex
    end
  end
end
