# frozen_string_literal: true

require_relative 'snapshot_cases'

module SnapshotCases
  # A few records with one state each, edited at random a step at a time, and
  # the article's snapshot after each step, as a history reads it: a record
  # reached twice, such as an author reviewing two comments, is the same both
  # times. Comments belong to the article or to nothing, replies to one comment
  # or none, an author can be the article's and any comment's reviewer, and
  # tags join the article through a list. SnapshotCases::Generator makes no
  # such promise, which the engine does not need and net changes do.
  class World
    FIELDS = {
      'Article' => %w[title body], 'Comment' => %w[body flag], 'Reply' => %w[body],
      'Author' => %w[name], 'Tag' => %w[label]
    }.freeze
    # Nil often: a field a record comes back with as nil has no row of its
    # own, so only the record's return can say it changed.
    VALUES = [nil, nil, 'a', 'b', 1, true].freeze
    TYPES = %w[Comment Reply Author Tag].freeze
    EDITS = %i[edit edit edit attach detach move review choose_author create destroy tag
               untag].freeze

    # Each record a snapshot reaches, by association path, type and id (the
    # article by an empty path and no identity), as its fields without nils.
    def self.records(snapshot, key = [[], nil, nil], found = {})
      return found unless snapshot

      found[key] = snapshot.attributes.compact
      snapshot.associations.each do |name, association|
        path = key.fetch(0) + [name]
        association.records.each { |record| records(record, [path, record.type, record.id], found) }
      end
      found
    end

    # Each record whose fields differ between two snapshots, as its fields in
    # each, or nil where it is not there.
    def self.changes(from, to)
      before = records(from)
      after = records(to)
      (before.keys | after.keys).filter_map do |key|
        [key, [before[key], after[key]]] unless before[key] == after[key]
      end.to_h
    end

    def initialize(random, size)
      @random = random
      @fields = {}
      @last_ids = Hash.new(0)
      @attached = []
      @parents = {}
      @reviewers = {}
      @tags = []
      @author = nil
      create_record('Article')
      (2 + @random.rand(2 + (2 * size))).times { create }
    end

    # The article before each of `count` steps and after the last.
    def history(count)
      states = [snapshot]
      count.times do
        step
        states << snapshot
      end
      states
    end

    private

    def step
      (1 + @random.rand(2)).times { send(EDITS.sample(random: @random)) }
    end

    def snapshot
      record('Article', 1,
             'author' => one(@author && record('Author', @author)),
             'comments' => many(:has_many, @attached.map { |id| comment(id) }),
             'tags' => many(:has_and_belongs_to_many, @tags.map { |id| record('Tag', id) }))
    end

    def comment(id)
      reviewer = @reviewers[id]
      replies = @parents.filter_map { |reply, parent| reply if parent == id }
      record('Comment', id,
             'reviewer' => one(reviewer && record('Author', reviewer)),
             'replies' => many(:has_many, replies.map { |reply| record('Reply', reply) }))
    end

    def record(type, id, associations = {})
      PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: @fields.fetch([type, id]),
                                         associations: associations)
    end

    def one(record)
      PaperTrailDiff::AssociationSnapshot.new(kind: :belongs_to, records: [record].compact)
    end

    def many(kind, records)
      PaperTrailDiff::AssociationSnapshot.new(kind: kind, records: records)
    end

    def ids(type)
      @fields.keys.filter_map { |record_type, id| id if record_type == type }
    end

    def any(type)
      ids(type).sample(random: @random)
    end

    def value
      VALUES.sample(random: @random)
    end

    def create_record(type)
      id = (@last_ids[type] += 1)
      @fields[[type, id]] = FIELDS.fetch(type).to_h { |field| [field, value] }
      id
    end

    def edit
      key = @fields.keys.sample(random: @random)
      field = FIELDS.fetch(key.fetch(0)).sample(random: @random)
      @fields[key] = @fields.fetch(key).merge(field => value)
    end

    def attach
      id = any('Comment')
      @attached |= [id] if id
    end

    def detach
      @attached.delete(@attached.sample(random: @random))
    end

    def move
      reply = any('Reply')
      @parents[reply] = [nil, *ids('Comment')].sample(random: @random) if reply
    end

    def review
      id = any('Comment')
      @reviewers[id] = [nil, *ids('Author')].sample(random: @random) if id
    end

    def choose_author
      @author = [nil, *ids('Author')].sample(random: @random)
    end

    def tag
      id = any('Tag')
      @tags |= [id] if id
    end

    def untag
      @tags.delete(@tags.sample(random: @random))
    end

    # A new comment is on the article and has a reviewer more often than not.
    def create
      type = TYPES.sample(random: @random)
      id = create_record(type)
      if type == 'Comment'
        @attached << id if @random.rand < 0.7
        @reviewers[id] = any('Author') if @random.rand < 0.5
      end
      @parents[id] = [nil, *ids('Comment')].sample(random: @random) if type == 'Reply'
    end

    def destroy
      type = TYPES.sample(random: @random)
      id = any(type)
      return unless id

      @fields.delete([type, id])
      forget(type, id)
    end

    # What pointed at a destroyed record no longer does.
    def forget(type, id)
      case type
      when 'Comment' then forget_comment(id)
      when 'Reply' then @parents.delete(id)
      when 'Author' then forget_author(id)
      else @tags.delete(id)
      end
    end

    def forget_comment(id)
      @attached.delete(id)
      @reviewers.delete(id)
      @parents.transform_values! { |parent| parent == id ? nil : parent }
    end

    def forget_author(id)
      @author = nil if @author == id
      @reviewers.transform_values! { |reviewer| reviewer == id ? nil : reviewer }
    end
  end
end
