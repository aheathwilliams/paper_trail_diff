# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # A field's change as the runs that make it up, for ChangeAttribution: the
  # changes its record's versions recorded, and between them whatever moved
  # without a version.
  module ChangeChain
    # The value's path from `start` to `finish` as links of [from, to,
    # version], with nil for no version: each recorded change, and between
    # them whatever moved without one. A first change that does not start
    # where the row does joins the row's start unless `trusted`.
    #: (untyped, untyped, Array[[ActivityBoundary, ValueChange]], trusted: bool) -> Array[[untyped, untyped, ActivityBoundary?]]
    def self.call(start, finish, touched, trusted:)
      links = [] #: Array[[untyped, untyped, ActivityBoundary?]]
      value = start
      touched.each_with_index do |(version, change), index|
        value = bridge(links, value, change.from) if index.positive? || trusted
        links << link(value, change.to, version)
        value = change.to
      end
      bridge(links, value, finish)
      merge(merge(links).reject { |from, to, _version| from == to })
    end

    # A move from `value` to `to` that no version recorded, as a link; returns
    # where it ends.
    #: (Array[[untyped, untyped, ActivityBoundary?]], untyped, untyped) -> untyped
    def self.bridge(links, value, to)
      links << link(value, to, nil) unless to == value
      to
    end

    #: (untyped, untyped, ActivityBoundary?) -> [untyped, untyped, ActivityBoundary?]
    def self.link(from, to, version) = [from, to, version]

    # Consecutive links of the same kind as one: recorded ones credited to the
    # last of their versions.
    #: (Array[[untyped, untyped, ActivityBoundary?]]) -> Array[[untyped, untyped, ActivityBoundary?]]
    def self.merge(links)
      merged = [] #: Array[[untyped, untyped, ActivityBoundary?]]
      links.each do |from, to, version|
        previous = merged.last
        if previous && previous.last.nil? == version.nil?
          merged[-1] = [previous.first, to, version]
        else
          merged << [from, to, version]
        end
      end
      merged
    end
    private_class_method :bridge, :link, :merge
  end
end
