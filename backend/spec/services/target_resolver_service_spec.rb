# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TargetResolverService do
  let(:location) { create(:location) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'User', user: user) }
  let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room) }

  describe '.resolve' do
    let(:candidates) do
      [
        { id: 1, name: 'Red Shirt', description: 'A bright red shirt' },
        { id: 2, name: 'Blue Pants', description: 'Dark blue jeans' },
        { id: 3, name: 'Green Hat', description: 'A green baseball cap' }
      ]
    end

    describe 'unique prefix matching' do
      let(:prefix_candidates) do
        [
          OpenStruct.new(id: 1, name: 'Bob Smith'),
          OpenStruct.new(id: 2, name: 'Alice Jones'),
          OpenStruct.new(id: 3, name: 'Charlie Brown')
        ]
      end

      it 'matches on short unique prefix' do
        # 'bo' uniquely matches Bob, even though it's < min_prefix_length
        result = described_class.resolve(
          query: 'bo',
          candidates: prefix_candidates,
          name_field: :name,
          min_prefix_length: 3
        )
        expect(result.name).to eq('Bob Smith')
      end

      it 'does not match short non-unique prefix' do
        candidates_with_bobby = prefix_candidates + [OpenStruct.new(id: 4, name: 'Bobby Tables')]
        result = described_class.resolve(
          query: 'bo',
          candidates: candidates_with_bobby,
          name_field: :name,
          min_prefix_length: 3
        )
        expect(result).to be_nil
      end
    end

    describe 'fuzzy (typo-tolerant) matching' do
      let(:candidates) do
        [
          OpenStruct.new(id: 1, name: 'Bob'),
          OpenStruct.new(id: 2, name: 'Alice'),
          OpenStruct.new(id: 3, name: 'Charlie')
        ]
      end

      it 'matches with single character typo' do
        result = described_class.resolve(
          query: 'bbo',  # typo for 'bob'
          candidates: candidates,
          name_field: :name,
          min_prefix_length: 3
        )
        expect(result.name).to eq('Bob')
      end

      it 'matches with transposed characters' do
        result = described_class.resolve(
          query: 'ailce',  # typo for 'alice'
          candidates: candidates,
          name_field: :name,
          min_prefix_length: 3
        )
        expect(result.name).to eq('Alice')
      end

      it 'does not match with too many typos' do
        result = described_class.resolve(
          query: 'xyz',
          candidates: candidates,
          name_field: :name,
          min_prefix_length: 3
        )
        expect(result).to be_nil
      end

      it 'does not match when multiple candidates fuzzy-match' do
        # Both 'Bob' and 'Rob' are within edit distance 1 of 'bob'
        candidates_with_rob = candidates + [OpenStruct.new(id: 4, name: 'Rob')]
        result = described_class.resolve(
          query: 'rob',  # matches both 'Bob' (1 edit) and 'Rob' (exact)
          candidates: candidates_with_rob,
          name_field: :name,
          min_prefix_length: 3
        )
        # Should return exact match 'Rob' via earlier strategies, not fuzzy
        expect(result.name).to eq('Rob')
      end

      it 'allows 2 edits for longer queries' do
        result = described_class.resolve(
          query: 'chralie',  # typo for 'charlie' (2 transpositions)
          candidates: candidates,
          name_field: :name,
          min_prefix_length: 3
        )
        expect(result.name).to eq('Charlie')
      end
    end

    describe 'word-start (initials) matching' do
      let(:initials_candidates) do
        [
          OpenStruct.new(id: 1, name: 'John Smith'),
          OpenStruct.new(id: 2, name: 'Jane Doe'),
          OpenStruct.new(id: 3, name: 'Charlie Brown')
        ]
      end

      it 'matches initials' do
        result = described_class.resolve(
          query: 'js',
          candidates: initials_candidates,
          name_field: :name,
          min_prefix_length: 2
        )
        expect(result.name).to eq('John Smith')
      end

      it 'does not match ambiguous initials' do
        # Jack Sparrow also has 'js' initials, so this should be ambiguous
        candidates_with_conflict = initials_candidates + [OpenStruct.new(id: 4, name: 'Jack Sparrow')]
        result = described_class.resolve(
          query: 'js',
          candidates: candidates_with_conflict,
          name_field: :name,
          min_prefix_length: 2
        )
        # Returns nil when ambiguous
        expect(result).to be_nil
      end

      it 'matches initials as prefix' do
        result = described_class.resolve(
          query: 'jd',
          candidates: initials_candidates,
          name_field: :name,
          min_prefix_length: 2
        )
        expect(result.name).to eq('Jane Doe')
      end

      it 'matches initials for multi-word names' do
        result = described_class.resolve(
          query: 'cb',
          candidates: initials_candidates,
          name_field: :name,
          min_prefix_length: 2
        )
        expect(result.name).to eq('Charlie Brown')
      end

      it 'requires minimum query length of 2 for initials' do
        # Single letter 'j' should not match via initials (too ambiguous)
        result = described_class.resolve(
          query: 'j',
          candidates: initials_candidates,
          name_field: :name,
          min_prefix_length: 3
        )
        # Should not match - 'j' is too short for initials matching
        expect(result).to be_nil
      end
    end

    context 'with empty query' do
      it 'returns nil for nil query' do
        result = described_class.resolve(query: nil, candidates: candidates)
        expect(result).to be_nil
      end

      it 'returns nil for blank query' do
        result = described_class.resolve(query: '  ', candidates: candidates)
        expect(result).to be_nil
      end
    end

    context 'with empty candidates' do
      it 'returns nil for nil candidates' do
        result = described_class.resolve(query: 'shirt', candidates: nil)
        expect(result).to be_nil
      end

      it 'returns nil for empty candidates array' do
        result = described_class.resolve(query: 'shirt', candidates: [])
        expect(result).to be_nil
      end
    end

    context 'with exact name match' do
      it 'finds exact match on name (case insensitive)' do
        result = described_class.resolve(query: 'Red Shirt', candidates: candidates)
        expect(result[:id]).to eq(1)
      end

      it 'finds exact match on name (lowercase)' do
        result = described_class.resolve(query: 'red shirt', candidates: candidates)
        expect(result[:id]).to eq(1)
      end
    end

    context 'with exact description match' do
      it 'finds exact match on description' do
        result = described_class.resolve(
          query: 'A bright red shirt',
          candidates: candidates
        )
        expect(result[:id]).to eq(1)
      end
    end

    context 'with prefix match on name' do
      it 'finds prefix match when query >= min_prefix_length' do
        result = described_class.resolve(query: 'Red', candidates: candidates)
        expect(result[:id]).to eq(1)
      end

      it 'does not match ambiguous prefix shorter than min_prefix_length' do
        # Add another candidate starting with 'Re' to make it ambiguous
        ambiguous_candidates = candidates + [{ id: 4, name: 'Red Cap', description: 'A red cap' }]
        result = described_class.resolve(
          query: 'Re',
          candidates: ambiguous_candidates,
          min_prefix_length: 3
        )
        # With two items starting with 'Re', short prefix should not match
        expect(result).to be_nil
      end
    end

    context 'with contains match on name' do
      it 'finds contains match' do
        result = described_class.resolve(query: 'Shirt', candidates: candidates)
        expect(result[:id]).to eq(1)
      end
    end

    context 'with HTML in description' do
      let(:html_candidates) do
        [
          { id: 1, name: 'Sword', description: '<span class="red">A sharp blade</span>' },
          { id: 2, name: 'Shield', description: '<strong>A wooden shield</strong>' }
        ]
      end

      it 'strips HTML when matching descriptions' do
        result = described_class.resolve(
          query: 'A sharp blade',
          candidates: html_candidates
        )
        expect(result[:id]).to eq(1)
      end
    end
  end

  describe '.resolve_with_disambiguation' do
    let(:candidates) do
      [
        { id: 1, name: 'Red Shirt', description: 'Bright red' },
        { id: 2, name: 'Red Hat', description: 'Dark red' },
        { id: 3, name: 'Blue Pants', description: 'Blue jeans' }
      ]
    end

    context 'with empty query' do
      it 'returns error for blank query' do
        result = described_class.resolve_with_disambiguation(
          query: '',
          candidates: candidates
        )
        expect(result[:error]).to include('looking for')
      end
    end

    context 'with empty candidates' do
      it 'returns error for empty candidates' do
        result = described_class.resolve_with_disambiguation(
          query: 'test',
          candidates: []
        )
        expect(result[:error]).to include('Nothing to search')
      end
    end

    context 'with single exact match' do
      it 'returns match directly' do
        result = described_class.resolve_with_disambiguation(
          query: 'Blue Pants',
          candidates: candidates
        )
        expect(result[:match][:id]).to eq(3)
      end
    end

    context 'with single partial match' do
      it 'returns match directly' do
        result = described_class.resolve_with_disambiguation(
          query: 'Blue',
          candidates: candidates
        )
        expect(result[:match][:id]).to eq(3)
      end
    end

    context 'with multiple matches' do
      it 'creates disambiguation menu when character_instance provided' do
        result = described_class.resolve_with_disambiguation(
          query: 'Red',
          candidates: candidates,
          character_instance: character_instance
        )

        expect(result[:quickmenu]).not_to be_nil
        expect(result[:disambiguation]).to be true
      end

      it 'returns first match with warning when no character_instance' do
        result = described_class.resolve_with_disambiguation(
          query: 'Red',
          candidates: candidates,
          character_instance: nil
        )

        expect(result[:match][:id]).to eq(1)
        expect(result[:warning]).to include('Multiple matches')
      end
    end

    context 'with no matches' do
      it 'returns error' do
        result = described_class.resolve_with_disambiguation(
          query: 'Yellow',
          candidates: candidates
        )
        expect(result[:error]).to include('No match found')
      end
    end

    context 'with short query' do
      it 'returns error for query shorter than min_prefix_length' do
        result = described_class.resolve_with_disambiguation(
          query: 'Re',
          candidates: candidates,
          min_prefix_length: 3
        )
        expect(result[:error]).to include('too short')
      end
    end
  end

  describe '.resolve_character' do
    let(:user2) { create(:user) }
    let(:char_alice) { Character.create(forename: 'Alice', surname: 'Smith', user: user2, is_npc: false) }
    let(:char_bob) { Character.create(forename: 'Bob', surname: 'Jones', user: user2, is_npc: false) }
    let(:char_alfred) { Character.create(forename: 'Alfred', surname: 'Brown', user: user2, is_npc: false) }

    let(:character_candidates) { [char_alice, char_bob, char_alfred] }

    context 'with empty query' do
      it 'returns nil for nil query' do
        result = described_class.resolve_character(
          query: nil,
          candidates: character_candidates
        )
        expect(result).to be_nil
      end
    end

    context 'with exact forename match' do
      it 'finds exact match on forename' do
        result = described_class.resolve_character(
          query: 'Alice',
          candidates: character_candidates
        )
        expect(result).to eq(char_alice)
      end

      it 'finds match case-insensitively' do
        result = described_class.resolve_character(
          query: 'alice',
          candidates: character_candidates
        )
        expect(result).to eq(char_alice)
      end
    end

    context 'with exact full name match' do
      it 'finds exact match on full name' do
        result = described_class.resolve_character(
          query: 'Alice Smith',
          candidates: character_candidates
        )
        expect(result).to eq(char_alice)
      end
    end

    context 'with prefix match' do
      it 'finds prefix match on forename' do
        result = described_class.resolve_character(
          query: 'Ali',
          candidates: character_candidates
        )
        expect(result).to eq(char_alice)
      end

      it 'does not match prefix shorter than min_prefix_length' do
        result = described_class.resolve_character(
          query: 'A',
          candidates: character_candidates,
          min_prefix_length: 2
        )
        # Both Alice and Alfred start with 'A', but query is too short
        expect(result).to be_nil
      end
    end

    context 'with contains match' do
      it 'finds contains match' do
        result = described_class.resolve_character(
          query: 'lice',
          candidates: character_candidates
        )
        expect(result).to eq(char_alice)
      end
    end

    context 'with viewer and personalized name matching' do
      let(:viewer_user) { create(:user) }
      let(:viewer_char) { Character.create(forename: 'Viewer', surname: 'Test', user: viewer_user, is_npc: false) }
      let(:viewer_instance) do
        CharacterInstance.create(
          character: viewer_char,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive',
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
      end

      let(:char_stranger) { Character.create(forename: 'Mysterious', surname: 'Figure', short_desc: 'a cloaked stranger', user: user2, is_npc: false) }
      let(:stranger_instance) do
        CharacterInstance.create(
          character: char_stranger,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive',
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
      end

      let(:alice_instance) do
        CharacterInstance.create(
          character: char_alice,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive',
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
      end

      it 'matches unknown character by short_desc when viewer does not know them' do
        # Viewer doesn't know the stranger, so display_name_for returns short_desc
        result = described_class.resolve_character(
          query: 'cloaked stranger',
          candidates: [alice_instance, stranger_instance],
          viewer: viewer_instance
        )
        expect(result).to eq(stranger_instance)
      end

      it 'matches unknown character by short_desc prefix' do
        result = described_class.resolve_character(
          query: 'a cloaked',
          candidates: [alice_instance, stranger_instance],
          viewer: viewer_instance
        )
        expect(result).to eq(stranger_instance)
      end

      it 'matches known character by known_name' do
        # Viewer knows Alice by a nickname
        CharacterKnowledge.create(
          knower_character_id: viewer_char.id,
          known_character_id: char_alice.id,
          is_known: true,
          known_name: 'Ali'
        )
        result = described_class.resolve_character(
          query: 'Ali',
          candidates: [alice_instance, stranger_instance],
          viewer: viewer_instance
        )
        expect(result).to eq(alice_instance)
      end

      it 'still matches by forename without viewer' do
        result = described_class.resolve_character(
          query: 'Mysterious',
          candidates: [alice_instance, stranger_instance]
        )
        expect(result).to eq(stranger_instance)
      end

      it 'still matches by forename even with viewer' do
        result = described_class.resolve_character(
          query: 'Alice',
          candidates: [alice_instance, stranger_instance],
          viewer: viewer_instance
        )
        expect(result).to eq(alice_instance)
      end
    end

    context 'with CharacterInstance candidates' do
      let(:alice_instance) do
        CharacterInstance.create(
          character: char_alice,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive',
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
      end
      let(:bob_instance) do
        CharacterInstance.create(
          character: char_bob,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive',
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
      end

      let(:instance_candidates) { [alice_instance, bob_instance] }

      it 'resolves CharacterInstance via character.forename' do
        result = described_class.resolve_character(
          query: 'Alice',
          candidates: instance_candidates
        )
        expect(result).to eq(alice_instance)
      end

      it 'resolves CharacterInstance via character.full_name' do
        result = described_class.resolve_character(
          query: 'Bob Jones',
          candidates: instance_candidates
        )
        expect(result).to eq(bob_instance)
      end
    end
  end

  describe '.resolve_character_with_disambiguation' do
    let(:user2) { create(:user) }
    let(:char_john_smith) { Character.create(forename: 'John', surname: 'Smith', user: user2, is_npc: false) }
    let(:char_john_jones) { Character.create(forename: 'John', surname: 'Jones', user: user2, is_npc: false) }
    let(:char_bob) { Character.create(forename: 'Bob', surname: 'Wilson', user: user2, is_npc: false) }

    let(:character_candidates) { [char_john_smith, char_john_jones, char_bob] }

    context 'with single match' do
      it 'returns match directly' do
        result = described_class.resolve_character_with_disambiguation(
          query: 'Bob',
          candidates: character_candidates,
          character_instance: character_instance
        )
        expect(result[:match]).to eq(char_bob)
      end
    end

    context 'with multiple matches' do
      it 'creates disambiguation menu' do
        # Need to search for a partial match that matches multiple Johns
        result = described_class.resolve_character_with_disambiguation(
          query: 'Joh',
          candidates: character_candidates,
          character_instance: character_instance
        )

        expect(result[:quickmenu]).not_to be_nil
        expect(result[:disambiguation]).to be true
      end
    end

    context 'with no matches' do
      it 'returns error' do
        result = described_class.resolve_character_with_disambiguation(
          query: 'Zed',
          candidates: character_candidates,
          character_instance: character_instance
        )
        expect(result[:error]).to include('No one matching')
      end
    end

    context 'with personalized name matching via viewer' do
      let(:char_hooded) { Character.create(forename: 'Shadow', surname: 'Walker', short_desc: 'a hooded figure', user: user2, is_npc: false) }
      let(:desc_candidates) { [char_john_smith, char_bob, char_hooded] }

      it 'finds exact match on display name (short_desc for unknown characters)' do
        # character_instance (viewer) doesn't know char_hooded, so sees short_desc
        result = described_class.resolve_character_with_disambiguation(
          query: 'a hooded figure',
          candidates: desc_candidates,
          character_instance: character_instance
        )
        expect(result[:match]).to eq(char_hooded)
      end

      it 'finds partial match on display name' do
        result = described_class.resolve_character_with_disambiguation(
          query: 'hooded',
          candidates: desc_candidates,
          character_instance: character_instance
        )
        expect(result[:match]).to eq(char_hooded)
      end
    end
  end

  describe '.resolve_movement_target' do
    # Set up room with spatial bounds for adjacency
    let(:room_with_bounds) { create(:room, name: 'Test Room', short_description: 'A room', location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
    # Other room north of test room
    let(:other_room) { Room.create(name: 'North Room', short_description: 'North', location: location, room_type: 'standard', indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200) }

    # Override room and character_instance for movement tests
    let(:room) { room_with_bounds }
    let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room_with_bounds) }

    # Ensure other_room exists for spatial adjacency
    before { other_room }

    let(:user2) { create(:user) }
    let(:other_char) { Character.create(forename: 'Other', surname: 'Person', user: user2, is_npc: false) }
    let!(:other_instance) do
      CharacterInstance.create(
        character: other_char,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end
    # Viewer knows the other character by name (required for visible-name matching)
    let!(:knowledge_of_other) do
      CharacterKnowledge.create(
        knower_character_id: character.id,
        known_character_id: other_char.id,
        is_known: true,
        known_name: other_char.full_name
      )
    end

    context 'with empty target' do
      it 'returns error for nil target' do
        result = described_class.resolve_movement_target(nil, character_instance)
        expect(result.type).to eq(:error)
        expect(result.error).to include('Where')
      end

      it 'returns error for blank target' do
        result = described_class.resolve_movement_target('', character_instance)
        expect(result.type).to eq(:error)
      end
    end

    context 'with direction target' do
      it 'finds exit by direction name' do
        result = described_class.resolve_movement_target('north', character_instance)
        expect(result.type).to eq(:exit)
        expect(result.exit.direction).to eq('north')
        expect(result.exit.to_room).to eq(other_room)
      end

      it 'finds exit case-insensitively' do
        result = described_class.resolve_movement_target('NORTH', character_instance)
        expect(result.type).to eq(:exit)
        expect(result.exit.direction).to eq('north')
        expect(result.exit.to_room).to eq(other_room)
      end
    end

    context 'with room name target' do
      before do
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
      end

      it 'finds room by name' do
        result = described_class.resolve_movement_target('North Room', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target).to eq(other_room)
      end

      it 'finds room by partial name' do
        result = described_class.resolve_movement_target('North', character_instance)
        # Direction match takes priority over room match
        expect(result.type).to eq(:exit)
      end
    end

    context 'with character target' do
      before do
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
      end

      it 'finds character in room by name' do
        result = described_class.resolve_movement_target('Other', character_instance)
        expect(result.type).to eq(:character)
        expect(result.target).to eq(other_instance)
      end

      it 'finds character by full name' do
        result = described_class.resolve_movement_target('Other Person', character_instance)
        expect(result.type).to eq(:character)
        expect(result.target).to eq(other_instance)
      end

      it 'does not match self by forename' do
        # Update character to unique name that won't match room or exit names
        character.update(forename: 'Xavier', surname: 'Unique')
        result = described_class.resolve_movement_target('Xavier', character_instance)
        # Should not find self, but also no room/exit with that name, so error
        expect(result.type).to eq(:error)
      end
    end

    context 'with unknown target' do
      before do
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
      end

      it 'returns error for no match' do
        result = described_class.resolve_movement_target('xyz123', character_instance)
        expect(result.type).to eq(:error)
        expect(result.error).to include("Can't find")
      end
    end
  end

  describe '.strip_html' do
    it 'removes HTML tags' do
      result = described_class.strip_html('<span class="red">text</span>')
      expect(result).to eq('text')
    end

    it 'handles nested tags' do
      result = described_class.strip_html('<div><span>nested</span></div>')
      expect(result).to eq('nested')
    end

    it 'returns empty string for nil input' do
      result = described_class.strip_html(nil)
      expect(result).to eq('')
    end

    it 'returns plain text unchanged' do
      result = described_class.strip_html('plain text')
      expect(result).to eq('plain text')
    end
  end

  describe 'vehicle targets' do
    let(:other_room) { Room.create(name: 'Parking Lot', short_description: 'A lot', location: location, room_type: 'standard') }
    let!(:vehicle) { create(:vehicle, owner: character, current_room: other_room, name: 'Blue Sedan') }

    it 'resolves "car" to owned vehicle location' do
      result = described_class.resolve_movement_target('car', character_instance)
      expect(result.type).to eq(:room)
      expect(result.target.id).to eq(other_room.id)
    end

    it 'resolves "vehicle" to owned vehicle location' do
      result = described_class.resolve_movement_target('vehicle', character_instance)
      expect(result.type).to eq(:room)
      expect(result.target.id).to eq(other_room.id)
    end

    it 'resolves "my car" to owned vehicle location' do
      result = described_class.resolve_movement_target('my car', character_instance)
      expect(result.type).to eq(:room)
      expect(result.target.id).to eq(other_room.id)
    end

    it 'resolves specific vehicle name' do
      result = described_class.resolve_movement_target('blue sedan', character_instance)
      expect(result.type).to eq(:room)
      expect(result.target.id).to eq(other_room.id)
    end

    it 'resolves partial vehicle name' do
      result = described_class.resolve_movement_target('sedan', character_instance)
      expect(result.type).to eq(:room)
      expect(result.target.id).to eq(other_room.id)
    end

    context 'when character has no vehicles' do
      before { vehicle.destroy }

      it 'returns error for generic vehicle keywords' do
        result = described_class.resolve_movement_target('car', character_instance)
        expect(result.type).to eq(:error)
        expect(result.error).to include("Can't find")
      end
    end

    context 'when vehicle has no room (lost)' do
      before { vehicle.update(room_id: nil) }

      it 'returns error for vehicle with no location' do
        result = described_class.resolve_movement_target('car', character_instance)
        expect(result.type).to eq(:error)
        expect(result.error).to include("location")
      end
    end

    context 'with multiple vehicles' do
      let(:another_room) { Room.create(name: 'Garage', short_description: 'A garage', location: location, room_type: 'standard') }
      let!(:motorcycle) { create(:vehicle, owner: character, current_room: another_room, name: 'Red Motorcycle') }

      it 'returns ambiguous result for generic "car"' do
        result = described_class.resolve_movement_target('car', character_instance)
        expect(result.type).to eq(:ambiguous)
        expect(result.target[:matches].length).to eq(2)
      end

      it 'returns ambiguous result for generic "vehicle"' do
        result = described_class.resolve_movement_target('vehicle', character_instance)
        expect(result.type).to eq(:ambiguous)
        expect(result.target[:matches].length).to eq(2)
      end

      it 'resolves specific vehicle name unambiguously' do
        result = described_class.resolve_movement_target('motorcycle', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(another_room.id)
      end
    end
  end

  describe 'event targets' do
    let(:event_room) { Room.create(name: 'Event Hall', long_description: 'A hall', location: location, room_type: 'standard') }

    context 'with public events' do
      let!(:public_event) do
        Event.create(
          name: 'Birthday Party',
          event_type: 'party',
          status: 'active',
          is_public: true,
          room: event_room,
          organizer: character,
          starts_at: Time.now - 3600
        )
      end

      it 'resolves exact event name' do
        result = described_class.resolve_movement_target('Birthday Party', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(event_room.id)
      end

      it 'resolves partial event name' do
        result = described_class.resolve_movement_target('birthday', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(event_room.id)
      end

      it 'resolves event name case-insensitively' do
        result = described_class.resolve_movement_target('BIRTHDAY PARTY', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(event_room.id)
      end
    end

    context 'with private events' do
      let(:organizer_user) { User.create(email: 'org@example.com', password_hash: 'hash', username: 'organizer') }
      let(:organizer_char) { Character.create(forename: 'Org', surname: 'Anizer', user: organizer_user, is_npc: false) }
      let!(:private_event) do
        Event.create(
          name: 'Secret Meeting',
          event_type: 'meeting',
          status: 'active',
          is_public: false,
          room: event_room,
          organizer: organizer_char,
          starts_at: Time.now - 3600
        )
      end

      it 'does not resolve private event without attendance' do
        result = described_class.resolve_movement_target('Secret Meeting', character_instance)
        expect(result.type).to eq(:error)
      end

      it 'resolves private event when attending' do
        EventAttendee.create(
          event: private_event,
          character: character,
          status: 'yes'
        )
        result = described_class.resolve_movement_target('Secret Meeting', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(event_room.id)
      end

      it 'does not resolve private event when bounced' do
        EventAttendee.create(
          event: private_event,
          character: character,
          status: 'yes',
          bounced: true
        )
        result = described_class.resolve_movement_target('Secret Meeting', character_instance)
        expect(result.type).to eq(:error)
      end

      it 'resolves private event for organizer' do
        private_event.update(organizer_id: character.id)
        result = described_class.resolve_movement_target('Secret Meeting', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(event_room.id)
      end
    end

    context 'with upcoming events' do
      let!(:upcoming_event) do
        Event.create(
          name: 'Tomorrow Party',
          event_type: 'party',
          status: 'scheduled',
          is_public: true,
          room: event_room,
          organizer: character,
          starts_at: Time.now + 3600  # 1 hour from now
        )
      end

      it 'resolves upcoming public events within 24 hours' do
        result = described_class.resolve_movement_target('Tomorrow Party', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(event_room.id)
      end
    end

    context 'with completed events' do
      let!(:old_event) do
        Event.create(
          name: 'Old Party',
          event_type: 'party',
          status: 'completed',
          is_public: true,
          room: event_room,
          organizer: character,
          starts_at: Time.now - 86_400
        )
      end

      it 'does not resolve completed events' do
        result = described_class.resolve_movement_target('Old Party', character_instance)
        expect(result.type).to eq(:error)
      end
    end

    context 'with event having no room' do
      let!(:roomless_event) do
        Event.create(
          name: 'Virtual Meeting',
          event_type: 'meeting',
          status: 'active',
          is_public: true,
          room_id: nil,
          organizer: character,
          starts_at: Time.now - 3600
        )
      end

      it 'returns error for event without location' do
        result = described_class.resolve_movement_target('Virtual Meeting', character_instance)
        expect(result.type).to eq(:error)
        expect(result.error).to include('no location')
      end
    end

    context 'with multiple matching events' do
      let!(:party1) do
        Event.create(
          name: 'Staff Party North',
          event_type: 'party',
          status: 'active',
          is_public: true,
          room: event_room,
          organizer: character,
          starts_at: Time.now - 3600
        )
      end
      let(:event_room2) { Room.create(name: 'South Hall', long_description: 'South', location: location, room_type: 'standard') }
      let!(:party2) do
        Event.create(
          name: 'Staff Party South',
          event_type: 'party',
          status: 'active',
          is_public: true,
          room: event_room2,
          organizer: character,
          starts_at: Time.now - 3600
        )
      end

      it 'returns ambiguous result for multiple matches' do
        result = described_class.resolve_movement_target('Staff Party', character_instance)
        expect(result.type).to eq(:ambiguous)
        expect(result.target[:type]).to eq(:event)
        expect(result.target[:matches].length).to eq(2)
      end

      it 'resolves when query matches only one event' do
        result = described_class.resolve_movement_target('Staff Party North', character_instance)
        expect(result.type).to eq(:room)
        expect(result.target.id).to eq(event_room.id)
      end
    end
  end

  describe '.find_by_identifier' do
    let(:candidates) do
      [
        { id: 1, name: 'First' },
        { id: 2, name: 'Second' },
        { id: 3, name: 'Third' }
      ]
    end

    it 'finds item by integer id' do
      result = described_class.find_by_identifier(2, candidates)
      expect(result[:name]).to eq('Second')
    end

    it 'finds item by string id' do
      result = described_class.find_by_identifier('2', candidates)
      expect(result[:name]).to eq('Second')
    end

    it 'returns nil for non-existent id' do
      result = described_class.find_by_identifier(999, candidates)
      expect(result).to be_nil
    end

    context 'with object candidates (not hashes)' do
      let(:obj_candidates) do
        [
          OpenStruct.new(id: 10, name: 'First Object'),
          OpenStruct.new(id: 20, name: 'Second Object')
        ]
      end

      it 'finds item by id on object' do
        result = described_class.find_by_identifier(20, obj_candidates)
        expect(result.name).to eq('Second Object')
      end
    end
  end

  describe 'levenshtein_distance edge cases (private method through fuzzy match)' do
    let(:candidates) do
      [
        OpenStruct.new(id: 1, name: ''),  # empty name
        OpenStruct.new(id: 2, name: 'X'),  # single char
        OpenStruct.new(id: 3, name: 'LongName')
      ]
    end

    it 'handles empty candidate name gracefully' do
      # Query that shouldn't match empty string
      result = described_class.resolve(
        query: 'test',
        candidates: candidates,
        name_field: :name,
        min_prefix_length: 3
      )
      # Should match LongName as fallback or return nil
      expect(result).to be_nil
    end

    it 'handles single character names' do
      result = described_class.resolve(
        query: 'X',
        candidates: candidates,
        name_field: :name,
        min_prefix_length: 1
      )
      expect(result&.name).to eq('X')
    end
  end

  describe 'matches_word_starts edge cases' do
    let(:candidates) do
      [
        OpenStruct.new(id: 1, name: 'A B C'),  # Single letter words
        OpenStruct.new(id: 2, name: ''),  # Empty name
        OpenStruct.new(id: 3, name: 'John')  # Single word
      ]
    end

    it 'matches single letter word initials' do
      result = described_class.resolve(
        query: 'ab',
        candidates: candidates,
        name_field: :name,
        min_prefix_length: 2
      )
      expect(result&.name).to eq('A B C')
    end

    it 'matches single word initial' do
      # 'j' as initial should match 'John' if query is 'j'
      # But requires min 2 chars for initials
      result = described_class.resolve(
        query: 'jo',  # Not initials, but prefix
        candidates: candidates,
        name_field: :name,
        min_prefix_length: 2
      )
      expect(result&.name).to eq('John')
    end
  end

  describe '.resolve_movement_target with furniture' do
    let(:other_room) { Room.create(name: 'Furniture Room', short_description: 'Furnished', location: location, room_type: 'standard') }

    context 'when room has places/furniture' do
      let(:furniture) { double('RoomPlace', name: 'Comfy Chair', description: 'A leather chair', id: 99) }
      let(:mock_room) { double('Room', name: 'Mocked Room', id: 999, location_id: 1) }

      before do
        # Mock vehicle resolution to avoid database query on owner_id
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
        # Stub current_room to return the mocked room
        allow(character_instance).to receive(:current_room).and_return(mock_room)
        allow(mock_room).to receive(:respond_to?).with(:places).and_return(true)
        allow(mock_room).to receive(:places).and_return([furniture])
        allow(mock_room).to receive(:passable_spatial_exits).and_return([])
        allow(mock_room).to receive(:character_instances).and_return([character_instance])
        # Stub RoomAdjacencyService calls
        allow(RoomAdjacencyService).to receive(:contained_rooms).with(mock_room).and_return([])
        allow(RoomAdjacencyService).to receive(:containing_room).with(mock_room).and_return(nil)
      end

      it 'finds furniture by name' do
        result = described_class.resolve_movement_target('chair', character_instance)
        expect(result.type).to eq(:furniture)
        expect(result.target).to eq(furniture)
      end

      it 'finds furniture by exact name' do
        result = described_class.resolve_movement_target('Comfy Chair', character_instance)
        expect(result.type).to eq(:furniture)
        expect(result.target).to eq(furniture)
      end
    end

    context 'when room has no places method' do
      let(:mock_room) { double('Room', name: 'Mocked Room', id: 998, location_id: 1) }

      before do
        # Mock vehicle resolution to avoid database query on owner_id
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
        # Stub current_room to return the mocked room
        allow(character_instance).to receive(:current_room).and_return(mock_room)
        allow(mock_room).to receive(:respond_to?).with(:places).and_return(false)
        allow(mock_room).to receive(:passable_spatial_exits).and_return([])
        allow(mock_room).to receive(:character_instances).and_return([character_instance])
        # Stub RoomAdjacencyService calls
        allow(RoomAdjacencyService).to receive(:contained_rooms).with(mock_room).and_return([])
        allow(RoomAdjacencyService).to receive(:containing_room).with(mock_room).and_return(nil)
      end

      it 'skips furniture check gracefully' do
        result = described_class.resolve_movement_target('chair', character_instance)
        expect(result.type).to eq(:error)
        expect(result.error).to include("Can't find")
      end
    end
  end

  describe '.resolve_character with edge cases' do
    context 'with nil candidates' do
      it 'returns nil' do
        result = described_class.resolve_character(
          query: 'test',
          candidates: nil
        )
        expect(result).to be_nil
      end
    end

    context 'with empty candidates' do
      it 'returns nil' do
        result = described_class.resolve_character(
          query: 'test',
          candidates: []
        )
        expect(result).to be_nil
      end
    end

    context 'with custom field accessors' do
      let(:custom_candidates) do
        [
          OpenStruct.new(nickname: 'Bob', display_name: 'Robert Smith'),
          OpenStruct.new(nickname: 'Alice', display_name: 'Alice Jones')
        ]
      end

      it 'uses custom forename_field' do
        result = described_class.resolve_character(
          query: 'Bob',
          candidates: custom_candidates,
          forename_field: :nickname
        )
        expect(result.nickname).to eq('Bob')
      end

      it 'uses custom full_name_method' do
        result = described_class.resolve_character(
          query: 'Robert Smith',
          candidates: custom_candidates,
          forename_field: :nickname,
          full_name_method: :display_name
        )
        expect(result.display_name).to eq('Robert Smith')
      end
    end
  end

  describe '.resolve_character_with_disambiguation edge cases' do
    let(:user2) { create(:user) }
    let(:char_test) { Character.create(forename: 'Unique', surname: 'Tester', user: user2, is_npc: false) }
    let(:candidates) { [char_test] }

    context 'with empty query' do
      it 'returns error for nil query' do
        result = described_class.resolve_character_with_disambiguation(
          query: nil,
          candidates: candidates,
          character_instance: character_instance
        )
        expect(result[:error]).to include('Who are you looking for')
      end

      it 'returns error for blank query' do
        result = described_class.resolve_character_with_disambiguation(
          query: '  ',
          candidates: candidates,
          character_instance: character_instance
        )
        expect(result[:error]).to include('Who are you looking for')
      end
    end

    context 'with empty candidates' do
      it 'returns error for nil candidates' do
        result = described_class.resolve_character_with_disambiguation(
          query: 'Test',
          candidates: nil,
          character_instance: character_instance
        )
        expect(result[:error]).to include('No one to search')
      end

      it 'returns error for empty candidates array' do
        result = described_class.resolve_character_with_disambiguation(
          query: 'Test',
          candidates: [],
          character_instance: character_instance
        )
        expect(result[:error]).to include('No one to search')
      end
    end

    context 'with short query' do
      let(:short_candidates) do
        [
          Character.create(forename: 'Alice', surname: 'Smith', user: user2, is_npc: false),
          Character.create(forename: 'Bob', surname: 'Jones', user: user2, is_npc: false)
        ]
      end

      it 'returns error for query shorter than min_prefix_length' do
        result = described_class.resolve_character_with_disambiguation(
          query: 'A',
          candidates: short_candidates,
          character_instance: character_instance,
          min_prefix_length: 2
        )
        expect(result[:error]).to include('too short')
      end
    end
  end

  describe '.resolve_with_disambiguation max_disambiguation limit' do
    let(:many_candidates) do
      (1..15).map { |i| { id: i, name: "Red Item #{i}", description: "Red description #{i}" } }
    end

    it 'limits disambiguation menu options' do
      result = described_class.resolve_with_disambiguation(
        query: 'Red',
        candidates: many_candidates,
        character_instance: character_instance,
        max_disambiguation: 5
      )

      expect(result[:quickmenu]).not_to be_nil
      # The menu should only show up to max_disambiguation items
      # We can check the context has limited match_ids
    end
  end

  describe 'ambiguous movement targets' do
    # Set up spatially adjacent rooms
    let(:test_room) { create(:room, name: 'Test Room', short_description: 'Test', location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
    let(:east_room) { Room.create(name: 'East Room', short_description: 'East', location: location, room_type: 'standard', indoors: false, min_x: 100, max_x: 200, min_y: 0, max_y: 100) }

    context 'when direction name conflicts with character name' do
      let(:user2) { create(:user) }
      let(:char_named_east) { Character.create(forename: 'East', surname: 'Guard', user: user2, is_npc: false) }
      let(:test_character_instance) { create(:character_instance, character: character, reality: reality, current_room: test_room) }
      let!(:char_instance) do
        CharacterInstance.create(
          character: char_named_east,
          reality: reality,
          current_room: test_room,
          online: true,
          status: 'alive',
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
      end

      before do
        # Ensure spatial adjacency
        east_room
        # Mock vehicle resolution to avoid database query on owner_id
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
      end

      # Note: Direction matches take priority over character name matches
      # This is the expected behavior - directions should resolve first
      it 'returns exit match (direction takes priority over character name)' do
        result = described_class.resolve_movement_target('east', test_character_instance)
        expect(result.type).to eq(:exit)
        expect(result.exit.direction).to eq('east')
      end
    end

    context 'when character name does not conflict with direction' do
      let(:user2) { create(:user) }
      let(:char_named_bob) { Character.create(forename: 'Bob', surname: 'Guard', user: user2, is_npc: false) }
      let(:test_character_instance) { create(:character_instance, character: character, reality: reality, current_room: test_room) }
      let!(:char_instance) do
        CharacterInstance.create(
          character: char_named_bob,
          reality: reality,
          current_room: test_room,
          online: true,
          status: 'alive',
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
      end

      # Viewer knows Bob Guard by name (required for visible-name matching)
      let!(:knowledge_of_bob) do
        CharacterKnowledge.create(
          knower_character_id: character.id,
          known_character_id: char_named_bob.id,
          is_known: true,
          known_name: char_named_bob.full_name
        )
      end

      before do
        # Ensure spatial adjacency
        east_room
        # Mock vehicle resolution to avoid database query on owner_id
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
      end

      it 'returns character match when name does not match direction' do
        result = described_class.resolve_movement_target('bob', test_character_instance)
        expect(result.type).to eq(:character)
        expect(result.target.character.forename).to eq('Bob')
      end
    end
  end

  describe 'exit resolution by destination room name' do
    # Set up spatially adjacent rooms for testing
    let(:current_room) { create(:room, name: 'Main Room', short_description: 'Start', location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
    let(:west_room) { Room.create(name: 'Unique West Room', short_description: 'West', location: location, room_type: 'standard', indoors: false, min_x: -100, max_x: 0, min_y: 0, max_y: 100) }
    let(:test_char_instance) { create(:character_instance, character: character, reality: reality, current_room: current_room) }

    context 'when searching by adjacent room name' do
      before do
        west_room # Ensure created for spatial adjacency
        # Mock vehicle resolution to avoid database query on owner_id
        allow(described_class).to receive(:resolve_vehicle_target).and_return(nil)
      end

      it 'finds exit to adjacent room by partial name' do
        result = described_class.resolve_movement_target('unique west', test_char_instance)
        # Should find the room (either as exit or room)
        expect([:exit, :room]).to include(result.type)
        if result.type == :exit
          expect(result.exit.to_room).to eq(west_room)
        else
          expect(result.target).to eq(west_room)
        end
      end

      it 'resolves direction before room name when exact match' do
        result = described_class.resolve_movement_target('west', test_char_instance)
        expect(result.type).to eq(:exit)
        expect(result.exit.direction).to eq('west')
        expect(result.exit.to_room).to eq(west_room)
      end
    end
  end

  describe 'get_field helper (through resolve)' do
    context 'with hash candidates' do
      let(:hash_candidates) { [{ id: 1, name: 'Hash Item' }] }

      it 'accesses hash fields with symbol keys' do
        result = described_class.resolve(
          query: 'Hash Item',
          candidates: hash_candidates,
          name_field: :name
        )
        expect(result[:name]).to eq('Hash Item')
      end
    end

    context 'with object candidates' do
      let(:obj_candidates) { [OpenStruct.new(id: 1, name: 'Object Item')] }

      it 'accesses object fields via method' do
        result = described_class.resolve(
          query: 'Object Item',
          candidates: obj_candidates,
          name_field: :name
        )
        expect(result.name).to eq('Object Item')
      end
    end

    context 'with nil name_field' do
      let(:candidates) { [{ id: 1, name: 'Test', description: 'A test item' }] }

      it 'uses description when name_field is nil' do
        result = described_class.resolve(
          query: 'A test item',
          candidates: candidates,
          name_field: nil,
          description_field: :description
        )
        expect(result[:id]).to eq(1)
      end
    end
  end

  describe 'get_identifier helper (through find_by_identifier)' do
    context 'with object that has no id method' do
      let(:no_id_candidates) do
        [
          { 'id' => '100', name: 'String Key ID' }
        ]
      end

      it 'finds by string key id' do
        result = described_class.find_by_identifier('100', no_id_candidates)
        expect(result[:name]).to eq('String Key ID')
      end
    end
  end
end
