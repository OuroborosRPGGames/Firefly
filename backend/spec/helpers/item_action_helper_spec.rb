# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ItemActionHelper do
  # Create a test class that includes the helper and mocks command dependencies
  let(:test_class) do
    Class.new do
      include ItemActionHelper

      attr_accessor :character, :character_instance, :broadcast_messages

      def initialize(char, char_instance)
        @character = char
        @character_instance = char_instance
        @broadcast_messages = []
      end

      def error_result(message, **options)
        { success: false, message: message, error: message }.merge(options)
      end

      def success_result(message, **options)
        { success: true, message: message }.merge(options)
      end

      def broadcast_to_room(message, exclude_character: nil)
        @broadcast_messages << { message: message, exclude: exclude_character }
      end

      def resolve_item_with_menu(input, candidates)
        matches = candidates.select { |i| i.name.downcase.include?(input.downcase) }
        if matches.empty?
          { error: "Item not found" }
        elsif matches.length > 1
          { disambiguation: true, result: { options: matches.map(&:name) } }
        else
          { match: matches.first }
        end
      end

      def disambiguation_result(data, prompt)
        { success: false, disambiguation: true, prompt: prompt, data: data }
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def item_selection_menu(items, prompt, command:, description_field:)
        {
          success: true,
          type: :quickmenu,
          prompt: prompt,
          options: items.map { |i| { label: i.name } }
        }
      end
    end
  end

  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room) }
  let(:helper) { test_class.new(character, char_instance) }

  # Mock items for testing
  let(:sword) do
    item = create(:item, name: 'iron sword', character_instance: char_instance)
    allow(item).to receive(:drop!)
    allow(item).to receive(:wear!)
    allow(item).to receive(:hold!)
    allow(item).to receive(:remove!)
    item
  end

  let(:shield) do
    item = create(:item, name: 'wooden shield', character_instance: char_instance)
    allow(item).to receive(:drop!)
    allow(item).to receive(:wear!)
    allow(item).to receive(:hold!)
    allow(item).to receive(:remove!)
    item
  end

  describe '#perform_item_action' do
    it 'calls the action method on the item' do
      helper.perform_item_action(
        item: sword,
        action_method: :drop!,
        action_name: 'drop',
        self_verb: 'drop',
        other_verb: 'drops'
      )

      expect(sword).to have_received(:drop!)
    end

    it 'returns success result with correct message' do
      result = helper.perform_item_action(
        item: sword,
        action_method: :drop!,
        action_name: 'drop',
        self_verb: 'drop',
        other_verb: 'drops'
      )

      expect(result[:success]).to be true
      expect(result[:message]).to eq('You drop iron sword.')
      expect(result[:data][:action]).to eq('drop')
      expect(result[:data][:item_id]).to eq(sword.id)
    end

    it 'broadcasts to room with correct message' do
      helper.perform_item_action(
        item: sword,
        action_method: :drop!,
        action_name: 'drop',
        self_verb: 'drop',
        other_verb: 'drops'
      )

      expect(helper.broadcast_messages.length).to eq(1)
      expect(helper.broadcast_messages.first[:message]).to include('drops iron sword')
      expect(helper.broadcast_messages.first[:exclude]).to eq(char_instance)
    end

    it 'handles preposition in messages' do
      result = helper.perform_item_action(
        item: sword,
        action_method: :hold!,
        action_name: 'get',
        self_verb: 'pick',
        other_verb: 'picks',
        preposition: 'up'
      )

      expect(result[:message]).to eq('You pick up iron sword.')
    end

    it 'calls proc action method when provided' do
      custom_action = proc { |item| item.drop! }
      helper.perform_item_action(
        item: sword,
        action_method: custom_action,
        action_name: 'custom',
        self_verb: 'use',
        other_verb: 'uses'
      )

      expect(sword).to have_received(:drop!)
    end
  end

  describe '#perform_bulk_action' do
    let(:items) { [sword, shield] }

    it 'returns error when items empty' do
      result = helper.perform_bulk_action(
        items: [],
        action_method: :drop!,
        action_name: 'drop_all',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'No items to drop.'
      )

      expect(result[:success]).to be false
      expect(result[:message]).to eq('No items to drop.')
    end

    it 'calls action method on each item' do
      helper.perform_bulk_action(
        items: items,
        action_method: :drop!,
        action_name: 'drop_all',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'No items.'
      )

      expect(sword).to have_received(:drop!)
      expect(shield).to have_received(:drop!)
    end

    it 'returns success with all item names' do
      result = helper.perform_bulk_action(
        items: items,
        action_method: :drop!,
        action_name: 'drop_all',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'No items.'
      )

      expect(result[:success]).to be true
      expect(result[:message]).to eq('You drop iron sword, wooden shield.')
      expect(result[:data][:action]).to eq('drop_all')
      expect(result[:data][:items]).to eq(['iron sword', 'wooden shield'])
    end

    it 'broadcasts bulk action message' do
      helper.perform_bulk_action(
        items: items,
        action_method: :drop!,
        action_name: 'drop_all',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'No items.'
      )

      expect(helper.broadcast_messages.length).to eq(1)
      expect(helper.broadcast_messages.first[:message]).to include('several items')
    end

    it 'calls proc action method on each item' do
      custom_action = proc { |item| item.drop! }
      helper.perform_bulk_action(
        items: items,
        action_method: custom_action,
        action_name: 'custom_all',
        self_verb: 'process',
        other_verb: 'processes',
        empty_error: 'No items.'
      )

      expect(sword).to have_received(:drop!)
      expect(shield).to have_received(:drop!)
    end
  end

  describe '#handle_all_or_single' do
    let(:all_result) { { success: true, action: 'all' } }
    let(:single_result) { { success: true, action: 'single' } }

    it 'calls all_handler when input is "all"' do
      all_handler = proc { all_result }
      single_handler = proc { |_input| single_result }

      result = helper.handle_all_or_single('all', all_handler: all_handler, single_handler: single_handler)

      expect(result[:action]).to eq('all')
    end

    it 'calls all_handler with uppercase ALL' do
      all_handler = proc { all_result }
      single_handler = proc { |_input| single_result }

      result = helper.handle_all_or_single('ALL', all_handler: all_handler, single_handler: single_handler)

      expect(result[:action]).to eq('all')
    end

    it 'calls all_handler with whitespace' do
      all_handler = proc { all_result }
      single_handler = proc { |_input| single_result }

      result = helper.handle_all_or_single('  all  ', all_handler: all_handler, single_handler: single_handler)

      expect(result[:action]).to eq('all')
    end

    it 'calls single_handler with other input' do
      all_handler = proc { all_result }
      single_handler = proc { |_input| single_result }

      result = helper.handle_all_or_single('sword', all_handler: all_handler, single_handler: single_handler)

      expect(result[:action]).to eq('single')
    end

    it 'passes input to single_handler' do
      all_handler = proc { all_result }
      received_input = nil
      single_handler = proc { |input| received_input = input; single_result }

      helper.handle_all_or_single('my sword', all_handler: all_handler, single_handler: single_handler)

      expect(received_input).to eq('my sword')
    end
  end

  describe '#item_action_with_disambiguation' do
    it 'performs action on matched item' do
      result = helper.item_action_with_disambiguation(
        input: 'iron sword',
        candidates: [sword],
        action_method: :drop!,
        action_name: 'drop',
        self_verb: 'drop',
        other_verb: 'drops'
      )

      expect(result[:success]).to be true
      expect(sword).to have_received(:drop!)
    end

    it 'returns disambiguation when multiple matches' do
      # Both items match 'sword' and 'shield' partial match scenario
      helper_with_multi_match = test_class.new(character, char_instance)

      # Override resolve_item_with_menu to return disambiguation
      allow(helper_with_multi_match).to receive(:resolve_item_with_menu).and_return({
        disambiguation: true,
        result: { options: ['iron sword', 'wooden shield'] }
      })

      result = helper_with_multi_match.item_action_with_disambiguation(
        input: 'item',
        candidates: [sword, shield],
        action_method: :drop!,
        action_name: 'drop',
        self_verb: 'drop',
        other_verb: 'drops'
      )

      expect(result[:disambiguation]).to be true
    end

    it 'returns error when no match found' do
      result = helper.item_action_with_disambiguation(
        input: 'nonexistent',
        candidates: [sword],
        action_method: :drop!,
        action_name: 'drop',
        self_verb: 'drop',
        other_verb: 'drops'
      )

      expect(result[:success]).to be false
    end

    it 'returns error from resolver when no match found' do
      result = helper.item_action_with_disambiguation(
        input: 'missing',
        candidates: [sword],
        action_method: :drop!,
        action_name: 'drop',
        self_verb: 'drop',
        other_verb: 'drops'
      )

      expect(result[:success]).to be false
      expect(result[:message]).to eq('Item not found')
    end

    it 'passes preposition to perform_item_action' do
      result = helper.item_action_with_disambiguation(
        input: 'iron sword',
        candidates: [sword],
        action_method: :hold!,
        action_name: 'get',
        self_verb: 'pick',
        other_verb: 'picks',
        preposition: 'up'
      )

      expect(result[:message]).to eq('You pick up iron sword.')
    end
  end

  describe '#standard_item_command' do
    let(:items_getter) { proc { [sword, shield] } }

    it 'returns error when no items available' do
      empty_getter = proc { [] }
      result = helper.standard_item_command(
        input: 'sword',
        items_getter: empty_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.'
      )

      expect(result[:success]).to be false
      expect(result[:message]).to eq('You have nothing to drop.')
    end

    it 'shows menu when input is empty' do
      result = helper.standard_item_command(
        input: '',
        items_getter: items_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.'
      )

      expect(result[:type]).to eq(:quickmenu)
      expect(result[:prompt]).to eq('What to drop?')
    end

    it 'shows menu when input is nil' do
      result = helper.standard_item_command(
        input: nil,
        items_getter: items_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.'
      )

      expect(result[:type]).to eq(:quickmenu)
    end

    it 'handles "all" keyword when allowed' do
      result = helper.standard_item_command(
        input: 'all',
        items_getter: items_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.',
        allow_all: true
      )

      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq('drop_all')
      expect(sword).to have_received(:drop!)
      expect(shield).to have_received(:drop!)
    end

    it 'does not handle "all" when not allowed' do
      # When allow_all is false, 'all' is treated as an item name search
      result = helper.standard_item_command(
        input: 'all',
        items_getter: items_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.',
        allow_all: false
      )

      # Should fail to find an item named 'all'
      expect(result[:success]).to be false
    end

    it 'performs single item action with input' do
      result = helper.standard_item_command(
        input: 'iron sword',
        items_getter: items_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.'
      )

      expect(result[:success]).to be true
      expect(result[:message]).to eq('You drop iron sword.')
    end

    it 'strips whitespace from input' do
      result = helper.standard_item_command(
        input: '  iron sword  ',
        items_getter: items_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.'
      )

      expect(result[:success]).to be true
      expect(result[:message]).to eq('You drop iron sword.')
    end

    it 'passes preposition to action' do
      result = helper.standard_item_command(
        input: 'iron sword',
        items_getter: items_getter,
        action_method: :hold!,
        action_name: 'get',
        menu_prompt: 'What to pick up?',
        self_verb: 'pick',
        other_verb: 'picks',
        empty_error: 'Nothing here.',
        preposition: 'up'
      )

      expect(result[:message]).to eq('You pick up iron sword.')
    end

    it 'returns error when item not found' do
      result = helper.standard_item_command(
        input: 'nonexistent',
        items_getter: items_getter,
        action_method: :drop!,
        action_name: 'drop',
        menu_prompt: 'What to drop?',
        self_verb: 'drop',
        other_verb: 'drops',
        empty_error: 'You have nothing to drop.'
      )

      expect(result[:success]).to be false
      expect(result[:message]).to eq('Item not found')
    end
  end
end
