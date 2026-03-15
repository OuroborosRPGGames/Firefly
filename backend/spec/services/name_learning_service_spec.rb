# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameLearningService do
  let(:character1) { double('Character', id: 1, full_name: 'Alice Smith', name_variants: ['Alice Smith', 'Alice']) }
  let(:character2) { double('Character', id: 2, full_name: 'Bob Jones', name_variants: ['Bob Jones', 'Bob']) }
  let(:character3) { double('Character', id: 3, full_name: 'Charlie Brown', name_variants: ['Charlie Brown', 'Charlie']) }

  let(:instance1) do
    double('CharacterInstance',
           character_id: 1,
           character: character1)
  end

  let(:instance2) do
    double('CharacterInstance',
           character_id: 2,
           character: character2)
  end

  let(:instance3) do
    double('CharacterInstance',
           character_id: 3,
           character: character3)
  end

  let(:room_characters) { [instance1, instance2, instance3] }

  describe '.process_emote' do
    context 'with nil inputs' do
      it 'returns early when text is nil' do
        expect(EmoteParserService).not_to receive(:parse)

        described_class.process_emote(character1, nil, room_characters)
      end

      it 'returns early when room_characters is nil' do
        expect(EmoteParserService).not_to receive(:parse)

        described_class.process_emote(character1, 'waves', nil)
      end

      it 'returns early when room_characters is empty' do
        expect(EmoteParserService).not_to receive(:parse)

        described_class.process_emote(character1, 'waves', [])
      end
    end

    context 'with speech segment containing own full name' do
      before do
        allow(EmoteParserService).to receive(:parse).and_return([
          { type: :speech, text: "I'm Alice Smith, nice to meet you!" }
        ])
        allow(EmoteParserService).to receive(:name_mentioned?).with(anything, 'Alice Smith').and_return(true)
        allow(EmoteParserService).to receive(:name_mentioned?).with(anything, 'Alice').and_return(true)
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([])
      end

      it 'teaches the longest matching name to other characters' do
        # Alice said "Alice Smith" which matches both "Alice Smith" and "Alice",
        # should use longest match: "Alice Smith"
        expect(character1).to receive(:introduce_to).with(character2, 'Alice Smith')
        expect(character1).to receive(:introduce_to).with(character3, 'Alice Smith')

        described_class.process_emote(character1, "says \"I'm Alice Smith!\"", room_characters)
      end

      it 'does not teach name to self' do
        expect(character1).not_to receive(:introduce_to).with(character1, anything)

        allow(character1).to receive(:introduce_to) # Allow other calls

        described_class.process_emote(character1, "says \"I'm Alice Smith!\"", room_characters)
      end
    end

    context 'with speech containing only nickname' do
      before do
        allow(EmoteParserService).to receive(:parse).and_return([
          { type: :speech, text: "Call me Alice." }
        ])
        allow(EmoteParserService).to receive(:name_mentioned?).with(anything, 'Alice Smith').and_return(false)
        allow(EmoteParserService).to receive(:name_mentioned?).with(anything, 'Alice').and_return(true)
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([])
      end

      it 'teaches the partial name that was mentioned' do
        expect(character1).to receive(:introduce_to).with(character2, 'Alice')
        expect(character1).to receive(:introduce_to).with(character3, 'Alice')

        described_class.process_emote(character1, "says \"Call me Alice.\"", room_characters)
      end
    end

    context 'with speech segment mentioning another character' do
      before do
        allow(EmoteParserService).to receive(:parse).and_return([
          { type: :speech, text: 'Hey Bob Jones, how are you?' }
        ])
        # Alice doesn't mention her own name
        allow(EmoteParserService).to receive(:name_mentioned?).with('Hey Bob Jones, how are you?', 'Alice Smith').and_return(false)
        allow(EmoteParserService).to receive(:name_mentioned?).with('Hey Bob Jones, how are you?', 'Alice').and_return(false)
        # Bob Jones is mentioned
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([instance2])
        allow(EmoteParserService).to receive(:name_mentioned?).with('Hey Bob Jones, how are you?', 'Bob Jones').and_return(true)
        allow(EmoteParserService).to receive(:name_mentioned?).with('Hey Bob Jones, how are you?', 'Bob').and_return(true)
      end

      it 'teaches mentioned character name to everyone using longest match' do
        expect(character2).to receive(:introduce_to).with(character1, 'Bob Jones')
        expect(character2).to receive(:introduce_to).with(character3, 'Bob Jones')

        described_class.process_emote(character1, 'says "Hey Bob Jones!"', room_characters)
      end

      it 'does not teach character about themselves' do
        expect(character2).not_to receive(:introduce_to).with(character2, anything)

        allow(character2).to receive(:introduce_to) # Allow other calls

        described_class.process_emote(character1, 'says "Hey Bob Jones!"', room_characters)
      end
    end

    context 'with action segment mentioning a character' do
      before do
        allow(EmoteParserService).to receive(:parse).and_return([
          { type: :action, text: 'waves to Bob Jones' }
        ])
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([instance2])
        # Default: name_mentioned? returns false unless specifically stubbed
        allow(EmoteParserService).to receive(:name_mentioned?).and_return(false)
        allow(EmoteParserService).to receive(:name_mentioned?).with('waves to Bob Jones', 'Bob Jones').and_return(true)
        allow(EmoteParserService).to receive(:name_mentioned?).with('waves to Bob Jones', 'Bob').and_return(true)
      end

      it 'teaches mentioned character name to everyone' do
        expect(character2).to receive(:introduce_to).with(character1, 'Bob Jones')
        expect(character2).to receive(:introduce_to).with(character3, 'Bob Jones')

        described_class.process_emote(character1, 'waves to Bob Jones', room_characters)
      end
    end

    context 'when emoting character mentions themselves in action' do
      before do
        allow(EmoteParserService).to receive(:parse).and_return([
          { type: :action, text: 'Alice Smith gestures dramatically' }
        ])
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([instance1])
      end

      it 'skips self-mentions in action segments' do
        expect(character1).not_to receive(:introduce_to)

        described_class.process_emote(character1, 'Alice Smith gestures', room_characters)
      end
    end

    context 'with mixed speech and action segments' do
      before do
        allow(EmoteParserService).to receive(:parse).and_return([
          { type: :action, text: 'turns to Bob Jones and' },
          { type: :speech, text: "Hi, I'm Alice Smith!" }
        ])
        # Default: name_mentioned? returns false unless specifically stubbed
        allow(EmoteParserService).to receive(:name_mentioned?).and_return(false)
        # Speech: Alice mentions her full name
        allow(EmoteParserService).to receive(:name_mentioned?).with("Hi, I'm Alice Smith!", 'Alice Smith').and_return(true)
        allow(EmoteParserService).to receive(:name_mentioned?).with("Hi, I'm Alice Smith!", 'Alice').and_return(true)
        # Action: Bob mentioned
        allow(EmoteParserService).to receive(:extract_mentioned_names).with('turns to Bob Jones and', room_characters).and_return([instance2])
        allow(EmoteParserService).to receive(:name_mentioned?).with('turns to Bob Jones and', 'Bob Jones').and_return(true)
        allow(EmoteParserService).to receive(:name_mentioned?).with('turns to Bob Jones and', 'Bob').and_return(true)
        # Speech: no one else mentioned
        allow(EmoteParserService).to receive(:extract_mentioned_names).with("Hi, I'm Alice Smith!", room_characters).and_return([])
      end

      it 'processes both action and speech segments' do
        # From action: Bob is mentioned, teach Bob's name
        expect(character2).to receive(:introduce_to).with(character1, 'Bob Jones')
        expect(character2).to receive(:introduce_to).with(character3, 'Bob Jones')

        # From speech: Alice says her name, teach Alice's name
        expect(character1).to receive(:introduce_to).with(character2, 'Alice Smith')
        expect(character1).to receive(:introduce_to).with(character3, 'Alice Smith')

        described_class.process_emote(character1, 'turns to Bob and says "I\'m Alice!"', room_characters)
      end
    end

    context 'with narrative segment' do
      before do
        allow(EmoteParserService).to receive(:parse).and_return([
          { type: :narrative, text: 'The room falls silent.' }
        ])
      end

      it 'ignores narrative segments' do
        expect(character1).not_to receive(:introduce_to)
        expect(character2).not_to receive(:introduce_to)

        described_class.process_emote(character1, 'The room falls silent.', room_characters)
      end
    end
  end

  describe '.process_speech' do
    context 'when speaker mentions their own name' do
      before do
        allow(EmoteParserService).to receive(:name_mentioned?).with("I'm Bob, nice to meet you", 'Bob Jones').and_return(false)
        allow(EmoteParserService).to receive(:name_mentioned?).with("I'm Bob, nice to meet you", 'Bob').and_return(true)
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([])
      end

      it 'teaches the matched name variant to room' do
        expect(character2).to receive(:introduce_to).with(character1, 'Bob')
        expect(character2).to receive(:introduce_to).with(character3, 'Bob')

        described_class.process_speech(character2, "I'm Bob, nice to meet you", room_characters)
      end
    end

    context 'when speech mentions no names' do
      before do
        allow(EmoteParserService).to receive(:name_mentioned?).and_return(false)
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([])
      end

      it 'does not teach any names' do
        expect(character1).not_to receive(:introduce_to)
        expect(character2).not_to receive(:introduce_to)

        described_class.process_speech(character1, "How's the weather?", room_characters)
      end
    end

    context 'with nil inputs' do
      it 'returns early when speech is nil' do
        expect(EmoteParserService).not_to receive(:name_mentioned?)
        described_class.process_speech(character1, nil, room_characters)
      end

      it 'returns early when room_characters is empty' do
        expect(EmoteParserService).not_to receive(:name_mentioned?)
        described_class.process_speech(character1, 'hello', [])
      end
    end
  end

  describe 'private methods' do
    describe '.teach_name_to_room' do
      it 'introduces character to all others in room with the given name' do
        expect(character1).to receive(:introduce_to).with(character2, 'Alice')
        expect(character1).to receive(:introduce_to).with(character3, 'Alice')

        described_class.send(:teach_name_to_room, character1, 'Alice', room_characters)
      end

      it 'does not introduce character to themselves' do
        expect(character1).not_to receive(:introduce_to).with(character1, anything)

        allow(character1).to receive(:introduce_to)

        described_class.send(:teach_name_to_room, character1, 'Alice', room_characters)
      end
    end

    describe '.process_mentioned_characters' do
      before do
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([instance2])
        allow(EmoteParserService).to receive(:name_mentioned?).with('mentions Bob Jones', 'Bob Jones').and_return(true)
        allow(EmoteParserService).to receive(:name_mentioned?).with('mentions Bob Jones', 'Bob').and_return(true)
      end

      it 'teaches mentioned character to everyone using longest match' do
        expect(character2).to receive(:introduce_to).with(character1, 'Bob Jones')
        expect(character2).to receive(:introduce_to).with(character3, 'Bob Jones')

        described_class.send(:process_mentioned_characters, 'mentions Bob Jones', character1, room_characters)
      end

      it 'skips if mentioned character is the emoting character' do
        allow(EmoteParserService).to receive(:extract_mentioned_names).and_return([instance1])

        expect(character1).not_to receive(:introduce_to)

        described_class.send(:process_mentioned_characters, 'Alice', character1, room_characters)
      end
    end
  end
end
