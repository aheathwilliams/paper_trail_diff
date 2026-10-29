# frozen_string_literal: true

require_relative '../support/source_type_database'

# `source_type:` keeps only the links whose type column names that class, so a
# link to a tag never makes the tag a linked author, whichever boundary reads
# it. A link whose type changes joins or leaves the association with it.
RSpec.describe 'A has_many :through with source_type' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [SourceTypeLink, SourceTypeHolder, SourceTypeAuthor, SourceTypeTag].each(&:delete_all)
  end

  let(:holder) { SourceTypeHolder.create!(name: 'holder') }
  let(:ada) { SourceTypeAuthor.create!(name: 'Ada') }
  let(:bea) { SourceTypeAuthor.create!(name: 'Bea') }
  let(:tag) { SourceTypeTag.create!(name: 'tag') }

  # One version per holder, saved together, at which a range starts or ends.
  def checkpoint(record)
    SourceTypeHolder.transaction do
      fresh = SourceTypeHolder.find(record.id)
      fresh.paper_trail.save_with_version
      fresh.versions.reorder(:id).last
    end
  end

  def names(diff)
    change = diff.associations[association.to_s]
    return empty unless change

    { added: change.added.map { |author| author.attributes.fetch('name') },
      removed: change.removed.map { |author| author.attributes.fetch('name') },
      changed: change.changed.map { |record| record.attributes.transform_values(&:to_h) } }
  end

  def empty
    { added: [], removed: [], changed: [] }
  end

  def boundaries(steps)
    steps.map { |step| [step.from_boundary.version_id, step.to_boundary.version_id] }
  end

  def link(owner, target)
    SourceTypeLink.create!(holder: owner, target: target)
  end

  def compare(from, to)
    names(PaperTrailDiff.compare(from, to, associations: [association]))
  end

  def analyze(record, **options)
    PaperTrailDiff.analyze(record, associations: [association], **options)
  end

  def activity(record, **options)
    PaperTrailDiff.activity_timeline(record, associations: [association], **options)
  end

  def analyze_many(records, **options)
    PaperTrailDiff.analyze_many(records, associations: [association], **options)
  end

  def report(since)
    analyses, = PaperTrailDiff.report(SourceTypeHolder.all, since: since, limit: 10,
                                                            associations: [association])
    analyses.to_h { |identity, analysis| [identity.last.to_i, names(analysis.diff)] }
  end

  # Active Record takes the type as a String or a Symbol.
  %i[linked_authors symbol_authors].each do |name|
    context "with #{name}" do
      let(:association) { name }

      describe 'a link to another type' do
        # The kept tag shares Ada's id, so only the type column tells them apart.
        def history
          kept = link(holder, SourceTypeTag.create!(name: 'tag', id: ada.id))
          link(holder, ada)
          from = checkpoint(holder)
          link(holder, SourceTypeTag.create!(name: 'added tag'))
          kept.touch
          kept.target.update!(name: 'tag renamed')
          [from, checkpoint(holder)]
        end

        it 'is never a member in an endpoint diff' do
          from, to = history

          expect([compare(from, to), compare(from, holder)]).to eq([empty, empty])
          expect(names(analyze(holder, from: from, to: to).diff)).to eq(empty)
          expect(names(analyze(holder, from: from).diff)).to eq(empty)
        end

        it 'is never a member at a boundary a snapshot shows' do
          from, to = history

          snapshots = activity(holder, from: from, to: to, snapshots: true).flat_map do |step|
            [step.from_snapshot, step.to_snapshot]
          end
          linked = snapshots.map do |snapshot|
            snapshot.associations.fetch(association.to_s).records.map do |author|
              author.attributes.fetch('name')
            end
          end
          expect(linked).to eq([['Ada'], ['Ada']])
        end

        it 'opens no activity step' do
          from, to = history

          steps = activity(holder, from: from, to: to)
          expect(boundaries(steps)).to eq([[from.id, to.id]])
          expect(names(steps.first.diff)).to eq(empty)
          analysis = analyze(holder, from: from, to: to, activity: true)
          expect(boundaries(analysis.activity_timeline)).to eq([[from.id, to.id]])
        end

        it 'is never a member in a batch' do
          from, to = history

          analysis = analyze_many([holder], within: from.created_at..Time.now.utc,
                                            activity: true).values.first
          expect(names(analysis.diff)).to eq(empty)
          expect(boundaries(analysis.activity_timeline).map(&:first)).to eq([from.id, to.id])
          compared = [to, holder].flat_map do |ending|
            PaperTrailDiff.compare_many([{ from: from, to: ending }],
                                        associations: [association]).values
          end
          expect(compared.map { |diff| names(diff) }).to eq([empty, empty])
        end

        # The renamed tag shares Bea's id; Bea is no member either.
        it 'does not make the holder report activity' do
          link(holder, ada)
          same_id = SourceTypeTag.create!(name: 'same id', id: bea.id)
          link(holder, same_id)
          since = Time.now.utc
          link(holder, SourceTypeTag.create!(name: 'late tag'))
          same_id.update!(name: 'same id renamed')

          expect(report(since)).to eq({})
        end
      end

      describe 'a link whose type changes' do
        def history
          to_tag = link(holder, ada)
          to_author = link(holder, tag)
          from = checkpoint(holder)
          to_tag.update!(target: SourceTypeTag.create!(name: 'new tag'))
          to_author.update!(target: bea)
          [from, checkpoint(holder), to_tag.versions.last, to_author.versions.last]
        end

        it 'adds or removes the author in the diff' do
          from, to = history

          expected = empty.merge(added: ['Bea'], removed: ['Ada'])
          expect(compare(from, to)).to eq(expected)
          expect(names(analyze(holder, from: from, to: to).diff)).to eq(expected)
          expect(names(analyze(holder, from: from).diff)).to eq(expected)
        end

        it 'adds or removes the author in the step of that version' do
          from, to, left, joined = history

          changes = activity(holder, from: from, to: to).filter_map do |step|
            change = names(step.diff)
            [step.from_boundary.version_id, change] unless change == empty
          end
          expect(changes).to eq([[left.id, empty.merge(removed: ['Ada'])],
                                 [joined.id, empty.merge(added: ['Bea'])]])
        end

        it 'matches each holder analyzed alone in a batch, with or without activity' do
          from, = history
          other = SourceTypeHolder.create!(name: 'other')
          link(other, ada).update!(target: tag)
          window = from.created_at..Time.now.utc
          summary = lambda do |analysis|
            steps = analysis.activity_timeline&.map do |step|
              [step.from_boundary.version_id, names(step.diff)]
            end
            [names(analysis.diff), steps]
          end

          holders = [holder, other]
          matches = lambda do |with_activity|
            batched = analyze_many(holders, within: window, activity: with_activity)
            alone = holders.map do |record|
              analyze(record, within: window, activity: with_activity)
            end
            expect(batched.values.map(&summary)).to eq(alone.map(&summary))
          end
          matches.call(false)
          matches.call(true)
          expect(names(analyze_many([holder], within: window).values.first.diff))
            .to eq(empty.merge(added: ['Bea'], removed: ['Ada']))
        end

        it 'makes report select the holder' do
          link(holder, ada)
          gaining = SourceTypeHolder.create!(name: 'gaining')
          to_author = link(gaining, tag)
          since = Time.now.utc
          holder.links.first.update!(target: SourceTypeTag.create!(name: 'other tag'))
          to_author.update!(target: bea)

          expect(report(since)).to eq(holder.id => empty.merge(removed: ['Ada']),
                                      gaining.id => empty.merge(added: ['Bea']))
        end
      end

      it 'makes report select a holder whose author changed, and no other' do
        link(holder, ada)
        link(SourceTypeHolder.create!(name: 'tagged'), tag)
        since = Time.now.utc
        ada.update!(name: 'Ada renamed')
        tag.update!(name: 'tag renamed')

        renamed = { 'name' => { from: 'Ada', to: 'Ada renamed' } }
        expect(report(since)).to eq(holder.id => empty.merge(changed: [renamed]))
      end

      # Prepared history reads a through itself; this is the PT-AT path a
      # record falls back to when it cannot. The tag shares Bea's id.
      it 'keeps only links of the type when PT-AT reifies the through' do
        link(holder, ada)
        link(holder, SourceTypeTag.create!(name: 'same id', id: bea.id))
        from = checkpoint(holder)

        record = from.reify(dup: true)
        reflection = SourceTypeHolder.reflect_on_association(association)
        PaperTrailDiff::HistoricalAssociationReifier.new(from).reify(record, [reflection])
        expect(record.public_send(association).map(&:name)).to eq(['Ada'])
      end
    end
  end
end
