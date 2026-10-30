# frozen_string_literal: true

require_relative '../support/oracle'

ActiveRecord::Encryption.configure(
  primary_key: 'p' * 32, deterministic_key: 'd' * 32, key_derivation_salt: 's' * 32
)

ActiveRecord::Schema.define do
  create_table :oracle_nodes, force: true do |table|
    table.string :name
    table.integer :parent_id
    table.timestamps
  end

  create_table :oracle_docs, force: true do |table|
    table.integer :node_id
    table.string :secret, limit: 510
    table.text :prefs
    table.string :kind
    table.integer :cents
    table.decimal :ratio, precision: 8, scale: 3
    table.json :meta
    table.timestamps
  end
end

# Integer cents in the database, a value object in Ruby.
class OracleMoneyType < ActiveRecord::Type::Value
  Money = Struct.new(:cents)

  def cast(value)
    value.nil? || value.is_a?(Money) ? value : Money.new(Integer(value))
  end

  def serialize(value) = cast(value)&.cents
  def deserialize(value) = cast(value)
end

# A tree of one model: a root's children are nodes too, so a root can sit
# inside another root's tree, and subtrees move between trees.
class OracleNode < ActiveRecord::Base
  belongs_to :parent, class_name: 'OracleNode', optional: true
  has_many :children, class_name: 'OracleNode', foreign_key: :parent_id
  has_many :docs, class_name: 'OracleDoc', foreign_key: :node_id
  has_paper_trail
end

# Attributes whose stored form differs from the value read: encrypted,
# serialized, a string-backed enum, a custom type, a scaled decimal and JSON.
class OracleDoc < ActiveRecord::Base
  belongs_to :node, class_name: 'OracleNode', optional: true
  encrypts :secret
  serialize :prefs, coder: YAML
  enum :kind, { memo: 'memo', note: 'note', task: 'task' }
  attribute :cents, OracleMoneyType.new
  has_paper_trail
end

# The state each tree should show, read with plain Active Record. A record
# leaves out its primary key, `updated_at`, and the keys of the associations
# it is read through, as snapshots do.
module OracleTreeTruth
  PATHS = [%w[children.children.children], %w[children.docs docs], %w[parent docs],
           %w[children.children.docs parent.parent]].freeze

  module_function

  def states(root_ids)
    root_ids.product(PATHS).to_h { |id, paths| [[id, paths], snapshot(id, tree(paths))] }
  end

  def snapshot(id, tree)
    record = OracleNode.find_by(id: id)
    record && build(record, tree, [])
  end

  def build(record, tree, incoming)
    reflections = tree.keys.map { |name| record.class.reflect_on_association(name) }
    keys = reflections.select(&:belongs_to?).map { |reflection| reflection.foreign_key.to_s }
    attributes = record.attributes.except(record.class.primary_key, 'updated_at', *incoming, *keys)
    associations = reflections.to_h do |reflection|
      members = Array(record.class.find(record.id).public_send(reflection.name))
      child_keys = reflection.belongs_to? ? [] : [reflection.foreign_key.to_s]
      records = members.map { |member| build(member, tree.fetch(reflection.name.to_s), child_keys) }
      snapshot = PaperTrailDiff::AssociationSnapshot.new(kind: reflection.macro, records: records)
      [reflection.name.to_s, snapshot]
    end
    PaperTrailDiff::RecordSnapshot.new(type: record.class.name, id: record.id,
                                       attributes: attributes, associations: associations)
  end

  def tree(paths)
    paths.each_with_object({}) do |path, root|
      path.split('.').inject(root) { |branch, name| branch[name] ||= {} }
    end
  end
end

