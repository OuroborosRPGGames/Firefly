# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Reskin, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  let(:unified_type) do
    UnifiedObjectType.create(
      name: 'sword',
      category: 'Sword'
    )
  end

  let(:pattern1) do
    Pattern.create(
      description: 'Iron Sword',
      unified_object_type_id: unified_type.id
    )
  end

  let(:pattern2) do
    Pattern.create(
      description: 'Steel Sword',
      unified_object_type_id: unified_type.id
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with stored item' do
      let!(:sword) do
        Item.create(
          name: 'Iron Sword',
          character_instance_id: character_instance.id,
          pattern_id: pattern1.id,
          quantity: 1,
          condition: 'good',
          stored: true
        )
      end

      before do
        # Ensure pattern2 exists
        pattern2
      end

      it 'lists available patterns' do
        result = command.execute('reskin iron sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Steel Sword')
        expect(result[:data][:action]).to eq('reskin_list')
      end

      it 'reskins to specific pattern' do
        result = command.execute('reskin iron sword to steel')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Reskinned')
        expect(result[:message]).to include('Steel Sword')
        expect(sword.reload.name).to eq('Steel Sword')
        expect(sword.pattern_id).to eq(pattern2.id)
      end
    end

    context 'with non-stored item' do
      let!(:sword) do
        Item.create(
          name: 'Iron Sword',
          character_instance_id: character_instance.id,
          pattern_id: pattern1.id,
          quantity: 1,
          condition: 'good',
          stored: false
        )
      end

      it 'returns error' do
        result = command.execute('reskin iron sword')

        expect(result[:success]).to be false
        expect(result[:error]).to include("don't have any stored items")
      end
    end

    context 'with empty input' do
      it 'returns error' do
        result = command.execute('reskin')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Reskin what')
      end
    end

    context 'with aliases' do
      it 'works with restyle alias' do
        command_class, _words = Commands::Base::Registry.find_command('restyle')
        expect(command_class).to eq(Commands::Inventory::Reskin)
      end
    end
  end
end
