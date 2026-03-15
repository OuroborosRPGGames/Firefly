# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AccessibilityOutputService do
  # Create a mock viewer that can toggle accessibility mode
  let(:viewer) { instance_double('CharacterInstance') }

  describe '.transform' do
    context 'when viewer has accessibility mode disabled' do
      before do
        allow(viewer).to receive(:accessibility_mode?).and_return(false)
      end

      it 'returns data unchanged for :room type' do
        data = { room: { name: 'Test Room' } }
        result = described_class.transform(:room, data, viewer)
        expect(result).to eq(data)
      end

      it 'returns data unchanged for :combat type' do
        data = { participants: [] }
        result = described_class.transform(:combat, data, viewer)
        expect(result).to eq(data)
      end

      it 'returns data unchanged for unknown type' do
        data = { foo: 'bar' }
        result = described_class.transform(:unknown, data, viewer)
        expect(result).to eq(data)
      end
    end

    context 'when viewer is nil' do
      it 'returns data unchanged' do
        data = { room: { name: 'Test Room' } }
        result = described_class.transform(:room, data, nil)
        expect(result).to eq(data)
      end
    end

    context 'when viewer has accessibility mode enabled' do
      before do
        allow(viewer).to receive(:accessibility_mode?).and_return(true)
      end

      it 'dispatches :room type to transform_room' do
        data = { room: { name: 'Test Room' } }
        result = described_class.transform(:room, data, viewer)
        expect(result[:accessible_text]).to include('Location: Test Room')
      end

      it 'dispatches :combat type to transform_combat' do
        data = { round_number: 3, participants: [] }
        result = described_class.transform(:combat, data, viewer)
        expect(result[:accessible_text]).to include('Combat Status')
      end

      it 'dispatches :character type to transform_character' do
        data = { name: 'John Doe' }
        result = described_class.transform(:character, data, viewer)
        expect(result[:accessible_text]).to include('John Doe')
      end

      it 'dispatches :message type to transform_message' do
        data = { message: 'Hello world' }
        result = described_class.transform(:message, data, viewer)
        expect(result[:accessible_text]).to eq('Hello world')
      end

      it 'returns original data for unknown types' do
        data = { custom: 'data' }
        result = described_class.transform(:unknown, data, viewer)
        expect(result).to eq(data)
      end
    end
  end

  describe '.transform_room' do
    before do
      allow(viewer).to receive(:accessibility_mode?).and_return(true)
    end

    let(:basic_room_data) do
      {
        room: {
          name: 'Town Square',
          description: 'A bustling town square with a fountain.'
        },
        exits: [
          { direction: 'north', display_name: 'North' },
          { direction: 'south', display_name: 'South', locked: true }
        ]
      }
    end

    it 'includes room name in location header' do
      result = described_class.transform_room(basic_room_data, viewer)
      expect(result[:accessible_text]).to include('Location: Town Square')
    end

    it 'includes room description' do
      result = described_class.transform_room(basic_room_data, viewer)
      expect(result[:accessible_text]).to include('A bustling town square')
    end

    it 'lists exits with directions' do
      result = described_class.transform_room(basic_room_data, viewer)
      expect(result[:accessible_text]).to include('Exits: north, south (locked)')
    end

    it 'sets format to :accessible' do
      result = described_class.transform_room(basic_room_data, viewer)
      expect(result[:format]).to eq(:accessible)
    end

    context 'with environment data' do
      let(:room_data_with_env) do
        {
          room: {
            name: 'Garden',
            time_of_day: 'evening',
            weather: 'light rain'
          }
        }
      end

      it 'includes time and weather' do
        result = described_class.transform_room(room_data_with_env, viewer)
        expect(result[:accessible_text]).to include('Environment: evening, light rain')
      end
    end

    context 'with characters present' do
      let(:room_data_with_chars) do
        {
          room: { name: 'Tavern' },
          characters_ungrouped: [
            { name: 'Alice', short_desc: 'A young woman', roomtitle: 'sitting at the bar' },
            { name: 'Bob', is_npc: true }
          ]
        }
      end

      it 'lists people with count' do
        result = described_class.transform_room(room_data_with_chars, viewer)
        expect(result[:accessible_text]).to include('People here (2):')
      end

      it 'includes character names' do
        result = described_class.transform_room(room_data_with_chars, viewer)
        expect(result[:accessible_text]).to include('- Alice')
        expect(result[:accessible_text]).to include('- Bob')
      end

      it 'includes roomtitle in parentheses' do
        result = described_class.transform_room(room_data_with_chars, viewer)
        expect(result[:accessible_text]).to include('Alice (sitting at the bar)')
      end

      it 'marks NPCs' do
        result = described_class.transform_room(room_data_with_chars, viewer)
        expect(result[:accessible_text]).to include('Bob [NPC]')
      end

      it 'includes short descriptions' do
        result = described_class.transform_room(room_data_with_chars, viewer)
        expect(result[:accessible_text]).to include('A young woman')
      end
    end

    context 'with places/furniture' do
      let(:room_data_with_places) do
        {
          room: { name: 'Living Room' },
          places: [
            { name: 'Sofa', description: 'A comfortable red sofa.', characters: [{ name: 'Cat' }] },
            { name: 'Table', characters: [] }
          ]
        }
      end

      it 'lists places' do
        result = described_class.transform_room(room_data_with_places, viewer)
        expect(result[:accessible_text]).to include('Places:')
        expect(result[:accessible_text]).to include('- Sofa')
        expect(result[:accessible_text]).to include('- Table')
      end

      it 'shows occupant count' do
        result = described_class.transform_room(room_data_with_places, viewer)
        expect(result[:accessible_text]).to include('Sofa (1 person)')
      end

      it 'includes place descriptions' do
        result = described_class.transform_room(room_data_with_places, viewer)
        expect(result[:accessible_text]).to include('A comfortable red sofa.')
      end
    end

    context 'with decorations' do
      let(:room_data_with_deco) do
        {
          room: { name: 'Hall' },
          decorations: [
            { name: 'Painting' },
            { name: 'Statue' }
          ]
        }
      end

      it 'lists decorations' do
        result = described_class.transform_room(room_data_with_deco, viewer)
        expect(result[:accessible_text]).to include('Decorations:')
        expect(result[:accessible_text]).to include('- Painting')
        expect(result[:accessible_text]).to include('- Statue')
      end
    end

    context 'with objects' do
      let(:room_data_with_objects) do
        {
          room: { name: 'Storage' },
          objects: [
            { name: 'Crate', quantity: 3 },
            { name: 'Barrel' }
          ]
        }
      end

      it 'lists objects with quantities' do
        result = described_class.transform_room(room_data_with_objects, viewer)
        expect(result[:accessible_text]).to include('Objects:')
        expect(result[:accessible_text]).to include('- Crate (x3)')
        expect(result[:accessible_text]).to include('- Barrel')
      end
    end

    context 'when viewer has accessibility mode disabled' do
      before do
        allow(viewer).to receive(:accessibility_mode?).and_return(false)
      end

      it 'returns data unchanged' do
        result = described_class.transform_room(basic_room_data, viewer)
        expect(result).to eq(basic_room_data)
        expect(result[:accessible_text]).to be_nil
      end
    end
  end

  describe '.transform_combat' do
    before do
      allow(viewer).to receive(:accessibility_mode?).and_return(true)
    end

    let(:basic_combat_data) do
      {
        round_number: 5,
        status: 'in_progress',
        participants: [
          {
            name: 'Hero',
            current_hp: 10,
            max_hp: 15,
            hex_x: 0,
            hex_y: 0,
            relationship: 'ally',
            is_current_character: true,
            input_complete: false
          },
          {
            name: 'Goblin',
            current_hp: 3,
            max_hp: 5,
            hex_x: 2,
            hex_y: 0,
            relationship: 'enemy'
          }
        ]
      }
    end

    it 'includes combat status header' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:accessible_text]).to include('<h4>Combat Status</h4>')
    end

    it 'includes round number' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:accessible_text]).to include('Round: 5')
    end

    it 'includes status' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:accessible_text]).to include('Status: in_progress')
    end

    it 'lists combatants' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:accessible_text]).to include('Combatants:')
      expect(result[:accessible_text]).to include('Hero')
      expect(result[:accessible_text]).to include('Goblin')
    end

    it 'shows HP for combatants' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:accessible_text]).to include('10/15HP')
      expect(result[:accessible_text]).to include('3/5HP')
    end

    it 'shows available actions when it is your turn' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:accessible_text]).to include('Your turn. Available actions:')
      expect(result[:accessible_text]).to include('Attack')
      expect(result[:accessible_text]).to include('Defend')
    end

    it 'sets format to :accessible' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:format]).to eq(:accessible)
    end

    it 'includes quick_commands' do
      result = described_class.transform_combat(basic_combat_data, viewer)
      expect(result[:quick_commands]).to be_an(Array)
    end

    context 'with knocked out participant' do
      let(:ko_combat_data) do
        {
          participants: [
            { name: 'Fallen', current_hp: 0, max_hp: 10, is_knocked_out: true, relationship: 'ally' }
          ]
        }
      end

      it 'marks knocked out status' do
        result = described_class.transform_combat(ko_combat_data, viewer)
        expect(result[:accessible_text]).to include('[KO]')
      end
    end

    context 'when viewer has accessibility mode disabled' do
      before do
        allow(viewer).to receive(:accessibility_mode?).and_return(false)
      end

      it 'returns data unchanged' do
        result = described_class.transform_combat(basic_combat_data, viewer)
        expect(result).to eq(basic_combat_data)
      end
    end
  end

  describe '.transform_character' do
    before do
      allow(viewer).to receive(:accessibility_mode?).and_return(true)
    end

    let(:basic_char_data) do
      {
        name: 'Jane Doe',
        short_desc: 'A tall woman with red hair',
        intro: 'She stands confidently, her green eyes surveying the room.'
      }
    end

    it 'includes character name as header' do
      result = described_class.transform_character(basic_char_data, viewer)
      expect(result[:accessible_text]).to include('<h4>Jane Doe</h4>')
    end

    it 'includes short description' do
      result = described_class.transform_character(basic_char_data, viewer)
      expect(result[:accessible_text]).to include('A tall woman with red hair')
    end

    it 'includes appearance intro' do
      result = described_class.transform_character(basic_char_data, viewer)
      expect(result[:accessible_text]).to include('Appearance:')
      expect(result[:accessible_text]).to include('She stands confidently')
    end

    it 'sets format to :accessible' do
      result = described_class.transform_character(basic_char_data, viewer)
      expect(result[:format]).to eq(:accessible)
    end

    context 'with descriptions' do
      let(:char_data_with_descs) do
        {
          name: 'Test',
          descriptions: [
            { type: 'face', content: 'Angular face with high cheekbones.' },
            { type: 'body_type', content: 'Athletic build.' }
          ]
        }
      end

      it 'formats description type names' do
        result = described_class.transform_character(char_data_with_descs, viewer)
        expect(result[:accessible_text]).to include('Face:')
        expect(result[:accessible_text]).to include('Body Type:')
      end

      it 'includes description content' do
        result = described_class.transform_character(char_data_with_descs, viewer)
        expect(result[:accessible_text]).to include('Angular face with high cheekbones.')
        expect(result[:accessible_text]).to include('Athletic build.')
      end
    end

    context 'with clothing' do
      let(:char_data_with_clothing) do
        {
          name: 'Test',
          clothing: [
            { name: 'Blue Dress', display_name: 'an elegant blue dress' },
            { name: 'Torn Shirt', torn: 1 }
          ]
        }
      end

      it 'lists clothing items' do
        result = described_class.transform_character(char_data_with_clothing, viewer)
        expect(result[:accessible_text]).to include('Wearing:')
        expect(result[:accessible_text]).to include('- an elegant blue dress')
      end

      it 'marks torn clothing' do
        result = described_class.transform_character(char_data_with_clothing, viewer)
        expect(result[:accessible_text]).to include('Torn Shirt (torn)')
      end
    end

    context 'with held items' do
      let(:char_data_with_items) do
        {
          name: 'Test',
          held_items: [
            { name: 'Sword', hand: 'right' },
            { name: 'Shield', hand: 'left' }
          ]
        }
      end

      it 'lists held items with hand' do
        result = described_class.transform_character(char_data_with_items, viewer)
        expect(result[:accessible_text]).to include('Holding:')
        expect(result[:accessible_text]).to include('- Sword (right)')
        expect(result[:accessible_text]).to include('- Shield (left)')
      end
    end

    context 'when viewer has accessibility mode disabled' do
      before do
        allow(viewer).to receive(:accessibility_mode?).and_return(false)
      end

      it 'returns data unchanged' do
        result = described_class.transform_character(basic_char_data, viewer)
        expect(result).to eq(basic_char_data)
      end
    end
  end

  describe '.transform_message' do
    before do
      allow(viewer).to receive(:accessibility_mode?).and_return(true)
    end

    it 'extracts message content' do
      data = { message: 'Hello there!' }
      result = described_class.transform_message(data, viewer)
      expect(result[:accessible_text]).to eq('Hello there!')
    end

    it 'extracts content key as fallback' do
      data = { content: 'Content text' }
      result = described_class.transform_message(data, viewer)
      expect(result[:accessible_text]).to eq('Content text')
    end

    it 'strips HTML tags' do
      data = { message: '<b>Bold</b> and <i>italic</i>' }
      result = described_class.transform_message(data, viewer)
      expect(result[:accessible_text]).to eq('Bold and italic')
    end

    it 'normalizes whitespace' do
      data = { message: "Multiple   spaces\nand\nnewlines" }
      result = described_class.transform_message(data, viewer)
      expect(result[:accessible_text]).to eq('Multiple spaces and newlines')
    end

    it 'sets format to :accessible' do
      data = { message: 'Test' }
      result = described_class.transform_message(data, viewer)
      expect(result[:format]).to eq(:accessible)
    end

    context 'when viewer has accessibility mode disabled' do
      before do
        allow(viewer).to receive(:accessibility_mode?).and_return(false)
      end

      it 'returns data unchanged' do
        data = { message: 'Test' }
        result = described_class.transform_message(data, viewer)
        expect(result).to eq(data)
      end
    end
  end

  # Test the private helper methods indirectly through public methods
  describe 'private helpers' do
    before do
      allow(viewer).to receive(:accessibility_mode?).and_return(true)
    end

    describe '#collect_all_characters' do
      it 'collects from ungrouped characters' do
        data = {
          room: { name: 'Test' },
          characters_ungrouped: [{ name: 'Alice' }]
        }
        result = described_class.transform_room(data, viewer)
        expect(result[:accessible_text]).to include('Alice')
      end

      it 'collects from places' do
        data = {
          room: { name: 'Test' },
          places: [{ name: 'Chair', characters: [{ name: 'Bob' }] }]
        }
        result = described_class.transform_room(data, viewer)
        expect(result[:accessible_text]).to include('Bob')
      end

      it 'falls back to characters array' do
        data = {
          room: { name: 'Test' },
          characters: [{ name: 'Charlie' }]
        }
        result = described_class.transform_room(data, viewer)
        expect(result[:accessible_text]).to include('Charlie')
      end
    end

    describe '#build_combat_quick_commands' do
      it 'includes enemy list command when enemies present' do
        data = {
          participants: [
            { name: 'Enemy1', relationship: 'enemy' }
          ]
        }
        result = described_class.transform_combat(data, viewer)
        enemy_cmd = result[:quick_commands].find { |c| c[:command] == 'combat enemies' }
        expect(enemy_cmd).not_to be_nil
      end

      it 'includes ally list command when allies present' do
        data = {
          participants: [
            { name: 'Ally1', relationship: 'ally' }
          ]
        }
        result = described_class.transform_combat(data, viewer)
        ally_cmd = result[:quick_commands].find { |c| c[:command] == 'combat allies' }
        expect(ally_cmd).not_to be_nil
      end

      it 'always includes recommend command' do
        data = { participants: [] }
        result = described_class.transform_combat(data, viewer)
        recommend_cmd = result[:quick_commands].find { |c| c[:command] == 'combat recommend' }
        expect(recommend_cmd).not_to be_nil
      end
    end
  end
end
