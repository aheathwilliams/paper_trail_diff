# frozen_string_literal: true

RSpec.describe PaperTrailDiff::IgnorePolicy do
  let(:paths) { %w[comments comments.replies] }

  it 'keeps the existing array form global' do
    policy = described_class.build(%i[updated_at lock_version], association_paths: paths)

    expect(policy.attributes_for('')).to eq(%w[lock_version updated_at])
    expect(policy.attributes_for('comments.replies')).to eq(%w[lock_version updated_at])
  end

  it 'combines all rules with exact path rules' do
    policy = described_class.build(
      {
        all: [:updated_at],
        paths: {
          '$': [:lock_version],
          comments: [:position],
          'comments.replies': [:body]
        }
      },
      association_paths: paths
    )

    expect(policy.attributes_for('')).to eq(%w[updated_at lock_version])
    expect(policy.attributes_for('comments')).to eq(%w[updated_at position])
    expect(policy.attributes_for('comments.replies')).to eq(%w[updated_at body])
  end

  it 'rejects unknown keys, paths, and invalid attribute lists' do
    expect { described_class.build({ models: {} }, association_paths: paths) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /ignore option/)
    expect { described_class.build({ paths: { replies: [] } }, association_paths: paths) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /ignore path/)
    expect { described_class.build({ all: nil }, association_paths: paths) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /ignore\[:all\]/)
  end
end
