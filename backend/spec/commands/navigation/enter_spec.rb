# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Enter do
  let(:location) { create(:location) }
  let(:outer) { create(:room, location: location, name: 'Building Lobby', min_x: 0, max_x: 200, min_y: 0, max_y: 200, indoors: false) }
  let(:shop) { create(:room, location: location, name: 'Coffee Shop', min_x: 50, max_x: 150, min_y: 50, max_y: 150, indoors: true) }
  let(:character) { create(:character) }
  let(:instance) { create(:character_instance, character: character, current_room: outer, x: 100, y: 100, z: 0) }

  subject(:command) { described_class.new(instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'enter' : "enter #{args}"
    command.execute(input)
  end

  describe '#execute' do
    it 'enters a contained room by name' do
      # Ensure shop exists before executing command
      shop # trigger lazy let
      # shop is contained within outer (50-150 is within 0-200)
      result = execute_command('coffee shop')

      expect(result[:success]).to be true
      expect(instance.reload.current_room_id).to eq(shop.id)
    end

    it 'matches partial names' do
      shop # trigger lazy let
      result = execute_command('coffee')

      expect(result[:success]).to be true
      expect(instance.reload.current_room_id).to eq(shop.id)
    end

    it 'is case insensitive' do
      shop # trigger lazy let
      result = execute_command('COFFEE SHOP')

      expect(result[:success]).to be true
      expect(instance.reload.current_room_id).to eq(shop.id)
    end

    it 'fails when room not found' do
      result = execute_command('nonexistent')

      expect(result[:success]).to be false
      expect(result[:error]).to include("can't find")
    end

    it 'requires a target' do
      result = execute_command('')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Enter where?')
    end

    it 'requires a target when nil' do
      result = execute_command(nil)

      expect(result[:success]).to be false
      expect(result[:message]).to include('Enter where?')
    end

    it 'positions character at center of destination room' do
      shop # trigger lazy let
      result = execute_command('coffee shop')

      expect(result[:success]).to be true
      instance.reload
      # Center of shop (50-150, 50-150) should be (100, 100)
      expect(instance.x).to be_within(1).of(100)
      expect(instance.y).to be_within(1).of(100)
    end

    it 'returns look result merged with movement info' do
      shop # trigger lazy let
      result = execute_command('coffee shop')

      expect(result[:success]).to be true
      expect(result[:moved_from]).to eq(outer.id)
      expect(result[:moved_to]).to eq(shop.id)
      expect(result[:action]).to eq('enter')
    end

    context 'with adjacent rooms' do
      let(:hallway) { create(:room, location: location, name: 'Hallway', min_x: 0, max_x: 100, min_y: 0, max_y: 100, indoors: false) }
      let(:kitchen) { create(:room, location: location, name: 'Kitchen', min_x: 0, max_x: 100, min_y: 100, max_y: 200, indoors: false) }
      let(:instance_in_hallway) { create(:character_instance, character: character, current_room: hallway, x: 50, y: 50, z: 0) }

      it 'can enter adjacent room by name' do
        kitchen # trigger lazy let
        cmd = described_class.new(instance_in_hallway)
        result = cmd.execute('enter kitchen')

        expect(result[:success]).to be true
        expect(instance_in_hallway.reload.current_room_id).to eq(kitchen.id)
      end
    end
  end
end
