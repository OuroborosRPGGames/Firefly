# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Whisper, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
  let(:target_character) { create(:character, forename: 'Bob') }
  let(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }
  let(:bystander_character) { create(:character, forename: 'Charlie') }
  let(:bystander_instance) { create(:character_instance, character: bystander_character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid target and message' do
      before { target_instance } # ensure target exists

      it 'successfully sends whisper' do
        result = command.execute('whisper Bob Hello there!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Hello there')
      end

      it 'persists message with whisper type' do
        result = command.execute('whisper Bob Hello there!')

        expect(result[:success]).to be true
        message = Message.last
        expect(message.message_type).to eq('whisper')
        expect(message.target_character_instance_id).to eq(target_instance.id)
      end

      it 'includes target in result' do
        result = command.execute('whisper Bob Hello there!')

        expect(result[:success]).to be true
        expect(result[:target]).to eq(target_character.full_name)
      end
    end

    context 'with no target specified' do
      it 'returns error when no one in room' do
        result = command.execute('whisper')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no one here to whisper/i)
      end

      it 'handles empty string when no one in room' do
        result = command.execute('whisper ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no one here to whisper/i)
      end
    end

    context 'with no message specified' do
      before { target_instance }

      it 'returns error' do
        result = command.execute('whisper Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what did you want to whisper/i)
      end

      it 'handles target with trailing space' do
        result = command.execute('whisper Bob ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what did you want to whisper/i)
      end
    end

    context 'with target not in room' do
      it 'returns error' do
        result = command.execute('whisper Nobody Hello')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no one matching|don't see anyone/i)
      end
    end

    context 'with self as target' do
      it 'returns error' do
        result = command.execute("whisper #{character.forename} Hello")

        expect(result[:success]).to be false
        expect(result[:error]).to match(/can't whisper to yourself/i)
      end
    end

    context 'with partial name match (4+ chars)' do
      let(:target_character) { create(:character, forename: 'Benjamin') }

      before { target_instance }

      it 'finds target with prefix' do
        result = command.execute('whisper Benj Hello!')

        expect(result[:success]).to be true
      end

      it 'matches short prefix' do
        result = command.execute('whisper Ben Hello!')

        expect(result[:success]).to be true
      end
    end

    context 'with case-insensitive matching' do
      before { target_instance }

      it 'finds target with lowercase name' do
        result = command.execute('whisper bob Hello!')

        expect(result[:success]).to be true
      end

      it 'finds target with uppercase name' do
        result = command.execute('whisper BOB Hello!')

        expect(result[:success]).to be true
      end
    end

    context 'with adverb' do
      before { target_instance }

      it 'incorporates adverb into formatted message' do
        result = command.execute('whisper Bob quietly Hello there!')

        expect(result[:success]).to be true
        expect(result[:formatted_message].downcase).to include('quietly')
      end
    end

    context 'with aliases' do
      before { target_instance }

      it 'works with whi alias' do
        result = command.execute('whi Bob Hello!')

        expect(result[:success]).to be true
      end

      it 'works with wh alias' do
        result = command.execute('wh Bob Hello!')

        expect(result[:success]).to be true
      end
    end

    context 'with duplicate detection' do
      before do
        target_instance
        # Create a recent whisper with similar content
        # Use update to set created_at since timestamps plugin overwrites it on create
        msg = Message.create(
          character_instance_id: character_instance.id,
          target_character_instance_id: target_instance.id,
          reality_id: reality.id,
          room_id: room.id,
          content: "#{character.full_name} whispers to #{target_character.full_name}, 'Hello there.'",
          message_type: 'whisper'
        )
        msg.this.update(created_at: Time.now - 60) # 1 minute ago - bypass timestamps plugin
      end

      it 'blocks similar whispers within 5 minutes' do
        result = command.execute('whisper Bob Hello there!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/recently whispered something similar/i)
      end
    end
  end

  describe '#can_execute?' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns true when character is in a room' do
      expect(command.can_execute?).to be true
    end

    it 'returns false when character has no room' do
      allow(command).to receive(:location).and_return(nil)
      expect(command.can_execute?).to be false
    end
  end

  # Use shared example for standard metadata tests
  it_behaves_like "command metadata", 'whisper', :roleplaying, ['whi', 'wh']

  # Additional metadata tests specific to whisper
  describe 'additional metadata' do
    it 'has usage info' do
      expect(described_class.usage).to be_a(String)
      expect(described_class.usage).to include('whisper')
    end

    it 'has examples' do
      expect(described_class.examples).to be_an(Array)
      expect(described_class.examples.length).to be > 0
    end
  end

  describe 'message formatting' do
    subject(:command) { described_class.new(character_instance) }

    before { target_instance }

    it 'formats message with sender and target names' do
      result = command.execute('whisper Bob Hello!')

      expect(result[:success]).to be true
      formatted = result[:formatted_message]
      expect(formatted).to include(character.full_name)
      expect(formatted).to include(target_character.full_name)
    end

    it 'includes whispers keyword' do
      result = command.execute('whisper Bob Hello!')

      expect(result[:success]).to be true
      expect(result[:formatted_message].downcase).to include('whisper')
    end
  end
end
