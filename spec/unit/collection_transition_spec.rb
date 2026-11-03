# frozen_string_literal: true

RSpec.describe PaperTrailDiff::CollectionTransition do
  def comment(id, body)
    PaperTrailDiff::RecordSnapshot.new(type: 'Comment', id: id, attributes: { body: body },
                                       associations: {})
  end

  def comments(*records)
    PaperTrailDiff::AssociationSnapshot.new(kind: :has_many, records: records)
  end

  # Another snapshot of the same records is another collection: only the
  # one the change was made to can take it.
  it 'knows the collection it left, and the record before and after the change' do
    before = comment(1, 'Draft')
    after = comment(1, 'Final')
    from = comments(before)
    transition = described_class.new(from: from, before: before, after: after)

    expect([transition.from?(from), transition.from?(comments(before))]).to eq([true, false])
    expect([transition.before, transition.after]).to eq([before, after])
    expect(transition).to be_frozen
  end
end
