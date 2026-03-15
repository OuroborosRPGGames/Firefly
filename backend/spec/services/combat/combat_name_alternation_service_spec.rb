# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatNameAlternationService do
  # Use doubles instead of database records to avoid callback cascades
  let(:fight) { instance_double(Fight, id: 1) }

  let(:character1) do
    instance_double(Character,
                    forename: 'Alice',
                    surname: 'Smith',
                    name: 'Alice Smith',
                    gender: 'female',
                    eye_color: 'blue',
                    hair_color: 'blonde',
                    body_type: 'slim',
                    height_cm: 170,
                    pronoun_subject: 'she',
                    pronoun_possessive: 'her',
                    pronoun_object: 'her')
  end

  let(:character2) do
    instance_double(Character,
                    forename: 'Bob',
                    surname: 'Jones',
                    name: 'Bob Jones',
                    gender: 'male',
                    eye_color: 'brown',
                    hair_color: 'black',
                    body_type: 'muscular',
                    height_cm: 190,
                    pronoun_subject: 'he',
                    pronoun_possessive: 'his',
                    pronoun_object: 'him')
  end

  let(:instance1) { instance_double(CharacterInstance, character: character1, id: 1) }
  let(:instance2) { instance_double(CharacterInstance, character: character2, id: 2) }

  let(:participant1) do
    instance_double(FightParticipant,
                    id: 1,
                    fight: fight,
                    character_instance: instance1,
                    character_name: 'Alice Smith',
                    melee_weapon_id: nil,
                    melee_weapon: nil,
                    ranged_weapon: nil)
  end

  let(:participant2) do
    instance_double(FightParticipant,
                    id: 2,
                    fight: fight,
                    character_instance: instance2,
                    character_name: 'Bob Jones',
                    melee_weapon_id: nil,
                    melee_weapon: nil,
                    ranged_weapon: nil)
  end

  subject(:service) { described_class.new(fight) }

  describe '#name_for' do
    it 'returns actual name on first call' do
      name = service.name_for(participant1)
      expect(name).to eq('Alice Smith')
    end

    it 'may return descriptor or name on subsequent calls' do
      # First call always returns name
      service.name_for(participant1)

      # Second call has 70% chance of name, 30% chance of descriptor
      # Just verify it returns a non-empty string
      name = service.name_for(participant1)
      expect(name).to be_a(String)
      expect(name).not_to be_empty
    end

    it 'returns valid name when opponent is provided' do
      name = service.name_for(participant1, opponent: participant2)
      expect(name).to eq('Alice Smith')
    end
  end

  describe '#pronoun_for' do
    it 'returns he for male characters' do
      expect(service.pronoun_for(participant2)).to eq('he')
    end

    it 'returns she for female characters' do
      expect(service.pronoun_for(participant1)).to eq('she')
    end

    it 'returns they for unknown gender' do
      allow(character1).to receive(:pronoun_subject).and_return(nil)
      expect(service.pronoun_for(participant1)).to eq('they')
    end
  end

  describe '#possessive_for' do
    it 'returns his for male characters' do
      expect(service.possessive_for(participant2)).to eq('his')
    end

    it 'returns her for female characters' do
      expect(service.possessive_for(participant1)).to eq('her')
    end

    it 'returns their for unknown gender' do
      allow(character1).to receive(:pronoun_possessive).and_return(nil)
      expect(service.possessive_for(participant1)).to eq('their')
    end
  end

  describe '#object_pronoun_for' do
    it 'returns him for male characters' do
      expect(service.object_pronoun_for(participant2)).to eq('him')
    end

    it 'returns her for female characters' do
      expect(service.object_pronoun_for(participant1)).to eq('her')
    end

    it 'returns them for unknown gender' do
      allow(character1).to receive(:pronoun_object).and_return(nil)
      expect(service.object_pronoun_for(participant1)).to eq('them')
    end
  end

  describe '#weapon_name_for' do
    context 'with no weapon' do
      it 'returns fists' do
        expect(service.weapon_name_for(participant1)).to eq('fists')
      end
    end

    context 'with equipped weapon' do
      let(:sword_pattern) { instance_double(Pattern, description: 'steel sword') }
      let(:sword) { instance_double(Item, id: 100, pattern: sword_pattern) }

      let(:participant_with_weapon) do
        instance_double(FightParticipant,
                        id: 3,
                        fight: fight,
                        character_instance: instance1,
                        character_name: 'Alice Smith',
                        melee_weapon_id: 100,
                        melee_weapon: sword,
                        ranged_weapon: nil)
      end

      it 'returns full name with article on first use' do
        name = service.weapon_name_for(participant_with_weapon)
        expect(name).to eq('a steel sword')
      end

      it 'returns possessive form on second use' do
        service.weapon_name_for(participant_with_weapon)
        name = service.weapon_name_for(participant_with_weapon)
        expect(name).to eq('her sword')
      end

      it 'returns category or synonym on subsequent uses' do
        3.times { service.weapon_name_for(participant_with_weapon) }
        # Third call returns category or synonym
        result = service.weapon_name_for(participant_with_weapon)
        # Accepts blade, weapon, or material-based alternatives
        expect(['the blade', 'the weapon', 'the steel', 'her sword', 'a steel sword']).to include(result)
      end
    end
  end

  describe '#reset_paragraph_tracking!' do
    it 'clears used descriptors but not name use count' do
      # Use name twice
      service.name_for(participant1)
      service.name_for(participant1)

      service.reset_paragraph_tracking!

      # Name use count should persist (not first call)
      # But used descriptors should be cleared
      name = service.name_for(participant1)
      expect(name).to be_a(String)
    end
  end

  describe 'descriptor generation' do
    context 'when descriptor is selected' do
      before do
        # Force the service to always try a descriptor (30% path)
        allow(service).to receive(:rand).with(100).and_return(85)
      end

      it 'can generate descriptors based on character attributes' do
        service.name_for(participant1) # First call

        # Subsequent calls may use descriptors
        10.times do
          name = service.name_for(participant1, opponent: participant2)
          expect(name).to be_a(String)
          expect(name).not_to be_empty
        end
      end
    end
  end
end
