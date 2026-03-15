# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MessageFormattingHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'instance methods' do
    it 'defines format_narrative_message' do
      expect(described_class.instance_methods).to include(:format_narrative_message)
    end

    it 'defines format_obscured_message' do
      expect(described_class.instance_methods).to include(:format_obscured_message)
    end

    it 'defines comma_punctuate' do
      expect(described_class.instance_methods).to include(:comma_punctuate)
    end
  end

  # Create a test class that includes the helper
  let(:test_class) do
    Class.new do
      include MessageFormattingHelper
    end
  end

  let(:instance) { test_class.new }

  describe '#format_narrative_message' do
    it 'formats message in one of two styles' do
      allow_any_instance_of(Object).to receive(:rand).with(2).and_return(0)

      result = instance.format_narrative_message(
        character_name: 'Bob',
        text: 'Hello there',
        verb: 'says'
      )
      expect(result).to be_a(String)
      expect(result).to include('Bob')
      expect(result).to include('Hello there')
    end

    it 'uses Format A: Name verb, "message"' do
      allow_any_instance_of(Object).to receive(:rand).with(2).and_return(0)

      result = instance.format_narrative_message(
        character_name: 'Bob',
        text: 'Hello',
        verb: 'says'
      )
      expect(result).to eq("Bob says, 'Hello'")
    end

    it 'uses Format B: "message" Name verb.' do
      allow_any_instance_of(Object).to receive(:rand).with(2).and_return(1)

      result = instance.format_narrative_message(
        character_name: 'Bob',
        text: 'Hello',
        verb: 'says'
      )
      expect(result).to eq("'Hello' Bob says.")
    end

    it 'includes adverb in message' do
      allow_any_instance_of(Object).to receive(:rand).with(2).and_return(0)

      result = instance.format_narrative_message(
        character_name: 'Bob',
        text: 'Hello',
        verb: 'says',
        adverb: 'quietly'
      )
      expect(result).to eq("Bob says quietly, 'Hello'")
    end

    it 'includes target name in message' do
      allow_any_instance_of(Object).to receive(:rand).with(2).and_return(0)

      result = instance.format_narrative_message(
        character_name: 'Bob',
        text: 'Hello',
        verb: 'says',
        target_name: 'Alice'
      )
      expect(result).to eq("Bob says to Alice, 'Hello'")
    end

    it 'places adverb before verb when adverb_before_verb is true' do
      allow_any_instance_of(Object).to receive(:rand).with(2).and_return(0)

      result = instance.format_narrative_message(
        character_name: 'Bob',
        text: 'Hi',
        verb: 'whispers',
        adverb: 'quietly',
        adverb_before_verb: true
      )
      expect(result).to eq("Bob quietly whispers, 'Hi'")
    end
  end

  describe '#format_obscured_message' do
    it 'formats obscured message without content' do
      result = instance.format_obscured_message(
        character_name: 'Bob',
        verb: 'whispers',
        target_name: 'Alice'
      )
      expect(result).to eq('Bob whispers something to Alice.')
    end

    it 'includes adverb in obscured message' do
      result = instance.format_obscured_message(
        character_name: 'Bob',
        verb: 'says',
        target_name: 'Alice',
        adverb: 'quietly'
      )
      expect(result).to eq('Bob quietly says something to Alice.')
    end
  end

  describe '#comma_punctuate' do
    it 'removes trailing period' do
      expect(instance.comma_punctuate('Hello.')).to eq('Hello')
    end

    it 'removes trailing exclamation' do
      expect(instance.comma_punctuate('Hello!')).to eq('Hello')
    end

    it 'removes trailing question mark' do
      expect(instance.comma_punctuate('Hello?')).to eq('Hello')
    end

    it 'strips whitespace' do
      expect(instance.comma_punctuate('  Hello.  ')).to eq('Hello')
    end

    it 'leaves text without trailing punctuation unchanged' do
      expect(instance.comma_punctuate('Hello')).to eq('Hello')
    end

    it 'handles nil gracefully' do
      expect(instance.comma_punctuate(nil)).to eq('')
    end
  end
end
