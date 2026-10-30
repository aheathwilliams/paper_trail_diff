# frozen_string_literal: true

RSpec.describe PaperTrailDiff::AssociationTree do
  it 'builds a deterministic bounded tree from explicit paths' do
    tree = described_class.build([:'comments.replies.author', 'author', 'comments'])

    expect(tree.children.keys).to eq(%w[author comments])
    expect(tree.child(:comments).child(:replies).children.keys).to eq(['author'])
    expect(tree.paths).to eq(%w[author comments comments.replies comments.replies.author])
    expect(tree).to be_frozen
    expect(tree.children).to be_frozen
  end

  # As `includes` takes them.
  it 'takes a single name, and hashes of names to what to include below them' do
    expect(described_class.build(:comments).paths).to eq(%w[comments])
    expect(described_class.build('comments.replies').paths).to eq(%w[comments comments.replies])
    nested = described_class.build([:tags, { comments: [:replies, { author: :articles }] },
                                    { 'profile' => [] }])
    expect(nested.paths).to eq(%w[comments comments.author comments.author.articles
                                  comments.replies profile tags])
    expect(described_class.build({ comments: 'replies.author' }).paths)
      .to eq(%w[comments comments.replies comments.replies.author])
    expect(described_class.build([]).paths).to eq([])
  end

  it 'rejects malformed association paths and option values' do
    [nil, 1, [nil], { comments: 1 }, { 1 => :replies }].each do |value|
      expect { described_class.build(value) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /must be names, dotted paths/)
    end
    expect { described_class.build(['comments..replies']) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /association path/)
    expect { described_class.build(['$']) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /association path/)
  end
end
