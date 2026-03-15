# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutobattleAIService do
  let(:room) { create(:room) }
  let(:fight) { create(:fight, room: room, status: 'input') }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room) }
  let(:participant) do
    create(:fight_participant,
           fight: fight,
           character_instance: char_instance,
           current_hp: 5,
           max_hp: 5,
           autobattle_style: 'aggressive')
  end

  let(:enemy_char) { create(:character) }
  let(:enemy_instance) { create(:character_instance, character: enemy_char, current_room: room) }
  let!(:enemy) do
    create(:fight_participant,
           fight: fight,
           character_instance: enemy_instance,
           current_hp: 3,
           max_hp: 5,
           side: 2)
  end

  let(:service) { described_class.new(participant) }

  describe 'constants' do
    it 'defines MAX_WILLPOWER_SPEND' do
      expect(described_class::MAX_WILLPOWER_SPEND).to eq(2)
    end
  end

  describe '#initialize' do
    it 'initializes with participant' do
      expect(service.participant).to eq(participant)
    end

    it 'inherits from CombatAIService' do
      expect(service).to be_a(CombatAIService)
    end
  end

  describe '#determine_profile' do
    context 'with aggressive style' do
      before { allow(participant).to receive(:autobattle_style).and_return('aggressive') }

      it 'returns high attack weight' do
        svc = described_class.new(participant)
        profile = svc.determine_profile
        expect(profile[:attack_weight]).to eq(0.9)
        expect(profile[:defend_weight]).to eq(0.1)
        expect(profile[:target_strategy]).to eq(:weakest)
      end
    end

    context 'with defensive style' do
      before { allow(participant).to receive(:autobattle_style).and_return('defensive') }

      it 'returns high defense weight' do
        svc = described_class.new(participant)
        profile = svc.determine_profile
        expect(profile[:attack_weight]).to eq(0.4)
        expect(profile[:defend_weight]).to eq(0.6)
        expect(profile[:target_strategy]).to eq(:threat)
        expect(profile[:flee_threshold]).to eq(0.3)
      end
    end

    context 'with supportive style' do
      before { allow(participant).to receive(:autobattle_style).and_return('supportive') }

      it 'returns balanced weights with threat targeting' do
        svc = described_class.new(participant)
        profile = svc.determine_profile
        expect(profile[:attack_weight]).to eq(0.3)
        expect(profile[:defend_weight]).to eq(0.4)
        expect(profile[:target_strategy]).to eq(:threat)
      end
    end

    context 'with no style' do
      before { allow(participant).to receive(:autobattle_style).and_return(nil) }

      it 'returns base profile without modifications' do
        svc = described_class.new(participant)
        profile = svc.determine_profile
        # Base profile from CombatAIService
        expect(profile).to be_a(Hash)
      end
    end

    context 'with unknown style' do
      before { allow(participant).to receive(:autobattle_style).and_return('unknown_style') }

      it 'returns base profile' do
        svc = described_class.new(participant)
        profile = svc.determine_profile
        expect(profile).to be_a(Hash)
      end
    end
  end

  describe '#decide_standard_combat!' do
    before do
      allow(service).to receive(:determine_action).and_return('attack')
      allow(service).to receive(:determine_target).and_return(enemy)
      allow(service).to receive(:determine_movement).and_return({ action: 'stand_still' })
      allow(service).to receive(:available_allies).and_return([])
      allow(service).to receive(:available_enemies).and_return([enemy])
      allow(participant).to receive(:available_willpower_dice).and_return(1.0)
    end

    it 'returns decisions hash with tactic_choice' do
      decisions = service.decide_standard_combat!
      expect(decisions).to have_key(:tactic_choice)
    end

    it 'returns decisions hash with tactic_target_participant_id' do
      decisions = service.decide_standard_combat!
      expect(decisions).to have_key(:tactic_target_participant_id)
    end

    context 'aggressive style' do
      before { allow(participant).to receive(:autobattle_style).and_return('aggressive') }

      it 'sets aggressive tactic' do
        svc = described_class.new(participant)
        allow(svc).to receive(:determine_action).and_return('attack')
        allow(svc).to receive(:determine_target).and_return(enemy)
        allow(svc).to receive(:determine_movement).and_return({ action: 'stand_still' })
        allow(svc).to receive(:available_allies).and_return([])
        allow(svc).to receive(:available_enemies).and_return([enemy])
        allow(participant).to receive(:available_willpower_dice).and_return(1.0)

        decisions = svc.decide_standard_combat!
        expect(decisions[:tactic_choice]).to eq('aggressive')
      end
    end

    context 'defensive style' do
      before { allow(participant).to receive(:autobattle_style).and_return('defensive') }

      it 'sets defensive tactic' do
        svc = described_class.new(participant)
        allow(svc).to receive(:determine_action).and_return('attack')
        allow(svc).to receive(:determine_target).and_return(enemy)
        allow(svc).to receive(:determine_movement).and_return({ action: 'stand_still' })
        allow(svc).to receive(:available_allies).and_return([])
        allow(svc).to receive(:available_enemies).and_return([enemy])
        allow(participant).to receive(:available_willpower_dice).and_return(1.0)

        decisions = svc.decide_standard_combat!
        expect(decisions[:tactic_choice]).to eq('defensive')
      end
    end
  end

  describe 'private methods' do
    describe '#determine_tactic' do
      it 'returns aggressive for aggressive style' do
        allow(participant).to receive(:autobattle_style).and_return('aggressive')
        svc = described_class.new(participant)
        expect(svc.send(:determine_tactic)).to eq('aggressive')
      end

      it 'returns defensive for defensive style' do
        allow(participant).to receive(:autobattle_style).and_return('defensive')
        svc = described_class.new(participant)
        expect(svc.send(:determine_tactic)).to eq('defensive')
      end

      it 'returns guard for supportive style when ally needs protection' do
        allow(participant).to receive(:autobattle_style).and_return('supportive')
        svc = described_class.new(participant)
        allow(svc).to receive(:ally_needs_protection?).and_return(true)
        expect(svc.send(:determine_tactic)).to eq('guard')
      end

      it 'returns nil for supportive style when no ally needs protection' do
        allow(participant).to receive(:autobattle_style).and_return('supportive')
        svc = described_class.new(participant)
        allow(svc).to receive(:ally_needs_protection?).and_return(false)
        expect(svc.send(:determine_tactic)).to be_nil
      end

      it 'returns nil for unknown style' do
        allow(participant).to receive(:autobattle_style).and_return('unknown')
        svc = described_class.new(participant)
        expect(svc.send(:determine_tactic)).to be_nil
      end
    end

    describe '#determine_tactic_target' do
      let(:ally_char) { create(:character) }
      let(:ally_instance) { create(:character_instance, character: ally_char, current_room: room) }
      let(:ally) do
        create(:fight_participant,
               fight: fight,
               character_instance: ally_instance,
               current_hp: 2,
               max_hp: 5,
               side: 1)
      end

      it 'returns nil for non-guard tactics' do
        expect(service.send(:determine_tactic_target, 'aggressive')).to be_nil
        expect(service.send(:determine_tactic_target, 'defensive')).to be_nil
        expect(service.send(:determine_tactic_target, nil)).to be_nil
      end

      it 'returns nil when no allies available' do
        allow(service).to receive(:available_allies).and_return([])
        expect(service.send(:determine_tactic_target, 'guard')).to be_nil
      end

      it 'returns most wounded ally id for guard tactic' do
        allow(service).to receive(:available_allies).and_return([ally])
        allow(service).to receive(:ally_being_targeted?).and_return(false)
        expect(service.send(:determine_tactic_target, 'guard')).to eq(ally.id)
      end

      it 'prioritizes targeted allies' do
        ally2_char = create(:character)
        ally2_instance = create(:character_instance, character: ally2_char, current_room: room)
        ally2 = create(:fight_participant,
                       fight: fight,
                       character_instance: ally2_instance,
                       current_hp: 4,
                       max_hp: 5,
                       side: 1)

        allow(service).to receive(:available_allies).and_return([ally, ally2])
        allow(service).to receive(:ally_being_targeted?).with(ally).and_return(false)
        allow(service).to receive(:ally_being_targeted?).with(ally2).and_return(true)

        # ally2 is being targeted, so should be prioritized even though healthier
        expect(service.send(:determine_tactic_target, 'guard')).to eq(ally2.id)
      end

      it 'returns most wounded targeted ally when multiple are targeted' do
        ally2_char = create(:character)
        ally2_instance = create(:character_instance, character: ally2_char, current_room: room)
        ally2 = create(:fight_participant,
                       fight: fight,
                       character_instance: ally2_instance,
                       current_hp: 4,
                       max_hp: 5,
                       side: 1)

        allow(service).to receive(:available_allies).and_return([ally, ally2])
        allow(service).to receive(:ally_being_targeted?).and_return(true)

        # ally is more wounded, should be selected
        expect(service.send(:determine_tactic_target, 'guard')).to eq(ally.id)
      end
    end

    describe '#ally_needs_protection?' do
      let(:ally_char) { create(:character) }
      let(:ally_instance) { create(:character_instance, character: ally_char, current_room: room) }

      it 'returns false when no allies' do
        allow(service).to receive(:available_allies).and_return([])
        expect(service.send(:ally_needs_protection?)).to be false
      end

      it 'returns true when ally has low HP' do
        low_hp_ally = create(:fight_participant,
                              fight: fight,
                              character_instance: ally_instance,
                              current_hp: 2,
                              max_hp: 5,
                              side: 1)
        allow(service).to receive(:available_allies).and_return([low_hp_ally])
        allow(service).to receive(:ally_being_targeted?).and_return(false)
        expect(service.send(:ally_needs_protection?)).to be true
      end

      it 'returns true when ally is being targeted' do
        healthy_ally = create(:fight_participant,
                               fight: fight,
                               character_instance: ally_instance,
                               current_hp: 5,
                               max_hp: 5,
                               side: 1)
        allow(service).to receive(:available_allies).and_return([healthy_ally])
        allow(service).to receive(:ally_being_targeted?).and_return(true)
        expect(service.send(:ally_needs_protection?)).to be true
      end

      it 'returns false when ally is healthy and not targeted' do
        healthy_ally = create(:fight_participant,
                               fight: fight,
                               character_instance: ally_instance,
                               current_hp: 5,
                               max_hp: 5,
                               side: 1)
        allow(service).to receive(:available_allies).and_return([healthy_ally])
        allow(service).to receive(:ally_being_targeted?).and_return(false)
        expect(service.send(:ally_needs_protection?)).to be false
      end
    end

    describe '#ally_being_targeted?' do
      let(:ally_char) { create(:character) }
      let(:ally_instance) { create(:character_instance, character: ally_char, current_room: room) }
      let(:ally) do
        create(:fight_participant,
               fight: fight,
               character_instance: ally_instance,
               current_hp: 5,
               max_hp: 5,
               side: 1)
      end

      it 'returns true when enemy is targeting ally' do
        allow(enemy).to receive(:target_participant_id).and_return(ally.id)
        allow(service).to receive(:available_enemies).and_return([enemy])
        expect(service.send(:ally_being_targeted?, ally)).to be true
      end

      it 'returns false when no enemy targets ally' do
        allow(enemy).to receive(:target_participant_id).and_return(participant.id)
        allow(service).to receive(:available_enemies).and_return([enemy])
        expect(service.send(:ally_being_targeted?, ally)).to be false
      end
    end

    describe '#allocate_willpower!' do
      let(:decisions) { { main_action: 'attack', ability_id: nil } }

      it 'does nothing when no willpower available' do
        allow(participant).to receive(:available_willpower_dice).and_return(0)
        service.send(:allocate_willpower!, decisions)
        expect(decisions[:willpower_attack]).to be_nil
        expect(decisions[:willpower_defense]).to be_nil
        expect(decisions[:willpower_ability]).to be_nil
      end

      context 'with ability' do
        let(:ability) { instance_double('Ability', id: 1) }

        before do
          allow(participant).to receive(:available_willpower_dice).and_return(2.0)
          allow(Ability).to receive(:[]).with(1).and_return(ability)
        end

        it 'spends 1 die for normal ability' do
          allow(participant).to receive(:willpower_dice).and_return(2.0)
          allow(participant).to receive(:top_powerful_abilities).and_return([])

          decisions[:ability_id] = 1
          service.send(:allocate_willpower!, decisions)
          expect(decisions[:willpower_ability]).to eq(1)
        end

        it 'spends up to max for top ability at max willpower' do
          allow(participant).to receive(:willpower_dice).and_return(3.0)
          allow(participant).to receive(:top_powerful_abilities).and_return([ability])

          decisions[:ability_id] = 1
          service.send(:allocate_willpower!, decisions)
          expect(decisions[:willpower_ability]).to eq(2) # MAX_WILLPOWER_SPEND
        end
      end

      context 'aggressive style without ability' do
        before do
          allow(participant).to receive(:autobattle_style).and_return('aggressive')
          allow(participant).to receive(:available_willpower_dice).and_return(1.0)
        end

        it 'boosts attack roll' do
          svc = described_class.new(participant)
          decisions = { main_action: 'attack', ability_id: nil }
          svc.send(:allocate_willpower!, decisions)
          expect(decisions[:willpower_attack]).to eq(1)
        end
      end

      context 'defensive style without ability' do
        before do
          allow(participant).to receive(:autobattle_style).and_return('defensive')
          allow(participant).to receive(:available_willpower_dice).and_return(1.0)
        end

        it 'boosts defense roll' do
          svc = described_class.new(participant)
          decisions = { main_action: 'attack', ability_id: nil }
          svc.send(:allocate_willpower!, decisions)
          expect(decisions[:willpower_defense]).to eq(1)
        end
      end

      context 'supportive style without ability' do
        before do
          allow(participant).to receive(:autobattle_style).and_return('supportive')
          allow(participant).to receive(:available_willpower_dice).and_return(1.0)
        end

        it 'does not spend willpower on basic attacks' do
          svc = described_class.new(participant)
          decisions = { main_action: 'attack', ability_id: nil }
          svc.send(:allocate_willpower!, decisions)
          expect(decisions[:willpower_attack]).to be_nil
          expect(decisions[:willpower_defense]).to be_nil
        end
      end
    end
  end
end
