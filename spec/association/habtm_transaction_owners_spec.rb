# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::HabtmTransactionOwners do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
  end

  let(:owners) { described_class.new(TrackedArticle, TrackedArticle.reflect_on_association(:tags)) }

  # Inserted, since creating a version resolves its item_type.
  def version(item_type, item_id, transaction_id)
    PaperTrail::Version.insert({ item_type: item_type, item_id: item_id, event: 'update',
                                 transaction_id: transaction_id, created_at: Time.now.utc })
  end

  def member(transaction_id, name: 'tags')
    PaperTrail::VersionAssociation.create!(version_id: transaction_id, foreign_key_name: name,
                                           foreign_key_id: 1)
  end

  describe '#shared' do
    it 'returns, as strings, the given transactions with more than one possible owner' do
      version('TrackedArticle', 1, 10)
      version('TrackedArticle', 2, 10)
      version('TrackedArticle', 1, 20)
      version('TrackedArticle', 3, 30)
      version('TrackedArticle', 4, 30)

      expect(owners.shared([10, 20])).to eq(['10'])
    end

    it 'counts a record that saved twice in the transaction once' do
      version('TrackedArticle', 1, 10)
      version('TrackedArticle', 1, 10)

      expect(owners.shared([10])).to eq([])
    end

    it 'leaves out records whose model has no HABTM of that name' do
      version('TrackedArticle', 1, 10)
      version('TrackedTag', 1, 10)
      version('TrackedComment', 1, 10)
      version('TrackedComment', 2, 10)

      expect(owners.shared([10])).to eq([])
    end

    it 'leaves out a model whose association of that name is not a HABTM' do
      tag_owners = described_class.new(TrackedArticle, TrackedTag.reflect_on_association(:articles))
      version('TrackedTag', 1, 10)
      version('TrackedAuthor', 1, 10)

      expect(tag_owners.shared(10)).to eq([])
    end

    it 'counts another model with a HABTM of the same name' do
      tag_owners = described_class.new(TrackedArticle, TrackedTag.reflect_on_association(:articles))
      version('TrackedArticle', 1, 10)
      version('TrackedTag', 1, 10)
      version('TrackedTag', 2, 10)

      expect(tag_owners.shared([10])).to eq(['10'])
    end

    it 'counts a model whose subclass declares the HABTM' do
      habtm = Struct.new(:macro).new(:has_and_belongs_to_many)
      base = Class.new { def self.reflect_on_association(_name) = nil }
      # `descendants` holds subclasses weakly; the local keeps this one from
      # being collected before `shared` looks for it.
      subclass = Class.new(base)
      subclass.define_singleton_method(:reflect_on_association) do |name|
        habtm if name == 'tags'
      end
      traversal = PaperTrailDiff::AssociationTraversal
      allow(traversal).to receive(:named_class).and_call_original
      allow(traversal).to receive(:named_class).with('HabtmStandIn').and_return(base)
      version('TrackedArticle', 1, 10)
      version('HabtmStandIn', 1, 10)

      expect(owners.shared([10])).to eq(['10'])
    end

    it 'counts a type that names no model, or names something other than a model' do
      version('TrackedArticle', 1, 10)
      version('RemovedModel', 1, 10)
      version('TrackedArticle', 1, 20)
      version('Comparable', 1, 20)

      expect(owners.shared([10, 20])).to contain_exactly('10', '20')
    end

    it 'resolves each type once' do
      allow(PaperTrailDiff::AssociationTraversal).to receive(:named_class).and_call_original
      version('TrackedArticle', 1, 10)
      version('TrackedArticle', 2, 10)

      owners.shared([10])

      expect(PaperTrailDiff::AssociationTraversal).to have_received(:named_class).once
    end
  end

  describe '#ambiguous?' do
    it 'is true only for a shared transaction that recorded members' do
      version('TrackedArticle', 1, 10)
      version('TrackedArticle', 2, 10)
      version('TrackedArticle', 3, 20)
      version('TrackedArticle', 4, 20)
      version('TrackedArticle', 5, 30)
      version('TrackedArticle', 6, 40)
      version('TrackedArticle', 7, 40)
      member(10)
      member(30)
      member(40, name: 'labels')

      expect([10, 20, 30, 40].map { |id| owners.ambiguous?(id) }).to eq([true, false, false, false])
    end
  end

  describe '#ensure_single_owner!' do
    it 'raises when the transaction is shared and recorded members' do
      version('TrackedArticle', 1, 10)
      version('TrackedArticle', 2, 10)
      member(10)

      expect { owners.ensure_single_owner!(10) }.to raise_error(
        PaperTrailDiff::IncompleteAssociationHistoryError,
        'HABTM history is ambiguous for tags at transaction 10: more than one record with ' \
        'a tags association saved a version in it, and PT-AT does not record which members ' \
        'belong to which record'
      )
    end

    it 'reads a shared transaction that recorded no members of that name' do
      version('TrackedArticle', 1, 10)
      version('TrackedArticle', 2, 10)
      member(10, name: 'labels')
      member(20)

      expect(owners.ensure_single_owner!(10)).to be_nil
    end

    it 'reads a transaction with one owner' do
      version('TrackedArticle', 1, 10)
      version('TrackedArticle', 2, 20)
      member(10)

      expect(owners.ensure_single_owner!(10)).to be_nil
    end
  end
end
