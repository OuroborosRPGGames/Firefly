# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmoteParserService do
  describe '.parse' do
    context 'with action only' do
      it 'returns single action segment' do
        result = described_class.parse('Alice smiles.')
        expect(result.length).to eq(1)
        expect(result[0][:type]).to eq(:action)
        expect(result[0][:text]).to eq('Alice smiles.')
      end
    end

    context 'with speech only' do
      it 'returns single speech segment' do
        result = described_class.parse('"Hello!"')
        expect(result.length).to eq(1)
        expect(result[0][:type]).to eq(:speech)
        expect(result[0][:text]).to eq('Hello!')
      end
    end

    context 'with action and speech' do
      it 'parses action followed by speech' do
        result = described_class.parse('Alice says, "Hello!"')
        expect(result.length).to eq(2)
        expect(result[0][:type]).to eq(:action)
        expect(result[0][:text]).to eq('Alice says, ')
        expect(result[1][:type]).to eq(:speech)
        expect(result[1][:text]).to eq('Hello!')
      end

      it 'parses speech followed by action' do
        result = described_class.parse('"Hello!" Alice waves.')
        expect(result.length).to eq(2)
        expect(result[0][:type]).to eq(:speech)
        expect(result[0][:text]).to eq('Hello!')
        expect(result[1][:type]).to eq(:action)
        expect(result[1][:text]).to eq(' Alice waves.')
      end

      it 'parses action-speech-action pattern' do
        result = described_class.parse('Alice smiles and says, "Hello everyone!" warmly.')
        expect(result.length).to eq(3)
        expect(result[0][:type]).to eq(:action)
        expect(result[0][:text]).to eq('Alice smiles and says, ')
        expect(result[1][:type]).to eq(:speech)
        expect(result[1][:text]).to eq('Hello everyone!')
        expect(result[2][:type]).to eq(:action)
        expect(result[2][:text]).to eq(' warmly.')
      end
    end

    context 'with multiple speech segments' do
      it 'parses multiple quotes' do
        result = described_class.parse('Alice says "Hi" then adds "Bye"')
        expect(result.length).to eq(4)
        expect(result[0]).to include(type: :action, text: 'Alice says ')
        expect(result[1]).to include(type: :speech, text: 'Hi')
        expect(result[2]).to include(type: :action, text: ' then adds ')
        expect(result[3]).to include(type: :speech, text: 'Bye')
      end
    end

    context 'with invalid input' do
      it 'returns empty array for nil' do
        result = described_class.parse(nil)
        expect(result).to eq([])
      end

      it 'returns empty array for empty string' do
        result = described_class.parse('')
        expect(result).to eq([])
      end
    end

    context 'with empty quotes' do
      it 'handles empty speech segments' do
        result = described_class.parse('Alice says ""')
        expect(result.length).to eq(1)
        expect(result[0][:type]).to eq(:action)
        expect(result[0][:text]).to eq('Alice says ')
      end
    end
  end

  describe '.extract_speech' do
    it 'returns only speech content' do
      result = described_class.extract_speech('Alice says "Hello" and "Goodbye"')
      expect(result).to eq('Hello Goodbye')
    end

    it 'returns empty string for action-only text' do
      result = described_class.extract_speech('Alice smiles.')
      expect(result).to eq('')
    end

    it 'returns all speech content concatenated' do
      result = described_class.extract_speech('"First" action "Second"')
      expect(result).to eq('First Second')
    end
  end

  describe '.extract_action' do
    it 'returns only action content' do
      result = described_class.extract_action('Alice says "Hello" warmly.')
      expect(result).to eq('Alice says  warmly.')
    end

    it 'returns empty string for speech-only text' do
      result = described_class.extract_action('"Hello!"')
      expect(result).to eq('')
    end

    it 'returns all action content concatenated' do
      result = described_class.extract_action('Before "speech" after')
      expect(result).to eq('Before  after')
    end
  end

  describe '.name_mentioned?' do
    context 'with word boundary matching' do
      it 'finds name at start of text' do
        expect(described_class.name_mentioned?('Alice waves', 'Alice')).to be true
      end

      it 'finds name at end of text' do
        expect(described_class.name_mentioned?('Hello Alice', 'Alice')).to be true
      end

      it 'finds name in middle of text' do
        expect(described_class.name_mentioned?('Hello Alice, how are you?', 'Alice')).to be true
      end

      it 'matches case-insensitively' do
        expect(described_class.name_mentioned?('Hello ALICE', 'alice')).to be true
        expect(described_class.name_mentioned?('Hello alice', 'ALICE')).to be true
      end

      it 'does not match partial names' do
        expect(described_class.name_mentioned?('malice', 'Alice')).to be false
        expect(described_class.name_mentioned?('alicejones', 'Alice')).to be false
      end

      it 'matches name followed by punctuation' do
        expect(described_class.name_mentioned?('Hello Alice!', 'Alice')).to be true
        expect(described_class.name_mentioned?('Hello Alice,', 'Alice')).to be true
        expect(described_class.name_mentioned?('Alice.', 'Alice')).to be true
      end
    end

    context 'with invalid input' do
      it 'returns false for nil text' do
        expect(described_class.name_mentioned?(nil, 'Alice')).to be false
      end

      it 'returns false for nil name' do
        expect(described_class.name_mentioned?('Hello', nil)).to be false
      end

      it 'returns false for very short names' do
        expect(described_class.name_mentioned?('Hello A', 'A')).to be false
      end
    end
  end

  describe '.extract_mentioned_names' do
    let(:alice) { instance_double('Character', to_s: 'Alice') }
    let(:bob) { instance_double('Character', to_s: 'Bob') }
    let(:alice_instance) { instance_double('CharacterInstance', character: alice) }
    let(:bob_instance) { instance_double('CharacterInstance', character: bob) }

    before do
      allow(DisplayHelper).to receive(:display_name).with(alice).and_return('Alice')
      allow(DisplayHelper).to receive(:display_name).with(bob).and_return('Bob')
    end

    it 'returns mentioned characters' do
      result = described_class.extract_mentioned_names('Hello Alice!', [alice_instance, bob_instance])
      expect(result).to include(alice_instance)
      expect(result).not_to include(bob_instance)
    end

    it 'returns multiple mentioned characters' do
      result = described_class.extract_mentioned_names('Hello Alice and Bob!', [alice_instance, bob_instance])
      expect(result).to include(alice_instance)
      expect(result).to include(bob_instance)
    end

    it 'returns empty array when no matches' do
      result = described_class.extract_mentioned_names('Hello there!', [alice_instance, bob_instance])
      expect(result).to be_empty
    end

    it 'returns empty array for nil text' do
      result = described_class.extract_mentioned_names(nil, [alice_instance])
      expect(result).to be_empty
    end

    it 'returns empty array for nil characters' do
      result = described_class.extract_mentioned_names('Hello Alice', nil)
      expect(result).to be_empty
    end
  end
end
