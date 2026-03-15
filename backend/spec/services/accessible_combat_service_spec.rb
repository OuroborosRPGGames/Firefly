# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AccessibleCombatService do
  let(:room) { create(:room) }
  let(:fight) { create(:fight, room: room, round_number: 1, status: 'input') }
  let(:viewer) { create(:fight_participant, fight: fight, hex_x: 0, hex_y: 0, current_hp: 5, max_hp: 5) }
  let(:enemy) { create(:fight_participant, :side_2, fight: fight, hex_x: 2, hex_y: 0, current_hp: 3, max_hp: 5) }
  let(:ally) { create(:fight_participant, :side_1, fight: fight, hex_x: 1, hex_y: 0, current_hp: 4, max_hp: 5) }
  let(:service) { described_class.new(fight, viewer) }

  before do
    # Ensure both participants are in the fight
    viewer
    enemy
  end

  describe '#initialize' do
    it 'sets fight and viewer' do
      expect(service.fight).to eq(fight)
      expect(service.viewer).to eq(viewer)
    end
  end

  describe '#combat_status' do
    it 'returns hash with combat status' do
      result = service.combat_status

      expect(result[:round]).to eq(1)
      expect(result[:phase]).to eq('input')
      expect(result[:format]).to eq(:accessible)
      expect(result[:accessible_text]).to include('Combat Status')
    end

    it 'includes viewer status when viewer exists' do
      result = service.combat_status

      expect(result[:your_status]).not_to be_nil
      expect(result[:accessible_text]).to include('Your Status')
    end

    it 'shows enemy count' do
      result = service.combat_status

      expect(result[:enemy_count]).to eq(1)
      expect(result[:accessible_text]).to include('Enemies: 1')
    end

    it 'shows input phase instructions when accepting input' do
      fight.update(status: 'input')
      viewer.update(input_complete: false)

      result = service.combat_status

      expect(result[:accessible_text]).to include('Your turn')
    end
  end

  describe '#list_enemies' do
    it 'returns hash with enemy list' do
      result = service.list_enemies

      expect(result[:enemies]).to be_an(Array)
      expect(result[:enemies].count).to eq(1)
      expect(result[:format]).to eq(:accessible)
    end

    it 'includes accessible text' do
      result = service.list_enemies

      expect(result[:accessible_text]).to include('Enemies (1)')
    end

    it 'returns empty list when no enemies' do
      enemy.destroy
      # Create a new service to reload participants from database
      fresh_service = described_class.new(fight, viewer)
      result = fresh_service.list_enemies

      expect(result[:enemies]).to be_empty
      expect(result[:accessible_text]).to include('No enemies in combat')
    end

    it 'does not include same-side participants in enemies' do
      ally
      fresh_service = described_class.new(fight, viewer)
      result = fresh_service.list_enemies

      expect(result[:enemies].map { |e| e[:id] }).not_to include(ally.id)
      expect(result[:enemies].count).to eq(1)
    end
  end

  describe '#list_allies' do
    it 'returns hash with ally list' do
      result = service.list_allies

      expect(result[:allies]).to be_an(Array)
      expect(result[:format]).to eq(:accessible)
    end

    it 'includes accessible text for no allies' do
      result = service.list_allies

      expect(result[:accessible_text]).to include('No allies in combat')
    end

    it 'lists same-side participants as allies' do
      ally
      fresh_service = described_class.new(fight, viewer)
      result = fresh_service.list_allies

      expect(result[:allies].map { |a| a[:id] }).to include(ally.id)
      expect(result[:accessible_text]).to include('Allies (1)')
    end
  end

  describe '#recommend_target' do
    it 'returns recommendation for best target' do
      result = service.recommend_target

      expect(result[:recommendation]).not_to be_nil
      expect(result[:format]).to eq(:accessible)
    end

    it 'includes reasons for recommendation' do
      result = service.recommend_target

      expect(result[:all_reasons]).to be_an(Array)
    end

    it 'returns no recommendation when no valid targets' do
      enemy.update(is_knocked_out: true)
      result = service.recommend_target

      expect(result[:recommendation]).to be_nil
      expect(result[:reason]).to include('No valid targets')
    end

    it 'prioritizes low HP targets' do
      enemy.update(current_hp: 1, max_hp: 5)
      result = service.recommend_target

      expect(result[:all_reasons]).to include(match(/Low HP|Critical HP/))
    end
  end

  describe '#quick_menu' do
    it 'returns menu options' do
      result = service.quick_menu

      expect(result[:options]).to be_an(Array)
      expect(result[:options].count).to be >= 4
    end

    it 'includes accessible text' do
      result = service.quick_menu

      expect(result[:accessible_text]).to include('List enemies')
      expect(result[:accessible_text]).to include('Recommend target')
    end
  end

  describe '#available_actions' do
    it 'returns can_act true when viewer can act' do
      viewer.update(is_knocked_out: false, input_complete: false)
      result = service.available_actions

      expect(result[:can_act]).to be true
    end

    it 'returns can_act false when knocked out' do
      viewer.update(is_knocked_out: true)
      result = service.available_actions

      expect(result[:can_act]).to be false
      expect(result[:accessible_text]).to include('knocked out')
    end

    it 'returns can_act false when input complete' do
      viewer.update(input_complete: true)
      result = service.available_actions

      expect(result[:can_act]).to be false
      expect(result[:accessible_text]).to include('already submitted')
    end

    it 'lists available actions in accessible text' do
      result = service.available_actions

      expect(result[:accessible_text]).to include('attack')
      expect(result[:accessible_text]).to include('defend')
      expect(result[:accessible_text]).to include('dodge')
    end
  end

  describe 'private methods' do
    describe 'format_phase' do
      it 'formats input phase' do
        fight.update(status: 'input')
        result = service.combat_status

        expect(result[:accessible_text]).to include('Input Phase')
      end

      it 'formats resolving phase' do
        fight.update(status: 'resolving')
        result = service.combat_status

        expect(result[:accessible_text]).to include('Round resolving')
      end
    end

    describe 'target scoring' do
      it 'scores lower HP targets higher' do
        # Place low HP enemy in melee range so it clearly outscores all others
        # (shared `enemy` is also side_2 at hex 2,0 with 3/5 HP and melee range)
        low_hp_enemy = create(:fight_participant, :side_2, fight: fight, hex_x: 2, hex_y: 0, current_hp: 1, max_hp: 5)
        _high_hp_enemy = create(:fight_participant, :side_2, fight: fight, hex_x: 4, hex_y: 0, current_hp: 5, max_hp: 5)

        result = service.recommend_target

        # The recommendation should be the low HP enemy
        expect(result[:recommendation][:id]).to eq(low_hp_enemy.id)
      end
    end
  end

  describe 'participant_to_hash' do
    it 'converts participant to hash with expected keys' do
      result = service.list_enemies

      participant_hash = result[:enemies].first
      expect(participant_hash).to include(
        :id, :name, :current_hp, :max_hp, :hp_percent,
        :is_knocked_out, :hex_x, :hex_y, :distance
      )
    end
  end
end
