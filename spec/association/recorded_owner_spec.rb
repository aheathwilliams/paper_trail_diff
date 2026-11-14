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
  has_paper_trail
end

# Versioned, with no belongs_to on the key its owners find it by: PT-AT
# records an owner for each belongs_to, so none for these.
class OwnerSpecLooseComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  belongs_to :reviewer, class_name: 'TrackedAuthor', optional: true
  has_many :replies, class_name: 'TrackedReply', foreign_key: :comment_id
  has_paper_trail
end

# Not versioned either, which every request that reads history refuses itself.
class OwnerSpecPlainComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
end

class OwnerSpecArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :comments, class_name: 'TrackedComment', foreign_key: :article_id
  has_many :loose_comments, class_name: 'OwnerSpecLooseComment', foreign_key: :article_id
  has_one :loose_comment, class_name: 'OwnerSpecLooseComment', foreign_key: :article_id
  has_many :plain_comments, class_name: 'OwnerSpecPlainComment', foreign_key: :article_id
  has_many :stickers, class_name: 'OwnerSpecSticker', as: :holder
  has_many :loose_comment_replies, through: :loose_comments, source: :replies
  has_many :comment_replies, through: :comments, source: :replies
  has_paper_trail
end

# Reaches a through with an unrecorded part through a recorded one.
class OwnerSpecAuthor < ActiveRecord::Base
  self.table_name = 'tracked_authors'
  has_many :articles, class_name: 'OwnerSpecArticle', foreign_key: :author_id
  has_many :article_loose_comments, through: :articles, source: :loose_comments
  has_paper_trail
end

class OwnerSpecArticle
  belongs_to :author, class_name: 'OwnerSpecAuthor', optional: true
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

  describe '.unsupported_reason' do
    def reason(model, name)
      described_class.unsupported_reason(model.reflect_on_association(name))
    end

    def unrecorded(target, key, association)
      owner = association.split('#').first
      "#{target} declares no belongs_to on #{key}, so its versions do not record the " \
        "#{owner} that held it, and one that left #{association} cannot be found"
    end

    it 'names a has_many or has_one whose target declares no belongs_to on its key' do
      expect(reason(OwnerSpecArticle, :loose_comments))
        .to eq(unrecorded('OwnerSpecLooseComment', 'article_id', 'OwnerSpecArticle#loose_comments'))
      expect(reason(OwnerSpecArticle, :loose_comment))
        .to eq(unrecorded('OwnerSpecLooseComment', 'article_id', 'OwnerSpecArticle#loose_comment'))
    end

    it 'accepts one whose target declares it, with a class or polymorphic' do
      expect(reason(OwnerSpecArticle, :comments)).to be_nil
      expect(reason(TrackedArticle, :profile)).to be_nil
      expect(reason(OwnerSpecArticle, :stickers)).to be_nil
    end

    # A belongs_to is recorded on the owner's own versions, and a target
    # without versions is refused for that.
    it 'accepts what is not read from a belongs_to back' do
      expect(reason(TrackedComment, :article)).to be_nil
      expect(reason(OwnerSpecArticle, :plain_comments)).to be_nil
    end

    it 'names the part of a through whose target declares none' do
      expect(reason(OwnerSpecArticle, :loose_comment_replies))
        .to eq(unrecorded('OwnerSpecLooseComment', 'article_id', 'OwnerSpecArticle#loose_comments'))
      expect(reason(OwnerSpecAuthor, :article_loose_comments))
        .to eq(unrecorded('OwnerSpecLooseComment', 'article_id', 'OwnerSpecArticle#loose_comments'))
      expect(reason(OwnerSpecArticle, :comment_replies)).to be_nil
      expect(reason(TrackedArticle, :contributors)).to be_nil
    end

    describe 'as the reason a request cannot name it',
             mutant_expression: 'PaperTrailDiff::AssociationTraversal' do
      it 'is the reason the traversal gives, directly or through' do
        expected = unrecorded('OwnerSpecLooseComment', 'article_id',
                              'OwnerSpecArticle#loose_comments')

        %i[loose_comments loose_comment_replies].each do |name|
          reflection = OwnerSpecArticle.reflect_on_association(name)
          expect(PaperTrailDiff::AssociationTraversal.unsupported_reason(OwnerSpecArticle,
                                                                         reflection))
            .to eq(expected)
        end
      end
    end

    # Nothing would say a comment that was destroyed, or moved to another
    # article, was ever this article's.
    it 'is refused in every method, reported by diagnose and left out of discovery' do
      article = OwnerSpecArticle.create!(title: 'Loose')
      version = article.versions.first
      options = { associations: [:loose_comments] }
      error = [PaperTrailDiff::UnsupportedAssociationError,
               /\Aunsupported association loose_comments: OwnerSpecLooseComment declares no /]

      expect { PaperTrailDiff.compare(version, article, **options) }.to raise_error(*error)
      expect { SpecTimelines.activity_timeline(article, **options) }.to raise_error(*error)
      expect { PaperTrailDiff.report(OwnerSpecArticle, since: Time.utc(2000), limit: 5, **options) }
        .to raise_error(*error)
      expect(PaperTrailDiff.diagnose(version, article, **options).errors.map do |issue|
        [issue.code, issue.message]
      end).to match([[:unsupported_association, error.last]])
      expect(PaperTrailDiff.association_paths(OwnerSpecArticle).map(&:path))
        .to eq(%w[author comment_replies comments stickers])
    ensure
      PaperTrail::Version.delete_all
      OwnerSpecArticle.delete_all
    end
  end
end
