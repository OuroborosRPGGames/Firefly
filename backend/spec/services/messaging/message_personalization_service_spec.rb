# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MessagePersonalizationService do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }

  # Create three characters for testing
  let(:alice_user) { create(:user) }
  let(:alice) { create(:character, forename: 'Alice', surname: 'Smith', user: alice_user) }
  let(:alice_instance) { create(:character_instance, character: alice, current_room: room, reality: reality, online: true) }

  let(:bob_user) { create(:user) }
  let(:bob) { create(:character, forename: 'Bob', surname: 'Jones', user: bob_user, short_desc: 'a tall man', nickname: 'Bobby') }
  let(:bob_instance) { create(:character_instance, character: bob, current_room: room, reality: reality, online: true) }

  let(:carol_user) { create(:user) }
  let(:carol) { create(:character, forename: 'Carol', surname: 'White', user: carol_user) }
  let(:carol_instance) { create(:character_instance, character: carol, current_room: room, reality: reality, online: true) }

  describe '.personalize' do
    context 'with nil or empty inputs' do
      it 'returns nil message unchanged' do
        result = described_class.personalize(message: nil, viewer: alice_instance)
        expect(result).to be_nil
      end

      it 'returns empty message unchanged' do
        result = described_class.personalize(message: '', viewer: alice_instance)
        expect(result).to eq('')
      end

      it 'returns message unchanged with nil viewer' do
        result = described_class.personalize(message: 'Hello world', viewer: nil)
        expect(result).to eq('Hello world')
      end
    end

    context 'name substitution' do
      before do
        # Ensure all instances exist
        alice_instance
        bob_instance
        carol_instance
      end

      it 'uses forename for the character themselves (bolded)' do
        message = "#{alice.full_name} waves."
        result = described_class.personalize(
          message: message,
          viewer: alice_instance,
          room_characters: [alice_instance, bob_instance, carol_instance]
        )
        # Self-viewing returns forename, bolded
        expect(result).to eq("<strong>Alice</strong> waves.")
      end

      it 'uses short_desc for unknown characters (capitalized at start of sentence)' do
        message = "#{bob.full_name} waves at everyone."
        result = described_class.personalize(
          message: message,
          viewer: alice_instance,
          room_characters: [alice_instance, bob_instance, carol_instance]
        )
        # Alice doesn't know Bob, so sees short_desc (capitalized at start)
        expect(result).to eq("A tall man waves at everyone.")
      end

      it 'uses nickname if no short_desc for unknown characters' do
        bob.update(short_desc: nil)
        message = "#{bob.full_name} waves."
        result = described_class.personalize(
          message: message,
          viewer: alice_instance,
          room_characters: [alice_instance, bob_instance]
        )
        expect(result).to eq("Bobby waves.")
      end

      it 'uses "Someone" if no short_desc or nickname (capitalized at start)' do
        bob.update(short_desc: nil, nickname: nil)
        message = "#{bob.full_name} waves."
        result = described_class.personalize(
          message: message,
          viewer: alice_instance,
          room_characters: [alice_instance, bob_instance]
        )
        expect(result).to eq("Someone waves.")
      end

      context 'when viewer knows the character' do
        before do
          CharacterKnowledge.create(
            knower_character_id: alice.id,
            known_character_id: bob.id,
            is_known: true,
            known_name: 'Bobby J'
          )
        end

        it 'uses the shortest known name (nickname) when unique in room' do
          message = "#{bob.full_name} waves."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance]
          )
          expect(result).to eq("Bobby waves.")
        end

        it 'uses full_name if known but no known_name set' do
          CharacterKnowledge.first(knower_character_id: alice.id, known_character_id: bob.id)
                           .update(known_name: nil)
          message = "#{bob.full_name} waves."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance]
          )
          # full_name includes nickname in quotes: "Bob 'Bobby' Jones"
          expect(result).to eq("#{bob.full_name} waves.")
        end
      end

      it 'handles multiple names in one message' do
        CharacterKnowledge.create(
          knower_character_id: carol.id,
          known_character_id: alice.id,
          is_known: true,
          known_name: 'Ali'
        )

        message = "#{alice.full_name} waves at #{bob.full_name}."
        result = described_class.personalize(
          message: message,
          viewer: carol_instance,
          room_characters: [alice_instance, bob_instance, carol_instance]
        )
        # Carol knows Alice as "Ali", doesn't know Bob (sees short_desc)
        expect(result).to eq("Ali waves at a tall man.")
      end

      context 'when message contains smart/curly quotes' do
        it 'still substitutes names with smart quotes around nickname' do
          # LLMs often convert straight quotes to smart quotes
          message = "Bob \u2018Bobby\u2019 Jones waves at everyone."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance, carol_instance]
          )
          expect(result).to eq("A tall man waves at everyone.")
        end

        it 'handles smart quotes in middle of sentence' do
          message = "Everyone watches as Bob \u2018Bobby\u2019 Jones arrives."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance]
          )
          expect(result).to eq("Everyone watches as a tall man arrives.")
        end
      end

      it 'substitutes longer names first to avoid partial matches' do
        # Create character with name that's a prefix of another
        john_user = create(:user)
        john = create(:character, forename: 'John', surname: 'Smith', user: john_user, short_desc: 'a man')
        john_instance = create(:character_instance, character: john, current_room: room, reality: reality, online: true)

        john_smith_user = create(:user)
        john_smith = create(:character, forename: 'John Smith', surname: 'Jr', user: john_smith_user, short_desc: 'a younger man')
        john_smith_instance = create(:character_instance, character: john_smith, current_room: room, reality: reality, online: true)

        message = "#{john_smith.full_name} waves."
        result = described_class.personalize(
          message: message,
          viewer: alice_instance,
          room_characters: [alice_instance, john_instance, john_smith_instance]
        )
        # Should substitute "John Smith Jr" first, not just "John Smith" (capitalized at start)
        expect(result).to eq("A younger man waves.")
      end
    end

    context 'sensory filtering' do
      before do
        alice_instance
        bob_instance
      end

      context 'when viewer is blindfolded' do
        before do
          alice_instance.update(is_blindfolded: true)
        end

        it 'filters visual-only messages' do
          message = "#{bob.full_name} waves at everyone."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance],
            message_type: :visual
          )
          expect(result).to eq("[You can't see what's happening.]")
        end

        it 'allows auditory messages through' do
          message = "#{bob.full_name} says something."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance],
            message_type: :auditory
          )
          expect(result).to include("says something")
        end

        it 'allows mixed messages through with name substitution' do
          message = "#{bob.full_name} does something."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance],
            message_type: :mixed
          )
          # Mixed messages pass through but names are still substituted (capitalized at start)
          expect(result).to eq("A tall man does something.")
        end
      end

      context 'when viewer is not blindfolded' do
        it 'allows visual messages through' do
          message = "#{bob.full_name} waves."
          result = described_class.personalize(
            message: message,
            viewer: alice_instance,
            room_characters: [alice_instance, bob_instance],
            message_type: :visual
          )
          expect(result).to eq("A tall man waves.")
        end
      end
    end

    context 'automatic room character fetching' do
      before do
        alice_instance
        bob_instance
      end

      it 'fetches room characters automatically if not provided' do
        message = "#{bob.full_name} waves."
        result = described_class.personalize(
          message: message,
          viewer: alice_instance
          # room_characters not provided - should be fetched
        )
        expect(result).to eq("A tall man waves.")
      end
    end
  end

  describe '.register_transformer and .unregister_transformer' do
    after do
      # Clean up any registered transformers
      described_class.unregister_transformer(:test_transformer)
    end

    it 'allows registering custom transformers' do
      described_class.register_transformer(:test_transformer) do |message:, **|
        message.upcase
      end

      result = described_class.personalize(
        message: 'hello world',
        viewer: alice_instance
      )
      expect(result).to eq('HELLO WORLD')
    end

    it 'raises error if transformer does not respond to call' do
      expect {
        described_class.register_transformer(:bad_transformer, "not callable")
      }.to raise_error(ArgumentError, /must respond to #call/)
    end

    it 'allows unregistering transformers' do
      described_class.register_transformer(:test_transformer) do |message:, **|
        message.upcase
      end
      described_class.unregister_transformer(:test_transformer)

      result = described_class.personalize(
        message: 'hello world',
        viewer: alice_instance
      )
      expect(result).to eq('hello world')
    end
  end
end
