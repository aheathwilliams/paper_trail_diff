# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Whether PaperTrail writes a column's changes to `object_changes` whenever
  # a version saves them. Only then does a version that left a column out of
  # its recorded changes show that the column changed without a version.
  #
  # `has_paper_trail ignore:` and `skip:` leave a column out, and `only:`
  # leaves out every column it does not name. Each can also name a column
  # with a condition, read when the version was saved; such a column might
  # have been left out, so it is not counted as recorded either.
  module RecordedColumns
    #: (untyped, String?) -> bool
    def self.recorded?(model_class, name)
      return false unless Support.versioned?(model_class)

      options = model_class.paper_trail_options
      return false if named?(options.fetch(:ignore), name) || named?(options.fetch(:skip), name)

      only = options.fetch(:only) #: Array[untyped]
      only.empty? || only.include?(name)
    end

    # PaperTrail keeps each entry as a name, or as a hash of names to
    # conditions, which may be a subclass such as HashWithIndifferentAccess.
    #: (Array[untyped], String?) -> bool
    def self.named?(entries, name)
      entries.any? { |entry| entry.is_a?(Hash) ? entry.key?(name) : entry == name }
    end
    private_class_method :named?
  end
end
