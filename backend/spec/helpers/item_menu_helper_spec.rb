# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ItemMenuHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'instance methods' do
    it 'defines item_selection_menu' do
      expect(described_class.instance_methods).to include(:item_selection_menu)
    end

    it 'defines character_selection_menu' do
      expect(described_class.instance_methods).to include(:character_selection_menu)
    end

    it 'defines clothing_selection_menu' do
      expect(described_class.instance_methods).to include(:clothing_selection_menu)
    end

    it 'defines custom_selection_menu' do
      expect(described_class.instance_methods).to include(:custom_selection_menu)
    end
  end

  # Create a test class that includes the helper with required dependencies
  let(:test_class) do
    Class.new do
      include ItemMenuHelper

      attr_accessor :character_instance

      # Mock the create_quickmenu method that the helper depends on
      def create_quickmenu(char_instance, prompt, options, context:)
        { quickmenu: { prompt: prompt, options: options, context: context } }
      end
    end
  end

  let(:char_instance) { double(id: 1) }
  let(:instance) do
    obj = test_class.new
    obj.character_instance = char_instance
    obj
  end

  describe '#item_selection_menu' do
    let(:items) do
      [
        double(id: 1, name: 'Sword', item_type: 'weapon'),
        double(id: 2, name: 'Shield', item_type: 'armor')
      ]
    end

    it 'builds quickmenu with items' do
      result = instance.item_selection_menu(items, 'Select an item:', command: 'drop')
      expect(result).to be_a(Hash)
      expect(result[:quickmenu]).to be_a(Hash)
    end

    it 'includes prompt in menu' do
      result = instance.item_selection_menu(items, 'Choose one:', command: 'get')
      expect(result[:quickmenu][:prompt]).to eq('Choose one:')
    end

    it 'creates options from items with cancel option' do
      result = instance.item_selection_menu(items, 'Select:', command: 'drop')
      # 2 items + cancel = 3 options
      expect(result[:quickmenu][:options].length).to eq(3)
    end

    it 'includes item names as labels' do
      result = instance.item_selection_menu(items, 'Select:', command: 'drop')
      labels = result[:quickmenu][:options].map { |o| o[:label] }
      expect(labels).to include('Sword', 'Shield', 'Cancel')
    end

    it 'uses item_type as description by default' do
      result = instance.item_selection_menu(items, 'Select:', command: 'drop')
      first_option = result[:quickmenu][:options].first
      expect(first_option[:description]).to eq('weapon')
    end

    it 'stores item data in context' do
      result = instance.item_selection_menu(items, 'Select:', command: 'drop')
      context = result[:quickmenu][:context]
      expect(context[:command]).to eq('drop')
      expect(context[:items]).to be_an(Array)
      expect(context[:items].first[:name]).to eq('Sword')
    end
  end

  describe '#character_selection_menu' do
    let(:characters) do
      [
        double(id: 1, character_id: 10, character: double(full_name: 'Alice', forename: 'Alice', short_desc: 'A warrior', display_name_for: 'Alice')),
        double(id: 2, character_id: 20, character: double(full_name: 'Bob', forename: 'Bob', short_desc: 'A mage', display_name_for: 'Bob'))
      ]
    end

    it 'builds quickmenu with characters' do
      result = instance.character_selection_menu(characters, 'Select:', command: 'follow')
      expect(result).to be_a(Hash)
    end

    it 'creates options from character names' do
      result = instance.character_selection_menu(characters, 'Who?', command: 'give')
      options = result[:quickmenu][:options]
      labels = options.map { |o| o[:label] }
      expect(labels).to include('Alice', 'Bob', 'Cancel')
    end

    it 'stores character data in context' do
      result = instance.character_selection_menu(characters, 'Select:', command: 'follow')
      context = result[:quickmenu][:context]
      expect(context[:characters]).to be_an(Array)
      expect(context[:characters].first[:name]).to eq('Alice')
    end
  end

  describe '#clothing_selection_menu' do
    let(:clothing) do
      [
        double(id: 1, name: 'Red Shirt', jewelry?: false),
        double(id: 2, name: 'Gold Ring', jewelry?: true)
      ]
    end

    it 'builds quickmenu with clothing items' do
      result = instance.clothing_selection_menu(clothing, 'Select clothing:', command: 'wear')
      expect(result).to be_a(Hash)
    end

    it 'uses jewelry? method for descriptions' do
      result = instance.clothing_selection_menu(clothing, 'Select:', command: 'wear')
      options = result[:quickmenu][:options]
      # First item is not jewelry
      expect(options[0][:description]).to eq('clothing')
      # Second item is jewelry
      expect(options[1][:description]).to eq('jewelry')
    end
  end

  describe '#custom_selection_menu' do
    let(:collection) do
      [
        double(id: 1, value: 'A'),
        double(id: 2, value: 'B')
      ]
    end

    it 'builds quickmenu with custom label proc' do
      result = instance.custom_selection_menu(
        collection,
        'Custom prompt:',
        command: 'custom',
        label_proc: ->(item) { "Item #{item.value}" }
      )
      expect(result).to be_a(Hash)
    end

    it 'uses label_proc for option labels' do
      result = instance.custom_selection_menu(
        collection,
        'Select:',
        command: 'test',
        label_proc: ->(item) { "Item #{item.value}" }
      )
      options = result[:quickmenu][:options]
      labels = options.map { |o| o[:label] }
      expect(labels).to include('Item A', 'Item B', 'Cancel')
    end

    it 'uses description_proc when provided' do
      result = instance.custom_selection_menu(
        collection,
        'Select:',
        command: 'test',
        label_proc: ->(item) { item.value },
        description_proc: ->(item) { "Desc for #{item.value}" }
      )
      options = result[:quickmenu][:options]
      expect(options[0][:description]).to eq('Desc for A')
    end
  end
end
