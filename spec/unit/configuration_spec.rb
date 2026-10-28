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

  it 'rejects malformed association paths and option values' do
    expect { described_class.build('comments') }
      .to raise_error(PaperTrailDiff::ConfigurationError, /array/)
    expect { described_class.build(['comments..replies']) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /association path/)
    expect { described_class.build(['$']) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /association path/)
  end
end
