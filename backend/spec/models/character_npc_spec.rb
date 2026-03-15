# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Character, 'NPC methods', type: :model do
  describe '#npc?' do
    it 'returns true for NPC characters' do
      character = create(:character, :npc, forename: 'Guard')
      expect(character.npc?).to be true
    end

    it 'returns false for player characters' do
      user = create(:user)
      character = create(:character, forename: 'Player', user: user, is_npc: false)
      expect(character.npc?).to be false
    end
  end

  describe '#unique_npc?' do
    it 'returns true for unique NPCs' do
      character = create(:character, :npc, forename: 'Jane', is_unique_npc: true)
      expect(character.unique_npc?).to be true
    end

    it 'returns false for template NPCs' do
      character = create(:character, :npc, forename: 'Orc', is_unique_npc: false)
      expect(character.unique_npc?).to be false
    end

    it 'returns false for player characters' do
      user = create(:user)
      character = create(:character, forename: 'Player', user: user, is_npc: false)
      expect(character.unique_npc?).to be false
    end
  end

  describe '#template_npc?' do
    it 'returns true for template NPCs' do
      character = create(:character, :npc, forename: 'Orc', is_unique_npc: false)
      expect(character.template_npc?).to be true
    end

    it 'returns false for unique NPCs' do
      character = create(:character, :npc, forename: 'Jane', is_unique_npc: true)
      expect(character.template_npc?).to be false
    end

    it 'returns false for player characters' do
      user = create(:user)
      character = create(:character, forename: 'Player', user: user, is_npc: false)
      expect(character.template_npc?).to be false
    end
  end

  describe '#humanoid_npc?' do
    it 'returns true when archetype is humanoid' do
      archetype = create(:npc_archetype, name: 'Guard', is_humanoid: true)
      character = create(:character, :npc, forename: 'Guard', npc_archetype: archetype)
      expect(character.humanoid_npc?).to be true
    end

    it 'returns false when archetype is not humanoid' do
      archetype = create(:npc_archetype, name: 'Wolf', is_humanoid: false)
      character = create(:character, :npc, forename: 'Wolf', npc_archetype: archetype)
      expect(character.humanoid_npc?).to be false
    end

    it 'returns true when humanoid fields are set (no archetype)' do
      character = create(:character, :npc, forename: 'Jane', npc_hair_desc: 'long brown hair')
      expect(character.humanoid_npc?).to be true
    end

    it 'returns false for player characters' do
      user = create(:user)
      character = create(:character, forename: 'Player', user: user, is_npc: false)
      expect(character.humanoid_npc?).to be false
    end
  end

  describe '#creature_npc?' do
    it 'returns true for non-humanoid NPCs' do
      archetype = create(:npc_archetype, name: 'Wolf', is_humanoid: false)
      character = create(:character, :npc, forename: 'Wolf', npc_archetype: archetype)
      expect(character.creature_npc?).to be true
    end

    it 'returns false for humanoid NPCs' do
      archetype = create(:npc_archetype, name: 'Guard', is_humanoid: true)
      character = create(:character, :npc, forename: 'Guard', npc_archetype: archetype)
      expect(character.creature_npc?).to be false
    end
  end

  describe '#npc_appearance_description' do
    context 'for humanoid NPCs' do
      it 'builds appearance from component parts' do
        character = create(:character, :npc,
          forename: 'Jane',
          npc_body_desc: 'A friendly-looking woman.',
          npc_hair_desc: 'long auburn hair',
          npc_eyes_desc: 'warm brown eyes',
          npc_skin_tone: 'olive'
        )
        desc = character.npc_appearance_description
        expect(desc).to include('A friendly-looking woman.')
        expect(desc).to include('long auburn hair')
        expect(desc).to include('warm brown eyes')
        expect(desc).to include('olive skin')
      end
    end

    context 'for creature NPCs' do
      it 'returns creature description' do
        archetype = create(:npc_archetype, name: 'Wolf', is_humanoid: false)
        character = create(:character, :npc,
          forename: 'Wolf',
          npc_archetype: archetype,
          npc_creature_desc: 'A large gray wolf with piercing yellow eyes.'
        )
        expect(character.npc_appearance_description).to eq('A large gray wolf with piercing yellow eyes.')
      end
    end

    it 'returns nil for player characters' do
      user = create(:user)
      character = create(:character, forename: 'Player', user: user, is_npc: false)
      expect(character.npc_appearance_description).to be_nil
    end
  end

  describe '#npc_clothing_description' do
    it 'returns clothing description for humanoid NPCs' do
      character = create(:character, :npc,
        forename: 'Jane',
        npc_hair_desc: 'long hair',
        npc_clothes_desc: 'a simple dress and apron'
      )
      expect(character.npc_clothing_description).to eq('a simple dress and apron')
    end

    it 'returns nil for creature NPCs' do
      archetype = create(:npc_archetype, name: 'Wolf', is_humanoid: false)
      character = create(:character, :npc,
        forename: 'Wolf',
        npc_archetype: archetype
      )
      expect(character.npc_clothing_description).to be_nil
    end

    it 'returns nil for player characters' do
      user = create(:user)
      character = create(:character, forename: 'Player', user: user, is_npc: false)
      expect(character.npc_clothing_description).to be_nil
    end
  end

  describe '#spawned_from_template?' do
    it 'returns true when npc_template_id is set' do
      template = create(:character, :npc, forename: 'Orc Template', is_unique_npc: false)
      spawn = create(:character, :npc, forename: 'Orc', npc_template_id: template.id)
      expect(spawn.spawned_from_template?).to be true
    end

    it 'returns false when npc_template_id is not set' do
      character = create(:character, :npc, forename: 'Jane')
      expect(character.spawned_from_template?).to be false
    end
  end
end
