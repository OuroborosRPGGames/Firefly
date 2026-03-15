# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Say, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
  let(:other_character) { create(:character, forename: 'Bob') }
  let(:other_instance) { create(:character_instance, character: other_character, current_room: room, reality: reality, online: true) }

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'say', :roleplaying, ['"', "'", 'yell', 'shout', 'mutter']

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with basic say text' do
      before { other_instance } # Ensure listener exists

      it 'successfully says message' do
        result = command.execute('say Hello everyone!')

        expect(result[:success]).to be true
      end

      it 'includes character name in formatted message' do
        result = command.execute('say Hello everyone!')

        expect(result[:formatted_message]).to include(character.full_name)
      end

      it 'includes the message text' do
        result = command.execute('say Hello everyone!')

        expect(result[:formatted_message]).to include('Hello everyone!')
      end

      it 'persists message with say type' do
        result = command.execute('say Hello everyone!')

        expect(result[:success]).to be true
        message = Message.last
        expect(message.message_type).to eq('say')
      end
    end

    context 'with quote shortcut' do
      before { other_instance }

      it 'works with double quote prefix' do
        result = command.execute('"Hello everyone!')

        expect(result[:success]).to be true
        expect(result[:formatted_message]).to include('Hello everyone!')
      end

      it 'works with single quote prefix' do
        result = command.execute("'Hello everyone!")

        expect(result[:success]).to be true
        expect(result[:formatted_message]).to include('Hello everyone!')
      end
    end

    context 'with no message specified' do
      it 'shows usage help' do
        result = command.execute('say')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Usage: say')
      end

      it 'shows usage help for empty string after say' do
        result = command.execute('say ')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Usage: say')
      end
    end

    context 'with adverb' do
      before { other_instance }

      it 'incorporates adverb into formatted message' do
        result = command.execute('say quietly I have a secret.')

        expect(result[:success]).to be true
        expect(result[:formatted_message].downcase).to include('quietly')
      end

      it 'extracts adverb correctly' do
        result = command.execute('say angrily That is not fair!')

        expect(result[:success]).to be true
        expect(result[:adverb]).to eq('angrily')
      end
    end

    context 'with yell alias' do
      before { other_instance }

      it 'works with yell' do
        result = command.execute('yell Hello!')

        expect(result[:success]).to be true
      end
    end

    context 'with shout alias' do
      before { other_instance }

      it 'works with shout' do
        result = command.execute('shout Hello!')

        expect(result[:success]).to be true
      end
    end

    context 'with mutter alias' do
      before { other_instance }

      it 'works with mutter' do
        result = command.execute('mutter Hello...')

        expect(result[:success]).to be true
      end
    end

    context 'when character is gagged' do
      before do
        allow(character_instance).to receive(:gagged?).and_return(true)
      end

      it 'returns error about being gagged' do
        result = command.execute('say Help!')

        expect(result[:success]).to be false
        expect(result[:error]).to include('gag')
      end
    end

    context 'with duplicate detection' do
      before do
        other_instance
        # Create a recent say message with similar content
        msg = Message.create(
          character_instance_id: character_instance.id,
          reality_id: reality.id,
          room_id: room.id,
          content: "#{character.full_name} says, 'Hello everyone!'",
          message_type: 'say'
        )
        msg.this.update(created_at: Time.now - 60) # 1 minute ago
      end

      it 'blocks similar say messages within cooldown period' do
        result = command.execute('say Hello everyone!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/recently said something similar/i)
      end
    end

    context 'message formatting' do
      before { other_instance }

      it 'includes quotes around the message' do
        result = command.execute('say Test message')

        expect(result[:success]).to be true
        expect(result[:formatted_message]).to include("'")
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

  describe 'additional metadata' do
    it 'has usage info' do
      expect(described_class.usage).to be_a(String)
      expect(described_class.usage).to include('say')
    end

    it 'has examples' do
      expect(described_class.examples).to be_an(Array)
      expect(described_class.examples.length).to be > 0
    end
  end

  # Reply/respond aliases moved to Commands::Communication::Reply
  # See spec/commands/communication/reply_spec.rb

  describe 'implicit target from context' do
    let(:room) { create(:room) }
    let(:reality) { create(:reality) }
    let(:speaker_character) { create(:character, forename: 'Speaker') }
    let(:speaker) { create(:character_instance, character: speaker_character, current_room: room, reality: reality, online: true) }
    let(:listener_character) { create(:character, forename: 'Listener') }
    let(:listener) { create(:character_instance, character: listener_character, current_room: room, reality: reality, online: true) }

    before do
      # speaker said something to listener, so listener's last_speaker is speaker
      listener.set_last_speaker(speaker)
    end

    it 'uses last_speaker when "say to" has no explicit target' do
      command = described_class.new(listener)
      # "say to Hey there!" - no target specified, should use context
      result = command.execute('say to Hey there!')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(speaker_character.full_name)
    end

    it 'uses last_speaker when "tell" has message but no target pattern' do
      command = described_class.new(listener)
      # The tell alias needs special handling since it expects "tell <target> <message>"
      # When context is available and no valid target found, fall back to context
      result = command.execute('tell Hey there!')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(speaker_character.full_name)
    end

    it 'returns error when no context and no target' do
      listener.clear_interaction_context!
      command = described_class.new(listener)
      result = command.execute('say to Hey there!')

      expect(result[:success]).to be false
      expect(result[:error]).to include('whom')
    end

    it 'updates context after successful say_to' do
      command = described_class.new(listener)
      command.execute('say to Hey there!')

      # listener spoke to speaker, so their last_spoken_to should be set
      listener.reload
      expect(listener.last_spoken_to_id).to eq(speaker.id)
    end

    it 'updates target context after successful say_to' do
      command = described_class.new(listener)
      command.execute('say to Hey there!')

      # speaker should know listener just spoke to them
      speaker.reload
      expect(speaker.last_speaker_id).to eq(listener.id)
    end

    it 'prefers explicit target over context' do
      # Create a third character to be the explicit target
      third_character = create(:character, forename: 'Third')
      third_instance = create(:character_instance, character: third_character, current_room: room, reality: reality, online: true)

      command = described_class.new(listener)
      result = command.execute("say to Third Hey there!")

      expect(result[:success]).to be true
      expect(result[:target]).to eq(third_character.full_name)
    end

    it 'indicates when implicit target was used' do
      command = described_class.new(listener)
      result = command.execute('say to Hey there!')

      expect(result[:success]).to be true
      expect(result[:implicit_target]).to be true
    end

    it 'does not set implicit_target when explicit target used' do
      # Create explicit target
      third_character = create(:character, forename: 'Third')
      create(:character_instance, character: third_character, current_room: room, reality: reality, online: true)

      command = described_class.new(listener)
      result = command.execute("say to Third Hey there!")

      expect(result[:success]).to be true
      expect(result[:implicit_target]).to be_falsey
    end
  end
end
