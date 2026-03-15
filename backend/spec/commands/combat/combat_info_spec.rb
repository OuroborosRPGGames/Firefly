# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Combat::CombatInfo, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality,
           status: 'alive', stance: 'standing', online: true)
  end

  let(:enemy_user) { create(:user) }
  let(:enemy_character) { create(:character, user: enemy_user, forename: 'Bob') }
  let(:enemy_instance) do
    create(:character_instance, character: enemy_character, current_room: room, reality: reality,
           status: 'alive', stance: 'standing', online: true)
  end

  # Use shared example for standard metadata tests
  it_behaves_like "command metadata", 'combat', :combat, ['cb', 'ci', 'battle']

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not in combat' do
      it 'returns error about not being in combat' do
        result = command.execute('combat')
        expect(result[:success]).to be false
        expect(result[:error]).to include('not in combat')
      end

      it 'suggests how to start combat' do
        result = command.execute('combat')
        expect(result[:error]).to include('attack')
      end
    end

    context 'when in combat' do
      let!(:fight) do
        enemy_instance # Ensure enemy exists
        FightService.start_fight(room: room, initiator: character_instance, target: enemy_instance)
      end

      describe 'status subcommand (default)' do
        it 'returns success' do
          result = command.execute('combat')
          expect(result[:success]).to be true
        end

        it 'shows combat status' do
          result = command.execute('combat status')
          expect(result[:success]).to be true
        end
      end

      describe 'enemies subcommand' do
        it 'lists enemies' do
          result = command.execute('combat enemies')
          expect(result[:success]).to be true
        end

        it 'works with e alias' do
          result = command.execute('combat e')
          expect(result[:success]).to be true
        end
      end

      describe 'allies subcommand' do
        it 'lists allies' do
          result = command.execute('combat allies')
          expect(result[:success]).to be true
        end

        it 'works with a alias' do
          result = command.execute('combat a')
          expect(result[:success]).to be true
        end
      end

      describe 'recommend subcommand' do
        it 'shows recommendation' do
          result = command.execute('combat recommend')
          expect(result[:success]).to be true
        end

        it 'works with rec alias' do
          result = command.execute('combat rec')
          expect(result[:success]).to be true
        end
      end

      describe 'actions subcommand' do
        it 'shows available actions' do
          result = command.execute('combat actions')
          expect(result[:success]).to be true
        end

        it 'works with act alias' do
          result = command.execute('combat act')
          expect(result[:success]).to be true
        end
      end

      describe 'menu subcommand' do
        it 'shows quick menu' do
          result = command.execute('combat menu')
          expect(result[:success]).to be true
        end

        it 'works with m alias' do
          result = command.execute('combat m')
          expect(result[:success]).to be true
        end
      end

      describe 'help subcommand' do
        it 'shows help' do
          result = command.execute('combat help')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Combat Commands')
        end

        it 'works with h alias' do
          result = command.execute('combat h')
          expect(result[:success]).to be true
        end

        it 'works with ? alias' do
          result = command.execute('combat ?')
          expect(result[:success]).to be true
        end
      end

      describe 'unknown subcommand' do
        it 'returns error' do
          result = command.execute('combat unknown_subcommand')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Unknown')
        end

        it 'suggests using help' do
          result = command.execute('combat unknown_subcommand')
          expect(result[:error]).to include('help')
        end
      end
    end

    context 'with aliases' do
      it 'works with cb alias' do
        result = command.execute('cb')
        expect(result[:success]).to be false # Not in combat
        expect(result[:error]).to include('not in combat')
      end

      it 'works with battle alias' do
        result = command.execute('battle')
        expect(result[:success]).to be false # Not in combat
        expect(result[:error]).to include('not in combat')
      end
    end
  end

  describe '#can_execute?' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns true for any character' do
      expect(command.can_execute?).to be true
    end
  end

  describe 'additional metadata' do
    it 'has usage info' do
      expect(described_class.usage).to be_a(String)
      expect(described_class.usage).to include('combat')
    end

    it 'has examples' do
      expect(described_class.examples).to be_an(Array)
      expect(described_class.examples.length).to be > 0
    end
  end
end
