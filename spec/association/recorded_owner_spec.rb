# frozen_string_literal: true

require_relative '../support/association_database'

# Only reflections are read, so these reuse the fixture tables. Owners three
# classes deep, as single-table inheritance has them.
class OwnerSpecDocument < ActiveRecord::Base
  self.table_name = 'prepared_documents'
  has_many :remarks, class_name: 'OwnerSpecRemark', foreign_key: :article_id
  has_many :stickers, class_name: 'OwnerSpecSticker', as: :holder
end

class OwnerSpecReport < OwnerSpecDocument; end
class OwnerSpecAnnualReport < OwnerSpecReport; end

# Its belongs_to names the middle class. The one on another key names a class
# that is no owner's.
class OwnerSpecRemark < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  belongs_to :report, class_name: 'OwnerSpecReport', foreign_key: :article_id
  belongs_to :reviewer, class_name: 'TrackedAuthor'
end

# A subclass with a belongs_to of its own on the same key.
class OwnerSpecAnnualRemark < OwnerSpecRemark
  belongs_to :annual_report, class_name: 'OwnerSpecAnnualReport', foreign_key: :article_id
end

class OwnerSpecSticker < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  belongs_to :holder, polymorphic: true
end

RSpec.describe PaperTrailDiff::RecordedOwner do
  def types(owner, name)
    described_class.types(owner.reflect_on_association(name), owner)
  end

  it 'names the owner and its base class, and no class for a row without a type' do
    expect(types(TrackedArticle, :comments)).to eq([nil, '', 'TrackedArticle'])
    expect(types(OwnerSpecReport, :stickers))
      .to eq([nil, '', 'OwnerSpecReport', 'OwnerSpecDocument'])
  end

  # PT-AT stores the class the belongs_to was declared with, whichever class
  # of the table the owner is.
  it "names each class a belongs_to on the association's key names" do
    expect(types(OwnerSpecAnnualReport, :remarks))
      .to eq([nil, '', 'OwnerSpecAnnualReport', 'OwnerSpecDocument', 'OwnerSpecReport'])
    expect(types(OwnerSpecDocument, :remarks))
      .to eq([nil, '', 'OwnerSpecDocument', 'OwnerSpecReport', 'OwnerSpecAnnualReport'])
  end
end
