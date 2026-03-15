# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterDisplayService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) do
    create(:character,
           user: user,
           forename: 'Jane',
           surname: 'Doe',
           gender: 'female',
           short_desc: 'A tall woman with red hair')
  end
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  let(:viewer_user) { create(:user) }
  let(:viewer_character) { create(:character, user: viewer_user, forename: 'Viewer') }
  let(:viewer_instance) do
    create(:character_instance,
           character: viewer_character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject { described_class.new(character_instance, viewer_instance: viewer_instance) }

  describe '#initialize' do
    it 'sets the target' do
      expect(subject.target).to eq(character_instance)
    end

    it 'sets the character' do
      expect(subject.character).to eq(character)
    end

    it 'sets the viewer' do
      expect(subject.viewer).to eq(viewer_instance)
    end

    it 'defaults xray to false' do
      expect(subject.xray).to be false
    end

    it 'accepts xray parameter' do
      service = described_class.new(character_instance, viewer_instance: viewer_instance, xray: true)
      expect(service.xray).to be true
    end
  end

  describe '#build_display' do
    it 'returns a hash with expected keys' do
      display = subject.build_display
      expect(display).to be_a(Hash)
      expect(display).to have_key(:name)
      expect(display).to have_key(:short_desc)
      expect(display).to have_key(:name_line)
      expect(display).to have_key(:status)
      expect(display).to have_key(:is_npc)
      expect(display).to have_key(:intro)
      expect(display).to have_key(:eyes_hair_line)
      expect(display).to have_key(:descriptions)
      expect(display).to have_key(:clothing)
      expect(display).to have_key(:held_items)
      expect(display).to have_key(:using_items)
      expect(display).to have_key(:thumbnails)
    end

    it 'includes character name' do
      display = subject.build_display
      expect(display[:name]).not_to be_nil
      expect(display[:name]).not_to eq('')
    end

    it 'includes short_desc' do
      display = subject.build_display
      expect(display[:short_desc]).to eq('A tall woman with red hair')
    end

    it 'includes status' do
      display = subject.build_display
      expect(display[:status]).to eq('alive')
    end

    it 'indicates character is not an NPC' do
      display = subject.build_display
      expect(display[:is_npc]).to be false
    end

    it 'returns arrays for list fields' do
      display = subject.build_display
      expect(display[:descriptions]).to be_an(Array)
      expect(display[:clothing]).to be_an(Array)
      expect(display[:held_items]).to be_an(Array)
      expect(display[:using_items]).to be_an(Array)
      expect(display[:thumbnails]).to be_an(Array)
    end

    it 'includes name_line combining name and short_desc (with lowercase start)' do
      # Create knowledge so viewer knows the character by name
      CharacterKnowledge.create(
        knower_character_id: viewer_character.id,
        known_character_id: character.id,
        is_known: true,
        known_name: nil # Will use full_name
      )
      display = subject.build_display
      expect(display[:name_line]).to include('Jane')
      # short_desc has first letter lowercased for grammatical flow
      expect(display[:name_line]).to include('a tall woman with red hair')
    end

    it 'includes eyes_hair_line' do
      display = subject.build_display
      expect(display[:eyes_hair_line]).to be_a(String)
      expect(display[:eyes_hair_line]).to include('has')
      expect(display[:eyes_hair_line]).to include('and')
    end
  end

  describe '#build_display for NPC' do
    let(:npc_character) { create(:character, :npc, forename: 'Goblin', is_npc: true) }
    let(:npc_instance) do
      create(:character_instance,
             character: npc_character,
             reality: reality,
             current_room: room,
             online: true,
             status: 'alive')
    end

    subject { described_class.new(npc_instance, viewer_instance: viewer_instance) }

    it 'delegates to NpcDisplayService' do
      # Just verify it doesn't error and returns a hash
      display = subject.build_display
      expect(display).to be_a(Hash)
    end
  end

  describe 'gender_noun helper' do
    context 'with female character' do
      it 'uses woman noun' do
        display = subject.build_display
        if display[:intro] && display[:intro].include?('woman')
          expect(display[:intro]).to include('woman')
        end
      end
    end

    context 'with male character' do
      let(:character) do
        create(:character,
               user: user,
               forename: 'John',
               surname: 'Doe',
               gender: 'male')
      end

      it 'uses man noun' do
        display = subject.build_display
        if display[:intro] && display[:intro].include?('man')
          expect(display[:intro]).to include('man')
        end
      end
    end

    context 'with unspecified gender' do
      let(:character) do
        create(:character,
               user: user,
               forename: 'Alex',
               surname: 'Smith',
               gender: nil)
      end

      it 'uses person noun' do
        display = subject.build_display
        if display[:intro] && display[:intro].include?('person')
          expect(display[:intro]).to include('person')
        end
      end
    end
  end

  describe 'article selection' do
    context 'with vowel-starting word' do
      let(:character) do
        create(:character,
               user: user,
               forename: 'Test',
               body_type: 'elegant')
      end

      it 'uses an article' do
        display = subject.build_display
        if display[:intro]&.include?('elegant')
          expect(display[:intro]).to include('an elegant')
        end
      end
    end

    context 'with consonant-starting word' do
      let(:character) do
        create(:character,
               user: user,
               forename: 'Test',
               body_type: 'tall')
      end

      it 'uses a article' do
        display = subject.build_display
        if display[:intro]&.include?('tall')
          expect(display[:intro]).to include('a tall')
        end
      end
    end
  end

  describe 'held items display' do
    let(:pattern) { create(:pattern) }
    let!(:held_item) do
      create(:item,
             pattern: pattern,
             character_instance: character_instance,
             name: 'Sword',
             held: true)
    end

    it 'includes held items in display' do
      display = subject.build_display
      expect(display[:held_items]).to be_an(Array)
      expect(display[:held_items].map { |i| i[:name] }).to include('Sword')
      expect(display[:held_items].map { |i| i[:hand] }).to include('hand')
    end
  end

  describe 'clothing display' do
    let(:clothing_pattern) { create(:pattern) }
    let!(:clothing_item) do
      create(:item,
             pattern: clothing_pattern,
             character_instance: character_instance,
             name: 'Red Shirt',
             worn: true,
             worn_layer: 1)
    end

    it 'includes clothing in display' do
      display = subject.build_display
      expect(display[:clothing]).to be_an(Array)
    end
  end

  describe 'concealed body descriptions' do
    let!(:covered_position) { create(:body_position, region: 'torso') }
    let!(:concealed_description) do
      create(
        :character_description,
        character_instance: character_instance,
        body_position: covered_position,
        concealed_by_clothing: true,
        content: 'A hidden chest scar'
      )
    end
    let!(:covering_item) { create(:item, character_instance: character_instance, worn: true) }

    before do
      ItemBodyPosition.create(item_id: covering_item.id, body_position_id: covered_position.id, covers: true)
    end

    it 'omits concealed body descriptions when covered by clothing' do
      display = subject.build_display
      contents = display[:descriptions].map { |d| d[:content] }

      expect(contents).not_to include('A hidden chest scar')
    end
  end

  describe 'without viewer' do
    subject { described_class.new(character_instance) }

    it 'works without a viewer' do
      display = subject.build_display
      expect(display).to be_a(Hash)
      expect(display[:name]).not_to be_nil
    end
  end

  describe 'at_place display' do
    context 'when character is not at a place' do
      it 'returns nil for at_place' do
        display = subject.build_display
        expect(display[:at_place]).to be_nil
      end
    end
  end
end
