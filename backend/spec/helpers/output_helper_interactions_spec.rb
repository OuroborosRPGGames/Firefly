# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/helpers/output_helper'

# Test class that includes OutputHelper
class TestOutputContext
  include OutputHelper

  attr_accessor :env

  def initialize(agent_mode: false)
    @env = agent_mode ? { 'firefly.agent_mode' => true } : {}
  end
end

RSpec.describe OutputHelper do
  let(:universe) { Universe.create(name: "Test Universe #{SecureRandom.hex(4)}", theme: 'fantasy') }
  let(:world) { World.create(name: 'Test World', universe: universe, gravity_multiplier: 1.0, world_size: 100.0) }
  let(:area) { Area.create(name: 'Test Area', world: world, zone_type: 'area', danger_level: 0) }
  let(:location) { Location.create(name: 'Test Location', zone: area, location_type: 'outdoor') }
  let(:room) { Room.create(name: 'Test Room', short_description: 'A test room', location: location, room_type: 'standard') }
  let(:reality) { Reality.create(name: "Test Reality #{SecureRandom.hex(4)}", reality_type: 'primary', time_offset: 0) }
  let(:user) { create(:user) }
  let(:character) { Character.create(forename: 'Test', user: user) }
  let(:char_instance) do
    CharacterInstance.create(
      character: character,
      reality: reality,
      current_room: room,
      level: 1,
      experience: 0,
      health: 100,
      max_health: 100,
      mana: 50,
      max_mana: 50
    )
  end

  let(:agent_context) { TestOutputContext.new(agent_mode: true) }
  let(:web_context) { TestOutputContext.new(agent_mode: false) }

  describe '#agent_mode?' do
    it 'returns true when env has agent mode flag' do
      expect(agent_context.agent_mode?).to be true
    end

    it 'returns false when env does not have agent mode flag' do
      # Reset the env to ensure no agent mode
      web_context.env = { 'PATH_INFO' => '/play' }
      expect(web_context.agent_mode?).to be false
    end
  end

  describe '#create_quickmenu' do
    let(:options) do
      [
        { key: '1', label: 'Attack', description: 'Strike the enemy' },
        { key: '2', label: 'Defend', description: 'Raise your shield' },
        { key: 'flee', label: 'Flee', description: 'Run away' }
      ]
    end

    context 'in agent mode' do
      it 'returns structured quickmenu data' do
        result = agent_context.create_quickmenu(char_instance, 'What do you do?', options)

        expect(result[:type]).to eq(:quickmenu)
        expect(result[:interaction_id]).not_to be_nil
        expect(result[:data][:prompt]).to eq('What do you do?')
        expect(result[:data][:options].length).to eq(3)
        expect(result[:requires_response]).to be true
      end

      it 'stores the interaction in Redis' do
        result = agent_context.create_quickmenu(char_instance, 'Test prompt', options)
        interaction_id = result[:interaction_id]

        stored = OutputHelper.get_agent_interaction(char_instance.id, interaction_id)
        expect(stored).not_to be_nil
        expect(stored[:type]).to eq('quickmenu')
        expect(stored[:prompt]).to eq('Test prompt')
      end

      it 'adds to pending interactions list' do
        agent_context.create_quickmenu(char_instance, 'Test prompt', options)

        pending = OutputHelper.get_pending_interactions(char_instance.id)
        expect(pending).not_to be_empty
        # Check that there's at least one quickmenu in the pending list
        quickmenus = pending.select { |i| i[:type] == 'quickmenu' }
        expect(quickmenus).not_to be_empty
      end
    end

    context 'in web mode' do
      it 'returns HTML formatted quickmenu' do
        result = web_context.create_quickmenu(char_instance, 'What do you do?', options)

        expect(result[:type]).to eq(:quickmenu)
        expect(result[:message_type]).to eq('quickmenu')
        expect(result[:message]).to include('quickmenu')
        expect(result[:message]).to include('Attack')
      end
    end

    it 'auto-generates keys if not provided' do
      simple_options = [
        { label: 'Option A' },
        { label: 'Option B' }
      ]

      result = agent_context.create_quickmenu(char_instance, 'Choose', simple_options)
      keys = result[:data][:options].map { |o| o[:key] }

      expect(keys).to include('1', '2')
    end
  end

  describe '#create_form' do
    let(:fields) do
      [
        { name: 'character_name', label: 'Character Name', type: 'text', required: true },
        { name: 'class', label: 'Class', type: 'select', options: ['Warrior', 'Mage', 'Rogue'] },
        { name: 'bio', label: 'Biography', type: 'textarea' }
      ]
    end

    context 'in agent mode' do
      it 'returns structured form data' do
        result = agent_context.create_form(char_instance, 'Create Character', fields)

        expect(result[:type]).to eq(:form)
        expect(result[:interaction_id]).not_to be_nil
        expect(result[:data][:title]).to eq('Create Character')
        expect(result[:data][:fields].length).to eq(3)
        expect(result[:requires_response]).to be true
      end

      it 'stores the form in Redis' do
        result = agent_context.create_form(char_instance, 'Test Form', fields)
        interaction_id = result[:interaction_id]

        stored = OutputHelper.get_agent_interaction(char_instance.id, interaction_id)
        expect(stored).not_to be_nil
        expect(stored[:type]).to eq('form')
        expect(stored[:title]).to eq('Test Form')
      end

      it 'includes field metadata' do
        result = agent_context.create_form(char_instance, 'Test', fields)

        name_field = result[:data][:fields].find { |f| f[:name] == 'character_name' }
        expect(name_field[:required]).to be true
        expect(name_field[:type]).to eq('text')

        class_field = result[:data][:fields].find { |f| f[:name] == 'class' }
        expect(class_field[:options]).to eq(['Warrior', 'Mage', 'Rogue'])
      end
    end

    context 'in web mode' do
      it 'returns HTML formatted form' do
        result = web_context.create_form(char_instance, 'Create Character', fields)

        expect(result[:type]).to eq(:form)
        expect(result[:message_type]).to eq('form')
        expect(result[:message]).to include('form-popup')
        expect(result[:message]).to include('Character Name')
      end
    end
  end

  describe '.get_pending_interactions' do
    before do
      # Clear any existing interactions for this character
      REDIS_POOL.with do |redis|
        keys = redis.keys("agent_interaction:#{char_instance.id}:*")
        redis.del(*keys) if keys.any?
        redis.del("agent_pending:#{char_instance.id}")
      end
    end

    it 'returns all pending interactions for a character' do
      agent_context.create_quickmenu(char_instance, 'Menu 1', [{ label: 'A' }])
      agent_context.create_form(char_instance, 'Form 1', [{ name: 'field1' }])

      pending = OutputHelper.get_pending_interactions(char_instance.id)

      expect(pending.length).to eq(2)
      types = pending.map { |p| p[:type] }
      expect(types).to include('quickmenu', 'form')
    end

    it 'returns empty array when no pending interactions' do
      pending = OutputHelper.get_pending_interactions(char_instance.id)
      expect(pending).to eq([])
    end
  end

  describe '.complete_interaction' do
    it 'removes the interaction from pending' do
      result = agent_context.create_quickmenu(char_instance, 'Test', [{ label: 'A' }])
      interaction_id = result[:interaction_id]

      # Verify it exists
      expect(OutputHelper.get_agent_interaction(char_instance.id, interaction_id)).not_to be_nil

      # Complete it
      OutputHelper.complete_interaction(char_instance.id, interaction_id)

      # Verify it's gone
      expect(OutputHelper.get_agent_interaction(char_instance.id, interaction_id)).to be_nil
      pending = OutputHelper.get_pending_interactions(char_instance.id)
      expect(pending.map { |p| p[:interaction_id] }).not_to include(interaction_id)
    end
  end

  describe 'format methods' do
    describe '#format_quickmenu_output' do
      let(:data) do
        {
          prompt: 'Choose wisely',
          options: [
            { key: '1', label: 'Option 1', description: 'First choice' },
            { key: '2', label: 'Option 2' }
          ]
        }
      end

      it 'formats for agent (plain text)' do
        result = agent_context.send(:format_quickmenu_output, data, html: false)

        expect(result).to include('**Choose wisely**')
        expect(result).to include('[1] Option 1')
        expect(result).to include('First choice')
        expect(result).to include('respond_to_interaction')
      end

      it 'formats for web (HTML)' do
        result = agent_context.send(:format_quickmenu_output, data, html: true)

        expect(result).to include('<div class=\'quickmenu\'>')
        expect(result).to include('Choose wisely')
        expect(result).to include('Option 1')
      end
    end

    describe '#format_form_output' do
      let(:data) do
        {
          title: 'User Form',
          fields: [
            { name: 'username', label: 'Username', type: 'text', required: true },
            { name: 'age', label: 'Age', type: 'number', default: '18' }
          ]
        }
      end

      it 'formats for agent (plain text)' do
        result = agent_context.send(:format_form_output, data, html: false)

        expect(result).to include('**User Form**')
        expect(result).to include('username (text) (required)')
        expect(result).to include('[default: 18]')
        expect(result).to include('respond_to_interaction')
      end

      it 'formats for web (HTML)' do
        result = agent_context.send(:format_form_output, data, html: true)

        expect(result).to include('<div class=\'form-popup\'>')
        expect(result).to include('User Form')
        expect(result).to include('type=\'text\'')
        expect(result).to include('type=\'number\'')
      end
    end
  end
end
