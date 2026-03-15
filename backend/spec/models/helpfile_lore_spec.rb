# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Helpfile, 'lore functionality' do
  describe '.lore_topics' do
    it 'returns only helpfiles with is_lore flag' do
      lore_file = create(:helpfile, is_lore: true, hidden: false)
      _regular_file = create(:helpfile, is_lore: false, hidden: false)

      topics = Helpfile.lore_topics
      expect(topics).to include(lore_file)
      expect(topics.length).to eq(1)
    end

    it 'excludes hidden lore files' do
      _hidden_lore = create(:helpfile, is_lore: true, hidden: true)
      visible_lore = create(:helpfile, is_lore: true, hidden: false)

      topics = Helpfile.lore_topics
      expect(topics).to include(visible_lore)
      expect(topics.length).to eq(1)
    end
  end

  describe '.lore_context_for' do
    context 'when no lore exists' do
      it 'returns empty string' do
        result = Helpfile.lore_context_for('some query')
        expect(result).to eq('')
      end
    end

    context 'with empty query' do
      it 'returns empty string for nil query' do
        expect(Helpfile.lore_context_for(nil)).to eq('')
      end

      it 'returns empty string for blank query' do
        expect(Helpfile.lore_context_for('   ')).to eq('')
      end
    end
  end

  describe '#embed_lore_content!' do
    let(:helpfile) { create(:helpfile, is_lore: false) }

    it 'does nothing when is_lore is false' do
      helpfile.is_lore = false
      expect(Embedding).not_to receive(:store)
      helpfile.embed_lore_content!
    end

    context 'when is_lore is true' do
      before { helpfile.update(is_lore: true) }

      it 'stores embedding with world_lore content type' do
        allow(Embedding).to receive(:store)

        helpfile.embed_lore_content!

        expect(Embedding).to have_received(:store).with(
          hash_including(
            content_type: 'world_lore',
            content_id: helpfile.id,
            input_type: 'document'
          )
        )
      end

      it 'includes topic and summary in embedded text' do
        allow(Embedding).to receive(:store)

        helpfile.embed_lore_content!

        expect(Embedding).to have_received(:store).with(
          hash_including(
            text: include(helpfile.topic).and(include(helpfile.summary))
          )
        )
      end

      it 'includes description if present' do
        helpfile.update(description: 'Detailed lore description')
        allow(Embedding).to receive(:store)

        helpfile.embed_lore_content!

        expect(Embedding).to have_received(:store).with(
          hash_including(
            text: include('Detailed lore description')
          )
        )
      end
    end
  end

  describe '#remove_lore_embedding!' do
    let(:helpfile) { create(:helpfile, is_lore: true) }

    it 'removes embedding for this helpfile' do
      allow(Embedding).to receive(:remove)

      helpfile.remove_lore_embedding!

      expect(Embedding).to have_received(:remove).with(
        content_type: 'world_lore',
        content_id: helpfile.id
      )
    end
  end

  describe '#lore_embedded?' do
    let(:helpfile) { create(:helpfile, is_lore: true) }

    it 'checks if embedding exists' do
      allow(Embedding).to receive(:exists_for?).and_return(true)

      result = helpfile.lore_embedded?

      expect(result).to be true
      expect(Embedding).to have_received(:exists_for?).with(
        content_type: 'world_lore',
        content_id: helpfile.id
      )
    end
  end

  describe 'after_save callback' do
    context 'when is_lore is set to true' do
      it 'embeds lore content' do
        helpfile = build(:helpfile, is_lore: true)
        allow(Embedding).to receive(:store)
        allow(Embedding).to receive(:remove)

        helpfile.save

        # Called twice: once for general helpfile embedding, once for lore embedding
        expect(Embedding).to have_received(:store).at_least(:once)
      end
    end

    context 'when is_lore is set to false' do
      it 'removes lore embedding' do
        helpfile = build(:helpfile, is_lore: false)
        allow(Embedding).to receive(:remove)

        helpfile.save

        expect(Embedding).to have_received(:remove)
      end
    end

    context 'when is_lore is changed from true to false' do
      let(:helpfile) { create(:helpfile, is_lore: true) }

      it 'removes the embedding' do
        allow(Embedding).to receive(:store)
        allow(Embedding).to receive(:remove)

        helpfile.update(is_lore: false)

        expect(Embedding).to have_received(:remove).with(
          content_type: 'world_lore',
          content_id: helpfile.id
        )
      end
    end
  end
end
