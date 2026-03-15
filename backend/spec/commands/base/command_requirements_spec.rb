# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Base::Command, 'requirements system' do
  let(:room) { create(:room, room_type: 'standard') }
  let(:water_room) { create(:room, room_type: 'water') }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, status: 'alive')
  end

  # Test command that requires combat
  let(:combat_command_class) do
    Class.new(Commands::Base::Command) do
      command_name 'test_combat'
      requires_combat
      requires_alive

      def perform_command(_parsed_input)
        success_result("Combat action!")
      end
    end
  end

  # Test command that requires specific room type
  let(:water_command_class) do
    Class.new(Commands::Base::Command) do
      command_name 'test_swim'
      requires_room_type :water, :lake
      requires_conscious

      def perform_command(_parsed_input)
        success_result("Swimming!")
      end
    end
  end

  # Test command with custom lambda requirement
  let(:custom_requirement_class) do
    Class.new(Commands::Base::Command) do
      command_name 'test_custom'
      requires ->(cmd) { cmd.character_instance.health.to_i >= 50 },
               message: "You need at least 50 health."

      def perform_command(_parsed_input)
        success_result("Custom action!")
      end
    end
  end

  describe 'requirements DSL' do
    describe '.requires' do
      it 'stores requirements on the class' do
        expect(combat_command_class.requirements).not_to be_empty
        expect(combat_command_class.requirements.first[:type]).to eq(:character_state)
      end
    end

    describe '.requires_combat' do
      it 'adds an in_combat character state requirement' do
        combat_req = combat_command_class.requirements.find { |r| r[:args]&.include?(:in_combat) }
        expect(combat_req).not_to be_nil
        expect(combat_req[:message]).to include('combat')
      end
    end

    describe '.requires_room_type' do
      it 'adds room type requirements' do
        room_req = water_command_class.requirements.find { |r| r[:type] == :room_type }
        expect(room_req).not_to be_nil
        expect(room_req[:args]).to include(:water)
        expect(room_req[:args]).to include(:lake)
      end
    end

    describe '.requires_alive' do
      it 'adds alive character state requirement' do
        alive_req = combat_command_class.requirements.find { |r| r[:args]&.include?(:alive) }
        expect(alive_req).not_to be_nil
      end
    end

    describe '.requires_conscious' do
      it 'adds conscious character state requirement' do
        conscious_req = water_command_class.requirements.find { |r| r[:args]&.include?(:conscious) }
        expect(conscious_req).not_to be_nil
      end
    end
  end

  describe '#unmet_requirements' do
    context 'when character is not in combat' do
      let(:command) { combat_command_class.new(character_instance) }

      before do
        allow(character_instance).to receive(:in_combat?).and_return(false)
      end

      it 'returns unmet combat requirement' do
        unmet = command.unmet_requirements
        expect(unmet).not_to be_empty
        expect(unmet.first[:args]).to include(:in_combat)
      end
    end

    context 'when character is in combat' do
      let(:command) { combat_command_class.new(character_instance) }

      before do
        allow(character_instance).to receive(:in_combat?).and_return(true)
        allow(character_instance).to receive(:status).and_return('alive')
      end

      it 'returns empty array when all requirements met' do
        unmet = command.unmet_requirements
        expect(unmet).to be_empty
      end
    end

    context 'when in wrong room type' do
      let(:command) { water_command_class.new(character_instance) }

      it 'returns unmet room type requirement' do
        unmet = command.unmet_requirements
        expect(unmet).not_to be_empty
        expect(unmet.first[:type]).to eq(:room_type)
      end
    end

    context 'when in correct room type' do
      let(:water_instance) do
        create(:character_instance, character: character, current_room: water_room, reality: reality, status: 'alive')
      end
      let(:command) { water_command_class.new(water_instance) }

      it 'returns empty array for room type requirements' do
        unmet = command.unmet_requirements
        room_unmet = unmet.select { |r| r[:type] == :room_type }
        expect(room_unmet).to be_empty
      end
    end
  end

  describe '#requirements_met?' do
    context 'when all requirements are met' do
      let(:water_instance) do
        create(:character_instance, character: character, current_room: water_room, reality: reality, status: 'alive')
      end
      let(:command) { water_command_class.new(water_instance) }

      it 'returns true' do
        expect(command.requirements_met?).to be true
      end
    end

    context 'when requirements are not met' do
      let(:command) { water_command_class.new(character_instance) }

      it 'returns false' do
        expect(command.requirements_met?).to be false
      end
    end
  end

  describe '#execute with requirements' do
    context 'when requirements are not met' do
      let(:command) { water_command_class.new(character_instance) }

      it 'returns error result' do
        result = command.execute('test_swim')
        expect(result[:success]).to be false
        expect(result[:error]).to be_a(String)
      end
    end

    context 'when requirements are met' do
      let(:water_instance) do
        create(:character_instance, character: character, current_room: water_room, reality: reality, status: 'alive')
      end
      let(:command) { water_command_class.new(water_instance) }

      it 'executes successfully' do
        result = command.execute('test_swim')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Swimming')
      end
    end
  end

  describe 'custom lambda requirements' do
    let(:command) { custom_requirement_class.new(character_instance) }

    context 'when lambda returns false' do
      before do
        allow(character_instance).to receive(:health).and_return(25)
      end

      it 'returns custom error message' do
        result = command.execute('test_custom')
        expect(result[:success]).to be false
        expect(result[:error]).to include('50 health')
      end
    end

    context 'when lambda returns true' do
      before do
        allow(character_instance).to receive(:health).and_return(100)
      end

      it 'executes successfully' do
        result = command.execute('test_custom')
        expect(result[:success]).to be true
      end
    end
  end

  describe 'character state checks' do
    let(:test_state_class) do
      Class.new(Commands::Base::Command) do
        command_name 'test_state'
        requires_standing

        def perform_command(_parsed_input)
          success_result("Standing action!")
        end
      end
    end

    context 'when character is standing' do
      let(:command) { test_state_class.new(character_instance) }

      before do
        allow(character_instance).to receive(:standing?).and_return(true)
      end

      it 'allows execution' do
        expect(command.requirements_met?).to be true
      end
    end

    context 'when character is sitting' do
      let(:command) { test_state_class.new(character_instance) }

      before do
        allow(character_instance).to receive(:standing?).and_return(false)
      end

      it 'blocks execution' do
        expect(command.requirements_met?).to be false
      end
    end
  end
end