# Random edits to two trees. Each takes the history's random source.
class OracleTreeHistory
  # Some Active Support and json versions cannot encode JSON together; the
  # JSON column then stays empty.
  JSON_ENCODES = begin
    ActiveSupport::JSON.encode({ 'a' => 1 })
    true
  rescue ArgumentError
    false
  end
  OPERATIONS = %i[add_node add_node move_node rename_node destroy_node
                  add_doc add_doc edit_doc edit_doc edit_doc move_doc destroy_doc].freeze

  attr_reader :recorder, :root_ids

  def initialize(seed, steps:)
    @random = Random.new(seed)
    @steps = steps
    @root_ids = []
    @recorder = Oracle::Recorder.new { [nil, nil, OracleTreeTruth.states(@root_ids)] }
  end

  def build
    @recorder.run(:trees) { plant }
    @steps.times do
      operation = OPERATIONS.sample(random: @random)
      @recorder.run(operation) { send(operation) }
    end
    self
  end

  private

  def plant
    roots = Array.new(2) do |index|
      root = OracleNode.create!(name: "root #{index}")
      middle = root.children.create!(name: "middle #{index}")
      middle.children.create!(name: "leaf #{index}")
      OracleDoc.create!(node: middle, **doc_values)
      root
    end
    @root_ids = roots.map(&:id) + [OracleNode.find_by!(name: 'middle 0').id]
  end

  def nodes = OracleNode.order(:id).to_a
  def docs = OracleDoc.order(:id).to_a
  def any(list) = list.sample(random: @random)

  def add_node = any(nodes).children.create!(name: "node #{@random.rand(100)}")
  def rename_node = any(nodes).update!(name: "node #{@random.rand(100)}")
  def add_doc = OracleDoc.create!(node: any(nodes), **doc_values)
  def move_doc = any(docs)&.update!(node: any(nodes))
  def destroy_doc = any(docs)&.destroy!

  def edit_doc
    values = doc_values.to_a.sample(1 + @random.rand(3), random: @random).to_h
    any(docs)&.update!(values)
  end

  # Moves a node that is not a top-level root under any node outside its own
  # subtree.
  def move_node
    node = any(nodes.reject { |candidate| @root_ids.first(2).include?(candidate.id) })
    node&.update!(parent_id: any(nodes.map(&:id) - subtree_ids(node)))
  end

  def destroy_node
    leaves = nodes.reject do |node|
      @root_ids.include?(node.id) || node.children.any? || node.docs.any?
    end
    any(leaves)&.destroy!
  end

  def subtree_ids(node)
    ids = [node.id]
    level = ids
    until level.empty?
      level = OracleNode.where(parent_id: level).pluck(:id)
      ids += level
    end
    ids
  end

  def doc_values
    {
      secret: any([nil, 's1', 's2', 'Sécret']),
      prefs: any([nil, { 'a' => 1 }, { 'a' => [1, 2] }, { 'b' => { 'c' => true } }]),
      kind: any([nil, 'memo', 'note', 'task']),
      cents: any([nil, 0, 150, 2_500]),
      ratio: any([nil, BigDecimal('1.25'), BigDecimal('0.333'), 2]),
      meta: JSON_ENCODES ? any([nil, { 'k' => 'v' }, [1, 'two'], { 'n' => 1.5 }]) : nil
    }
  end
end

RSpec.describe 'Rebuilt tree history against the recorded states' do
  before do
    [PaperTrail::VersionAssociation, PaperTrail::Version, OracleDoc, OracleNode].each(&:delete_all)
  end

  # PaperTrail's YAML stores a decimal as a BigDecimal, and PaperTrail 16 a
  # serialized hash's changes as a HashWithIndifferentAccess. An application
  # permits these like any other class its versions hold.
  around do |example|
    permitted = ActiveRecord.yaml_column_permitted_classes
    ActiveRecord.yaml_column_permitted_classes =
      permitted | [BigDecimal, ActiveSupport::HashWithIndifferentAccess]
    example.run
  ensure
    ActiveRecord.yaml_column_permitted_classes = permitted
  end

  def state(entry, key)
    entry.snapshot&.fetch(key, nil)
  end

  def expected_steps(recorder, key, from)
    first = recorder.entries.index { |entry| entry.version_ids.include?(from.id) }
    recorder.entries.each_cons(2).drop(first - 1).filter_map do |before, after|
      diff = PaperTrailDiff::Engine.compare(state(before, key), state(after, key))
      diff.to_h unless diff.empty?
    end
  end

  def check_root(history, failures, root, paths)
    key = [root.id, paths]
    versions = root.versions.reorder(:created_at, :id).to_a
    versions.each do |from|
      expected = PaperTrailDiff::Engine.compare(state(history.recorder.before(from.id), key),
                                                state(history.recorder.final, key))
      actual = PaperTrailDiff.compare(from, root, associations: paths)
      failures.check("compare #{key.inspect} from #{from.id}", expected.to_h, actual.to_h)
    end
    steps = PaperTrailDiff.activity_timeline(root, associations: paths, group: :transaction)
    failures.check("activity #{key.inspect}", expected_steps(history.recorder, key, versions.first),
                   steps.reject(&:empty?).map { |step| step.diff.to_h })
  end

  # Windows between two recorded transactions, over all roots at once, one of
  # them inside another's tree.
  def check_windows(history, failures, random)
    roots = OracleNode.where(id: history.root_ids).order(:id).to_a
    entries = history.recorder.entries
    4.times do
      first, last = (1...entries.length).to_a.sample(2, random: random).sort
      OracleTreeTruth::PATHS.each do |paths|
        check_window(failures, roots, paths, entries.fetch(first), entries.fetch(last))
      end
    end
  end

  def check_window(failures, roots, paths, first, last)
    many = PaperTrailDiff.analyze_many(roots, within: first.after..last.after, associations: paths,
                                              activity: true)
    roots.each do |root|
      key = [root.id, paths]
      expected = PaperTrailDiff::Engine.compare(state(first, key), state(last, key))
      failures.check("analyze_many #{key.inspect} from #{first.after.iso8601(6)}", expected.to_h,
                     many.fetch(PaperTrailDiff::Endpoint.identity(root)).diff.to_h)
    end
  end

  Oracle.seeds([1, 2, 3]).each do |seed|
    it "rebuilds every root's trees, activity and batch windows (seed #{seed})" do
      history = OracleTreeHistory.new(seed, steps: Oracle.steps(25)).build
      failures = Oracle::Failures.new(seed, history.recorder)
      OracleNode.where(id: history.root_ids).order(:id).each do |root|
        OracleTreeTruth::PATHS.each { |paths| check_root(history, failures, root, paths) }
      end
      check_windows(history, failures, Random.new(seed))

      expect(failures).to be_empty, -> { failures.message }
    end
  end
end
