# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Semote Integration', type: :integration do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) do
    create(
      :character_instance,
      character: character,
      current_room: room,
      reality: reality,
      online: true,
      stance: 'standing'
    )
  end
  let(:couch) do
    Place.create(
      room: room,
      name: 'leather couch',
      is_furniture: true,
      default_sit_action: 'on',
      capacity: 3
    )
  end
  let(:bob_char) { create(:character, forename: 'Bob') }
  let(:bob_instance) do
    create(
      :character_instance,
      character: bob_char,
      current_room: room,
      reality: reality,
      online: true
    )
  end

  before do
    couch
    bob_instance
  end

  describe 'full semote flow' do
    it 'broadcasts emote and extracts sit action' do
      # Stub LLM to return sit action
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "sit", "target": "leather couch"}]'
      )

      # Execute synchronously for testing by stubbing Thread.new
      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote walks over and plops down on the leather couch')

      # Emote broadcasts immediately
      expect(result[:success]).to be true
      expect(result[:message]).to include('Alice')
      expect(result[:message]).to include('plops down')

      # Character should now be sitting
      character_instance.refresh
      expect(character_instance.stance).to eq('sitting')
      expect(character_instance.current_place_id).to eq(couch.id)
    end

    it 'logs interpretation and execution' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "sit", "target": "leather couch"}]'
      )

      # Execute synchronously for testing
      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      command.execute('semote sits on the couch')

      log = SemoteLog.where(character_instance_id: character_instance.id).first
      expect(log).not_to be_nil
      expect(log.emote_text).to eq('sits on the couch')
      expect(log.parsed_interpreted_actions.first[:command]).to eq('sit')
      expect(log.parsed_executed_actions.first[:success]).to be true
    end

    it 'continues past failed actions' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "drink", "target": "nonexistent coffee"}, {"command": "sit", "target": "leather couch"}]'
      )

      # Execute synchronously for testing
      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      command.execute('semote sips coffee and sits down')

      # Drink failed but sit should have succeeded
      character_instance.refresh
      expect(character_instance.stance).to eq('sitting')
    end

    it 'skips LLM processing in combat' do
      # Create a fight and add the character as a participant
      fight = create(:fight, room: room)
      create(:fight_participant, fight: fight, character_instance: character_instance)

      expect(SemoteInterpreterService).not_to receive(:interpret)

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote swings at the enemy')

      expect(result[:success]).to be true
    end

    it 'handles stand action from sitting position' do
      # Start sitting
      character_instance.update(stance: 'sitting')

      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "stand", "target": null}]'
      )

      # Execute synchronously
      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote rises to their feet')

      expect(result[:success]).to be true

      character_instance.refresh
      expect(character_instance.stance).to eq('standing')
    end

    it 'handles blocklisted commands gracefully' do
      # Attempt to trigger a blocklisted command (pay) - should be filtered out
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "pay", "target": "Bob 100"}, {"command": "sit", "target": "leather couch"}]'
      )

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote pays Bob and sits down')

      expect(result[:success]).to be true

      # Pay should be blocklisted, but sit should still work
      character_instance.refresh
      expect(character_instance.stance).to eq('sitting')
    end

    it 'handles empty action list from LLM' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[]'
      )

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote smiles warmly')

      # Should still succeed - emote broadcasts even with no extractable actions
      expect(result[:success]).to be true
      expect(result[:message]).to include('Alice')
      # Note: Adverb processing may rearrange the text (e.g., "smiles warmly" -> "Warmly Alice smiles")
      expect(result[:message]).to include('smiles')

      # Stance should remain unchanged
      character_instance.refresh
      expect(character_instance.stance).to eq('standing')
    end

    it 'handles LLM failure gracefully' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: false,
        error: 'API rate limited'
      )

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote waves hello')

      # Emote should still succeed even if LLM fails
      expect(result[:success]).to be true
      expect(result[:message]).to include('Alice')
      expect(result[:message]).to include('waves hello')
    end

    it 'handles malformed LLM response' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: 'This is not valid JSON at all'
      )

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote scratches their head')

      # Emote should still succeed
      expect(result[:success]).to be true
      expect(result[:message]).to include('Alice')
    end
  end

  describe 'multiple actions in sequence' do
    it 'executes multiple non-timed actions in order' do
      # Start sitting on the couch
      character_instance.update(stance: 'sitting', current_place_id: couch.id)

      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "stand", "target": null}]'
      )

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      result = command.execute('semote stands up from the couch')

      expect(result[:success]).to be true

      character_instance.refresh
      expect(character_instance.stance).to eq('standing')
      # Place should be cleared when standing
      expect(character_instance.current_place_id).to be_nil
    end
  end

  describe 'context building' do
    it 'includes furniture in LLM context' do
      captured_prompt = nil

      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        captured_prompt = args[:prompt]
        { success: true, text: '[]' }
      end

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      command.execute('semote looks around')

      expect(captured_prompt).to include('leather couch')
    end

    it 'includes other characters in LLM context' do
      captured_prompt = nil

      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        captured_prompt = args[:prompt]
        { success: true, text: '[]' }
      end

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      command.execute('semote glances at the others')

      expect(captured_prompt).to include('Bob')
    end

    it 'includes character stance in LLM context' do
      character_instance.update(stance: 'lying')
      captured_prompt = nil

      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        captured_prompt = args[:prompt]
        { success: true, text: '[]' }
      end

      allow(Thread).to receive(:new).and_yield

      command = Commands::Communication::SEmote.new(character_instance)
      command.execute('semote stretches')

      expect(captured_prompt).to include('lying')
    end
  end
end
