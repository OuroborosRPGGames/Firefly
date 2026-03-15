# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcArchetype, type: :model do
  describe 'validations' do
    it 'requires name' do
      archetype = NpcArchetype.new
      expect(archetype.valid?).to be false
    end

    it 'requires unique name' do
      NpcArchetype.create(name: 'Guard')
      archetype = NpcArchetype.new(name: 'Guard')
      expect(archetype.valid?).to be false
    end

    it 'validates behavior_pattern' do
      archetype = NpcArchetype.new(name: 'Test', behavior_pattern: 'invalid')
      expect(archetype.valid?).to be false
    end

    it 'allows valid behavior patterns' do
      archetype = NpcArchetype.create(name: 'Guard', behavior_pattern: 'aggressive')
      expect(archetype.valid?).to be true
    end
  end

  describe 'defaults' do
    let(:archetype) { NpcArchetype.create(name: 'Guard') }

    it 'sets default is_humanoid to true' do
      expect(archetype.is_humanoid).to be true
    end

    it 'sets default name_pattern' do
      expect(archetype.name_pattern).to eq('{archetype}')
    end

    it 'sets default name_counter to 0' do
      expect(archetype.name_counter).to eq(0)
    end

    it 'sets default spawn_health_range' do
      expect(archetype.spawn_health_range).to eq('100-100')
    end

    it 'sets default spawn_level_range' do
      expect(archetype.spawn_level_range).to eq('1-1')
    end
  end

  describe '#create_unique_npc' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Tavern Staff',
        behavior_pattern: 'friendly',
        is_humanoid: true,
        default_hair_desc: 'long auburn hair',
        default_eyes_desc: 'warm brown eyes',
        default_clothes_desc: 'a simple apron'
      )
    end

    it 'creates a unique NPC character' do
      npc = archetype.create_unique_npc('Jane', surname: 'Miller')
      expect(npc).to be_a(Character)
      expect(npc.forename).to eq('Jane')
      expect(npc.surname).to eq('Miller')
      expect(npc.is_npc).to be true
      expect(npc.is_unique_npc).to be true
      expect(npc.npc_archetype).to eq(archetype)
    end

    it 'uses archetype defaults for appearance' do
      npc = archetype.create_unique_npc('Jane')
      expect(npc.npc_hair_desc).to eq('long auburn hair')
      expect(npc.npc_eyes_desc).to eq('warm brown eyes')
      expect(npc.npc_clothes_desc).to eq('a simple apron')
    end

    it 'allows overriding appearance' do
      npc = archetype.create_unique_npc('Jane', hair_desc: 'short dark hair')
      expect(npc.npc_hair_desc).to eq('short dark hair')
    end
  end

  describe '#create_template_npc' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Orc Warrior',
        behavior_pattern: 'aggressive',
        is_humanoid: false,
        default_creature_desc: 'a hulking orc with green skin'
      )
    end

    it 'creates a template NPC character' do
      npc = archetype.create_template_npc
      expect(npc).to be_a(Character)
      expect(npc.forename).to eq('Orc Warrior')
      expect(npc.is_npc).to be true
      expect(npc.is_unique_npc).to be false
      expect(npc.npc_archetype).to eq(archetype)
    end

    it 'uses archetype creature description' do
      npc = archetype.create_template_npc
      expect(npc.npc_creature_desc).to eq('a hulking orc with green skin')
    end
  end

  describe '#generate_spawn_name' do
    let(:archetype) { NpcArchetype.create(name: 'Guard', name_pattern: 'Guard #{n}') }

    it 'increments name_counter' do
      expect { archetype.generate_spawn_name }.to change { archetype.reload.name_counter }.by(1)
    end

    it 'generates name with counter' do
      archetype.update(name_pattern: 'Guard {n}')
      name = archetype.generate_spawn_name
      expect(name).to eq('Guard 1')
    end

    it 'generates name with padded counter' do
      archetype.update(name_pattern: 'Unit-{N}')
      name = archetype.generate_spawn_name
      expect(name).to eq('Unit-001')
    end

    it 'replaces archetype placeholder' do
      archetype.update(name_pattern: 'A {archetype}')
      name = archetype.generate_spawn_name
      expect(name).to eq('A Guard')
    end
  end

  describe '#spawn_instance_from_template' do
    let(:reality) { create(:reality) }
    let(:location) { create(:location) }
    let(:room) { create(:room, location: location) }
    let(:archetype) do
      NpcArchetype.create(
        name: 'Guard',
        spawn_health_range: '80-120',
        spawn_level_range: '2-4'
      )
    end
    let(:template) { archetype.create_template_npc }

    it 'creates a character instance from template' do
      instance = archetype.spawn_instance_from_template(template, room, reality: reality)
      expect(instance).to be_a(CharacterInstance)
      expect(instance.character).to eq(template)
      expect(instance.current_room).to eq(room)
      expect(instance.reality).to eq(reality)
      expect(instance.online).to be true
    end

    it 'sets health from spawn range' do
      instance = archetype.spawn_instance_from_template(template, room, reality: reality)
      expect(instance.health).to be_between(80, 120)
      expect(instance.max_health).to be_between(80, 120)
    end

    it 'sets level from spawn range' do
      instance = archetype.spawn_instance_from_template(template, room, reality: reality)
      expect(instance.level).to be_between(2, 4)
    end
  end
end
