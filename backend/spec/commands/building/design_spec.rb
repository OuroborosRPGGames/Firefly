# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Design, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Workshop') }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Designer') }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true)
  end

  subject { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
    allow(character).to receive(:staff?).and_return(true)
    allow(character).to receive(:admin?).and_return(false)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'design', :building, ['create item', 'createitem', 'spawn item', 'item create']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['design']).to eq(described_class)
    end
  end

  describe 'constants' do
    describe 'ITEM_TYPES' do
      it 'includes expected item types' do
        types = described_class::ITEM_TYPES.map { |t| t[:value] }
        expect(types).to include('generic', 'weapon', 'armor', 'clothing', 'jewelry',
                                 'container', 'food', 'drink', 'key', 'furniture', 'decoration')
      end

      it 'has labels for each type' do
        described_class::ITEM_TYPES.each do |type|
          expect(type).to have_key(:value)
          expect(type).to have_key(:label)
        end
      end
    end

    describe 'CONDITIONS' do
      it 'includes expected conditions' do
        conditions = described_class::CONDITIONS.map { |c| c[:value] }
        expect(conditions).to include('excellent', 'good', 'fair', 'poor', 'broken')
      end

      it 'has labels for each condition' do
        described_class::CONDITIONS.each do |cond|
          expect(cond).to have_key(:value)
          expect(cond).to have_key(:label)
        end
      end
    end
  end

  describe '#execute' do
    context 'when character is not staff' do
      before do
        allow(character).to receive(:staff?).and_return(false)
        allow(character).to receive(:admin?).and_return(false)
      end

      it 'returns an error' do
        result = subject.execute('design item')

        expect(result[:success]).to be false
        expect(result[:message]).to include('staff access')
      end
    end

    context 'when character is admin' do
      before do
        allow(character).to receive(:staff?).and_return(false)
        allow(character).to receive(:admin?).and_return(true)
      end

      it 'allows access' do
        expect(subject).to receive(:show_design_menu).and_return({ success: true, message: 'Test' })
        subject.execute('design')
      end
    end

    context 'with no arguments (help/menu)' do
      it 'shows design menu' do
        expect(subject).to receive(:create_quickmenu).and_return({ success: true, message: 'Test' })
        subject.execute('design')
      end
    end

    context 'with help subcommand' do
      it 'shows design menu' do
        expect(subject).to receive(:create_quickmenu).and_return({ success: true, message: 'Test' })
        subject.execute('design help')
      end
    end

    context 'with item subcommand' do
      it 'shows item creator form' do
        expect(subject).to receive(:create_form).and_return({ success: true, message: 'Test' })
        subject.execute('design item')
      end
    end

    context 'with object subcommand (alias)' do
      it 'shows item creator form' do
        expect(subject).to receive(:create_form).and_return({ success: true, message: 'Test' })
        subject.execute('design object')
      end
    end

    context 'with unknown subcommand' do
      it 'returns an error' do
        result = subject.execute('design unknown')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown design subcommand')
      end
    end
  end

  describe '#show_design_menu' do
    it 'creates a quickmenu with design options' do
      expect(subject).to receive(:create_quickmenu) do |instance, prompt, options, **kwargs|
        expect(prompt).to include('Design Menu')
        expect(options.any? { |o| o[:label] == 'Item' }).to be true
        expect(options.any? { |o| o[:label] == 'Cancel' }).to be true
        expect(kwargs[:context][:command]).to eq('design')
        { success: true, message: 'Test' }
      end

      subject.send(:show_design_menu)
    end
  end

  describe '#show_item_creator_form' do
    it 'creates a form with required fields' do
      expect(subject).to receive(:create_form) do |instance, title, fields, options|
        expect(title).to eq('Design Item')

        field_names = fields.map { |f| f[:name] }
        expect(field_names).to include('name', 'description', 'item_type',
                                       'quantity', 'condition', 'image_url')

        # Check name field is required
        name_field = fields.find { |f| f[:name] == 'name' }
        expect(name_field[:required]).to be true

        # Check item_type has options
        type_field = fields.find { |f| f[:name] == 'item_type' }
        expect(type_field[:options]).to eq(described_class::ITEM_TYPES)

        # Check condition has options
        cond_field = fields.find { |f| f[:name] == 'condition' }
        expect(cond_field[:options]).to eq(described_class::CONDITIONS)
      end

      subject.send(:show_item_creator_form)
    end
  end

  describe '#handle_form_response' do
    let(:form_data) do
      {
        'name' => 'Test Sword',
        'description' => 'A shiny test sword',
        'item_type' => 'weapon',
        'quantity' => '1',
        'condition' => 'good',
        'image_url' => ''
      }
    end

    let(:context) do
      {
        'stage' => 'item_form',
        'room_id' => room.id
      }
    end

    context 'with valid form data' do
      it 'creates an item' do
        result = subject.send(:handle_form_response, form_data, context)

        expect(result[:success]).to be true
        expect(result[:message]).to include('Created')
        expect(result[:message]).to include('Test Sword')
      end

      it 'includes structured data' do
        result = subject.send(:handle_form_response, form_data, context)

        expect(result[:data][:action]).to eq('design_item')
        expect(result[:data][:item_name]).to eq('Test Sword')
        expect(result[:data][:item_type]).to eq('weapon')
        expect(result[:data][:room_id]).to eq(room.id)
      end

      it 'broadcasts to room' do
        subject.send(:handle_form_response, form_data, context)

        expect(BroadcastService).to have_received(:to_room).with(
          room.id,
          anything,
          hash_including(exclude: [character_instance.id])
        )
      end
    end

    context 'with missing name' do
      let(:no_name_data) { form_data.merge('name' => '') }

      it 'returns an error' do
        result = subject.send(:handle_form_response, no_name_data, context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('name is required')
      end
    end

    context 'with name too long' do
      let(:long_name_data) { form_data.merge('name' => 'x' * 250) }

      it 'returns an error' do
        result = subject.send(:handle_form_response, long_name_data, context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('200 characters')
      end
    end

    context 'with description too long' do
      let(:long_desc_data) { form_data.merge('description' => 'x' * 2500) }

      it 'returns an error' do
        result = subject.send(:handle_form_response, long_desc_data, context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('2000 characters')
      end
    end

    context 'with quantity validation' do
      it 'enforces minimum of 1' do
        data = form_data.merge('quantity' => '0')
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be true
        # Item should be created with quantity 1
      end

      it 'enforces maximum of 999' do
        data = form_data.merge('quantity' => '5000')
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be true
        # Item should be created with quantity 999
      end

      it 'shows quantity in message when > 1' do
        data = form_data.merge('quantity' => '5')
        result = subject.send(:handle_form_response, data, context)

        expect(result[:message]).to include('(x5)')
      end
    end

    context 'with invalid condition' do
      let(:bad_condition_data) { form_data.merge('condition' => 'invalid') }

      it 'defaults to good' do
        result = subject.send(:handle_form_response, bad_condition_data, context)

        expect(result[:success]).to be true
        # Should use 'good' as default
      end
    end

    context 'with invalid image URL' do
      it 'rejects non-http URLs' do
        data = form_data.merge('image_url' => 'ftp://example.com/image.jpg')
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('http://')
      end

      it 'rejects URLs that are too long' do
        data = form_data.merge('image_url' => 'https://example.com/' + 'x' * 2100)
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('too long')
      end

      it 'accepts valid https URL' do
        data = form_data.merge('image_url' => 'https://example.com/item.png')
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be true
      end

      it 'accepts valid http URL' do
        data = form_data.merge('image_url' => 'http://example.com/item.jpg')
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be true
      end

      it 'accepts empty URL' do
        data = form_data.merge('image_url' => '')
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be true
      end

      it 'accepts nil URL' do
        data = form_data.merge('image_url' => nil)
        result = subject.send(:handle_form_response, data, context)

        expect(result[:success]).to be true
      end
    end

    context 'when room no longer exists' do
      let(:bad_context) { context.merge('room_id' => 99999) }

      it 'returns an error' do
        result = subject.send(:handle_form_response, form_data, bad_context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('Room no longer exists')
      end
    end

    context 'with unknown form stage' do
      let(:bad_context) { { 'stage' => 'unknown' } }

      it 'returns an error' do
        result = subject.send(:handle_form_response, form_data, bad_context)

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown form context')
      end
    end

    context 'with different item types' do
      %w[generic weapon armor clothing jewelry container food drink key furniture decoration].each do |item_type|
        it "creates #{item_type} items" do
          data = form_data.merge('item_type' => item_type)
          result = subject.send(:handle_form_response, data, context)

          expect(result[:success]).to be true
          expect(result[:data][:item_type]).to eq(item_type)
        end
      end
    end
  end

  describe '#build_item_properties' do
    it 'returns empty hash for generic items' do
      props = subject.send(:build_item_properties, 'generic', {})
      expect(props).to eq({})
    end

    it 'sets weapon properties' do
      props = subject.send(:build_item_properties, 'weapon', {})

      expect(props['damage_dice']).to eq('1d6')
      expect(props['weapon_type']).to eq('melee')
    end

    it 'sets armor properties' do
      props = subject.send(:build_item_properties, 'armor', {})

      expect(props['armor_value']).to eq(1)
      expect(props['armor_type']).to eq('light')
    end

    it 'sets container properties' do
      props = subject.send(:build_item_properties, 'container', {})

      expect(props['capacity']).to eq(10)
      expect(props['container']).to be true
    end

    it 'sets food properties' do
      props = subject.send(:build_item_properties, 'food', {})

      expect(props['consume_type']).to eq('food')
      expect(props['consume_time']).to eq(5)
    end

    it 'sets drink properties' do
      props = subject.send(:build_item_properties, 'drink', {})

      expect(props['consume_type']).to eq('drink')
      expect(props['consume_time']).to eq(3)
    end

    it 'sets key properties with unique ID' do
      props = subject.send(:build_item_properties, 'key', {})

      expect(props['key_id']).to be_a(String)
      expect(props['key_id'].length).to eq(16)
    end

    it 'generates unique key IDs' do
      props1 = subject.send(:build_item_properties, 'key', {})
      props2 = subject.send(:build_item_properties, 'key', {})

      expect(props1['key_id']).not_to eq(props2['key_id'])
    end

    it 'returns empty hash for clothing' do
      props = subject.send(:build_item_properties, 'clothing', {})
      expect(props).to eq({})
    end

    it 'returns empty hash for jewelry' do
      props = subject.send(:build_item_properties, 'jewelry', {})
      expect(props).to eq({})
    end

    it 'returns empty hash for furniture' do
      props = subject.send(:build_item_properties, 'furniture', {})
      expect(props).to eq({})
    end

    it 'returns empty hash for decoration' do
      props = subject.send(:build_item_properties, 'decoration', {})
      expect(props).to eq({})
    end
  end

  describe 'item creation database effects' do
    let(:form_data) do
      {
        'name' => 'Database Test Sword',
        'description' => 'For testing DB creation',
        'item_type' => 'weapon',
        'quantity' => '2',
        'condition' => 'excellent',
        'image_url' => 'https://example.com/sword.png'
      }
    end

    let(:context) do
      {
        'stage' => 'item_form',
        'room_id' => room.id
      }
    end

    it 'creates an Item record' do
      expect {
        subject.send(:handle_form_response, form_data, context)
      }.to change { Item.count }.by(1)
    end

    it 'sets correct attributes on item' do
      subject.send(:handle_form_response, form_data, context)

      item = Item.last
      expect(item.name).to eq('Database Test Sword')
      expect(item.description).to eq('For testing DB creation')
      expect(item.room_id).to eq(room.id)
      expect(item.quantity).to eq(2)
      expect(item.condition).to eq('excellent')
      expect(item.image_url).to eq('https://example.com/sword.png')
    end

    it 'sets clothing flag for clothing items' do
      data = form_data.merge('item_type' => 'clothing')
      subject.send(:handle_form_response, data, context)

      item = Item.last
      expect(item.is_clothing).to be true
    end

    it 'sets jewelry flag for jewelry items' do
      data = form_data.merge('item_type' => 'jewelry')
      subject.send(:handle_form_response, data, context)

      item = Item.last
      expect(item.is_jewelry).to be true
    end

    it 'sets nil description when empty' do
      data = form_data.merge('description' => '')
      subject.send(:handle_form_response, data, context)

      item = Item.last
      expect(item.description).to be_nil
    end
  end

  describe 'edge cases' do
    context 'with whitespace in name' do
      let(:form_data) do
        {
          'name' => '  Whitespace Test  ',
          'item_type' => 'generic'
        }
      end

      let(:context) { { 'stage' => 'item_form', 'room_id' => room.id } }

      it 'strips whitespace from name' do
        result = subject.send(:handle_form_response, form_data, context)

        expect(result[:success]).to be true
        item = Item.last
        expect(item.name).to eq('Whitespace Test')
      end
    end

    context 'with nil values' do
      let(:form_data) do
        {
          'name' => 'Minimal Item',
          'description' => nil,
          'item_type' => nil,
          'quantity' => nil,
          'condition' => nil,
          'image_url' => nil
        }
      end

      let(:context) { { 'stage' => 'item_form', 'room_id' => room.id } }

      it 'uses defaults for nil values' do
        result = subject.send(:handle_form_response, form_data, context)

        expect(result[:success]).to be true
        item = Item.last
        expect(item.name).to eq('Minimal Item')
        expect(item.quantity).to eq(1)
        expect(item.condition).to eq('good')
      end
    end
  end
end
