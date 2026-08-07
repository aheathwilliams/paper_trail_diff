# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PaperTrail/ActiveRecord boundary that produces plain record snapshots.
  class PaperTrailAdapter
    #: (associations: Array[String | Symbol], ignore: Array[String | Symbol]) -> void
    def initialize(associations:, ignore:)
      @association_names = normalize_names(associations, option: :associations)
      @ignored_attributes = normalize_names(ignore, option: :ignore)
    end

    #: (untyped, untyped) -> Diff
    def compare(from_version, to_version)
      validate_version_pair!(from_version, to_version)
      Engine.compare(snapshot_for(from_version), snapshot_for(to_version))
    end

    #: (untyped, from: untyped, to: untyped) -> Array[Step]
    def timeline(record, from:, to:)
      versions = versions_for(record)
      from_index = boundary_index(versions, from, boundary: :from)
      to_index = boundary_index(versions, to, boundary: :to)
      if from_index > to_index
        raise InvalidTimelineRangeError, '`from` version must not follow `to` version'
      end

      selected_versions = versions.slice(from_index..to_index) || []
      snapshots = selected_versions.map { |version| snapshot_for(version) }
      build_steps(selected_versions, snapshots)
    end

    private

    #: (Array[untyped], Array[RecordSnapshot?]) -> Array[Step]
    def build_steps(versions, snapshots)
      versions.each_cons(2).with_index.map do |version_pair, index|
        Step.new(
          from_version: version_pair.first,
          to_version: version_pair.last,
          diff: Engine.compare(snapshots.fetch(index), snapshots.fetch(index + 1))
        )
      end.freeze
    end

    # @rbs @association_names: Array[String]
    # @rbs @ignored_attributes: Array[String]

    #: (untyped) -> RecordSnapshot?
    def snapshot_for(version)
      normalize_record(version.reify(dup: true))
    end

    #: (untyped) -> RecordSnapshot?
    def normalize_record(record)
      return unless record

      attributes = record.attributes.dup
      excluded_attributes(record).each { |name| attributes.delete(name) }
      RecordSnapshot.new(
        type: record.class.name,
        id: record.id,
        attributes: attributes
      )
    end

    #: (untyped) -> Array[String]
    def excluded_attributes(record)
      primary_key = record.class.primary_key #: untyped
      primary_keys = primary_key.is_a?(Array) ? primary_key : [primary_key]
      # @type var primary_keys: Array[untyped]
      primary_keys = primary_keys.map { |key| key.to_s } # rubocop:disable Style/SymbolProc
      (primary_keys + @ignored_attributes).uniq
    end

    #: (untyped, untyped) -> void
    def validate_version_pair!(from_version, to_version)
      return if version_item_identity(from_version) == version_item_identity(to_version)

      raise VersionMismatchError, 'versions must belong to the same PaperTrail item'
    end

    #: (untyped) -> Array[String]
    def version_item_identity(version)
      [version.item_type.to_s, version.item_id.to_s]
    rescue NoMethodError => e
      raise VersionMismatchError, 'expected PaperTrail version endpoints', cause: e
    end

    #: (untyped) -> Array[untyped]
    def versions_for(record)
      association_name = record.class.versions_association_name
      record.public_send(association_name).to_a
    rescue NoMethodError => e
      message = 'record does not expose a PaperTrail version history'
      raise InvalidTimelineRangeError, message, cause: e
    end

    #: (Array[untyped], untyped, boundary: Symbol) -> Integer
    def boundary_index(versions, requested, boundary:)
      index = versions.index { |version| same_version?(version, requested) }
      return index if index

      raise InvalidTimelineRangeError, "`#{boundary}` version is not in the record history"
    end

    #: (untyped, untyped) -> bool
    def same_version?(version, requested)
      version.instance_of?(requested.class) && version.id == requested.id
    rescue NoMethodError
      false
    end

    #: (untyped, option: Symbol) -> Array[String]
    def normalize_names(values, option:)
      unless valid_names?(values)
        raise ArgumentError, "#{option}: must be an array of strings or symbols"
      end

      values.map(&:to_s).uniq.freeze
    end

    #: (untyped) -> bool
    def valid_names?(values)
      values.is_a?(Array) && values.all? do |value|
        value.is_a?(String) || value.is_a?(Symbol)
      end
    end
  end
end
