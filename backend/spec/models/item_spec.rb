# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Item do
  # Helper to create necessary associations - use factory defaults
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, current_room: room) }
  let(:character) { character_instance.character }

  # Helper to build/create items without nested pattern association issues
  # Supports traits like :in_room as first positional arg
  def build_item(*traits, **attrs)
    build(:item, *traits, pattern: nil, **attrs)
  end

  def create_item(*traits, **attrs)
    create(:item, *traits, pattern: nil, **attrs)
  end

  # ========================================
  # Validations
  # ========================================

  describe 'validations' do
    it 'requires name' do
      item = build_item(name: nil, character_instance: character_instance)
      expect(item.valid?).to be false
      expect(item.errors[:name]).to include('is not present')
    end

    it 'accepts positive quantity values' do
      item = build_item(quantity: 5, character_instance: character_instance)
      expect(item.valid?).to be true
      expect(item.quantity).to eq(5)
    end

    it 'validates condition is in allowed values' do
      item = build_item( condition: 'invalid', character_instance: character_instance)
      expect(item.valid?).to be false
      expect(item.errors[:condition]).not_to be_empty
    end

    it 'accepts all valid conditions' do
      %w[excellent good fair poor broken].each do |condition|
        item = build_item( condition: condition, character_instance: character_instance)
        expect(item.valid?).to eq(true), "Expected condition '#{condition}' to be valid"
      end
    end

    it 'requires item to belong to character_instance OR room' do
      item = build_item( character_instance: nil, room: nil)
      expect(item.valid?).to be false
      expect(item.errors[:base]).to include('Object must belong to either a character or a room')
    end

    it 'cannot belong to both character_instance AND room' do
      item = build_item( character_instance: character_instance, room: room)
      expect(item.valid?).to be false
      expect(item.errors[:base]).to include('Object cannot belong to both a character and a room')
    end

    it 'equipped can only be true for character-owned items' do
      item = build_item( :in_room, equipped: true, room: room)
      expect(item.valid?).to be false
      expect(item.errors[:equipped]).to include('can only be true for objects owned by characters')
    end

    it 'defaults quantity to 1' do
      item = build_item( quantity: nil, character_instance: character_instance)
      item.valid?
      expect(item.quantity).to eq(1)
    end

    it 'defaults condition to good' do
      item = build_item( condition: nil, character_instance: character_instance)
      item.valid?
      expect(item.condition).to eq('good')
    end
  end

  # ========================================
  # Location Methods
  # ========================================

  describe 'location methods' do
    describe '#owned_by_character?' do
      it 'returns true when item has character_instance_id' do
        item = build_item( character_instance: character_instance)
        expect(item.owned_by_character?).to be true
      end

      it 'returns false when item has no character_instance_id' do
        item = build_item( :in_room, room: room)
        expect(item.owned_by_character?).to be false
      end
    end

    describe '#in_room?' do
      it 'returns true when item has room_id' do
        item = build_item( :in_room, room: room)
        expect(item.in_room?).to be true
      end

      it 'returns false when item has no room_id' do
        item = build_item( character_instance: character_instance)
        expect(item.in_room?).to be false
      end
    end

    describe '#move_to_character' do
      it 'moves item from room to character and clears stale state flags' do
        item = create_item(:in_room, room: room)
        Item.where(id: item.id).update(
          worn: true,
          held: true,
          equipped: true,
          equipment_slot: 'right_hand',
          stored: true,
          stored_room_id: room.id,
          transfer_started_at: Time.now,
          transfer_destination_room_id: room.id,
          holstered_in_id: 999
        )
        item.refresh
        item.move_to_character(character_instance)
        item.refresh
        expect(item.character_instance_id).to eq(character_instance.id)
        expect(item.room_id).to be_nil
        expect(item.worn).to be false
        expect(item.held).to be false
        expect(item.equipped).to be false
        expect(item.equipment_slot).to be_nil
        expect(item.stored).to be false
        expect(item.stored_room_id).to be_nil
        expect(item.transfer_started_at).to be_nil
        expect(item.transfer_destination_room_id).to be_nil
        expect(item.holstered_in_id).to be_nil
      end

      it 'clears item game scores for previous owners when ownership changes' do
        previous_owner = create(:character_instance, current_room: room)
        next_owner = create(:character_instance, current_room: room)
        item = create_item(character_instance: previous_owner)

        allow(GameScore).to receive(:clear_for_items)

        item.move_to_character(next_owner)

        expect(GameScore).to have_received(:clear_for_items).with(previous_owner.id)
      end
    end

    describe '#move_to_room' do
      it 'moves item from character to room and clears stale state flags' do
        item = create_item(
          character_instance: character_instance,
          worn: true,
          held: true,
          equipped: true,
          equipment_slot: 'left_hand',
          stored: true,
          stored_room_id: room.id,
          transfer_started_at: Time.now,
          transfer_destination_room_id: room.id,
          holstered_in_id: 999
        )
        item.move_to_room(room)
        item.refresh
        expect(item.room_id).to eq(room.id)
        expect(item.character_instance_id).to be_nil
        expect(item.worn).to be false
        expect(item.held).to be false
        expect(item.equipped).to be false
        expect(item.equipment_slot).to be_nil
        expect(item.stored).to be false
        expect(item.stored_room_id).to be_nil
        expect(item.transfer_started_at).to be_nil
        expect(item.transfer_destination_room_id).to be_nil
        expect(item.holstered_in_id).to be_nil
      end

      it 'clears item game scores for the previous owner' do
        item = create_item(character_instance: character_instance)
        allow(GameScore).to receive(:clear_for_items)

        item.move_to_room(room)

        expect(GameScore).to have_received(:clear_for_items).with(character_instance.id)
      end
    end
  end

  # ========================================
  # Equipment Methods
  # ========================================

  describe 'equipment methods' do
    let(:item) { create_item( character_instance: character_instance) }

    describe '#equip' do
      it 'equips item to character' do
        item.equip('main_hand')
        expect(item.equipped).to be true
        expect(item.equipment_slot).to eq('main_hand')
      end

      it 'returns false if item not owned by character' do
        room_item = create_item( :in_room, room: room)
        expect(room_item.equip).to be false
      end
    end

    describe '#unequip' do
      it 'unequips item' do
        item.equip('main_hand')
        item.unequip
        expect(item.equipped).to be false
        expect(item.equipment_slot).to be_nil
      end
    end

    describe '#equipped?' do
      it 'returns true when equipped' do
        item.update(equipped: true)
        expect(item.equipped?).to be true
      end

      it 'returns false when not equipped' do
        expect(item.equipped?).to be false
      end
    end
  end

  # ========================================
  # Clothing Methods
  # ========================================

  describe 'clothing methods' do
    let(:item) { create_item( character_instance: character_instance) }

    describe '#worn?' do
      it 'returns true when worn' do
        item.update(worn: true)
        expect(item.worn?).to be true
      end

      it 'returns false when not worn' do
        expect(item.worn?).to be false
      end
    end

    describe '#wear!' do
      it 'sets worn to true' do
        item.wear!
        expect(item.worn).to be true
      end

      it 'returns false if not character owned' do
        room_item = create_item( :in_room, room: room)
        expect(room_item.wear!).to be false
      end
    end

    describe '#remove!' do
      it 'sets worn to false' do
        item.update(worn: true)
        item.remove!
        expect(item.worn).to be false
      end
    end

    describe 'type checks' do
      it '#clothing? returns true when is_clothing' do
        item.update(is_clothing: true)
        expect(item.clothing?).to be true
      end

      it '#jewelry? returns true when is_jewelry' do
        item.update(is_jewelry: true)
        expect(item.jewelry?).to be true
      end

      it '#tattoo? returns true when is_tattoo' do
        item.update(is_tattoo: true)
        expect(item.tattoo?).to be true
      end

      it '#piercing? returns true when is_piercing' do
        item.update(is_piercing: true)
        expect(item.piercing?).to be true
      end
    end
  end

  # ========================================
  # Image Methods
  # ========================================

  describe 'image methods' do
    let(:item) { build_item( character_instance: character_instance) }

    describe '#has_image?' do
      it 'returns true when image_url is set' do
        item.image_url = 'https://example.com/image.png'
        expect(item.has_image?).to be true
      end

      it 'returns false when image_url is nil' do
        item.image_url = nil
        expect(item.has_image?).to be false
      end

      it 'returns false when image_url is empty' do
        item.image_url = ''
        expect(item.has_image?).to be false
      end
    end

    describe '#has_thumbnail?' do
      it 'returns true when image_url is set (thumbnail delegates to image_url)' do
        item.image_url = 'https://example.com/thumb.png'
        expect(item.has_thumbnail?).to be true
      end

      it 'returns false when image_url is nil' do
        item.image_url = nil
        expect(item.has_thumbnail?).to be false
      end
    end
  end

  # ========================================
  # State Flags
  # ========================================

  describe 'state flags' do
    let(:item) { create_item( character_instance: character_instance) }

    describe '#torn?' do
      it 'returns true when torn > 0' do
        item.update(torn: 5)
        expect(item.torn?).to be true
      end

      it 'returns false when torn is 0' do
        item.update(torn: 0)
        expect(item.torn?).to be false
      end

      it 'returns false when torn is nil' do
        item.torn = nil
        expect(item.torn?).to be false
      end
    end

    describe '#damage_percentage' do
      it 'calculates percentage correctly' do
        item.update(torn: 5)
        expect(item.damage_percentage).to eq(50)
      end

      it 'clamps to 100' do
        item.update(torn: 15)
        expect(item.damage_percentage).to eq(100)
      end

      it 'returns 0 when not torn' do
        item.update(torn: 0)
        expect(item.damage_percentage).to eq(0)
      end
    end

    describe '#concealed?' do
      it 'returns true when concealed' do
        item.update(concealed: true)
        expect(item.concealed?).to be true
      end
    end

    describe '#zipped?' do
      it 'returns true when zipped' do
        item.update(zipped: true)
        expect(item.zipped?).to be true
      end
    end

    describe '#held?' do
      it 'returns true when held' do
        item.update(held: true)
        expect(item.held?).to be true
      end
    end

    describe '#hold!' do
      it 'sets held to true' do
        item.hold!
        expect(item.held).to be true
      end

      it 'returns false if not character owned' do
        room_item = create_item( :in_room, room: room)
        expect(room_item.hold!).to be false
      end
    end

    describe '#pocket!' do
      it 'sets held to false' do
        item.update(stored: false)
        item.pocket!
        expect(item.held).to be false
      end
    end
  end

  # ========================================
  # Storage Methods
  # ========================================

  describe 'storage methods' do
    let(:item) { create_item( character_instance: character_instance, worn: true, stored: false, equipped: true) }

    describe '#stored?' do
      it 'returns true when stored' do
        item.update(stored: true)
        expect(item.stored?).to be true
      end
    end

    describe '#store!' do
      it 'stores item and resets state flags' do
        item.store!
        expect(item.stored).to be true
        expect(item.worn).to be false
        expect(item.held).to be false
        expect(item.equipped).to be false
        expect(item.equipment_slot).to be_nil
      end

      it 'returns false if not character owned' do
        room_item = create_item( :in_room, room: room)
        expect(room_item.store!).to be false
      end
    end

    describe '#retrieve!' do
      it 'retrieves item from storage' do
        item.update(stored: true)
        item.retrieve!
        expect(item.stored).to be false
      end
    end

    describe '.stored_items_for' do
      it 'returns stored items for character instance' do
        stored = create_item( character_instance: character_instance, stored: true, name: 'Stored Item')
        not_stored = create_item( character_instance: character_instance, stored: false, name: 'Not Stored')

        results = Item.stored_items_for(character_instance)
        expect(results).to include(stored)
        expect(results).not_to include(not_stored)
      end
    end
  end

  # ========================================
  # Visibility Layer
  # ========================================

  describe '#visibility_layer' do
    let(:item) { build_item( character_instance: character_instance) }

    it 'returns worn_layer when set' do
      item.worn_layer = 5
      expect(item.visibility_layer).to eq(5)
    end

    it 'returns 0 when worn_layer is nil' do
      item.worn_layer = nil
      expect(item.visibility_layer).to eq(0)
    end
  end

  # ========================================
  # Pet Methods
  # ========================================

  describe 'pet methods' do
    let(:pet_item) { create_item( character_instance: character_instance, is_pet_instance: true) }

    describe '#pet?' do
      it 'returns true when is_pet_instance is true' do
        expect(pet_item.pet?).to be true
      end

      it 'returns false when is_pet_instance is false' do
        item = create_item( character_instance: character_instance, is_pet_instance: false)
        expect(item.pet?).to be false
      end
    end

    describe '#owner_instance' do
      it 'returns the character_instance' do
        expect(pet_item.owner_instance).to eq(character_instance)
      end
    end

    describe '#owner_character' do
      it 'returns the character through character_instance' do
        expect(pet_item.owner_character).to eq(character)
      end
    end

    describe '#owner_name' do
      it 'returns the character forename' do
        expect(pet_item.owner_name).to eq(character.forename)
      end

      it 'returns someone when no owner' do
        pet_item.character_instance = nil
        # Need to force room to make it valid
        pet_item.room = room
        expect(pet_item.owner_name).to eq('someone')
      end
    end

    describe '#pet_on_cooldown?' do
      it 'returns false when pet_last_animation_at is nil' do
        pet_item.pet_last_animation_at = nil
        expect(pet_item.pet_on_cooldown?).to be false
      end

      it 'returns true when animated recently' do
        pet_item.update(pet_last_animation_at: Time.now - 60)
        expect(pet_item.pet_on_cooldown?(120)).to be true
      end

      it 'returns false when cooldown has passed' do
        pet_item.update(pet_last_animation_at: Time.now - 200)
        expect(pet_item.pet_on_cooldown?(120)).to be false
      end
    end

    describe '#update_pet_animation_time!' do
      it 'updates pet_last_animation_at' do
        pet_item.update_pet_animation_time!
        expect(pet_item.pet_last_animation_at).to be_within(2).of(Time.now)
      end
    end
  end

  # ========================================
  # Class Methods
  # ========================================

  describe 'class methods' do
    describe '.pets_in_room' do
      it 'returns pet items in the specified room' do
        pet_in_room = create_item( :in_room, room: room, is_pet_instance: true)
        regular_in_room = create_item( :in_room, room: room, is_pet_instance: false)

        results = Item.pets_in_room(room.id)
        expect(results).to include(pet_in_room)
        expect(results).not_to include(regular_in_room)
      end
    end
  end

  # ========================================
  # Defaults
  # ========================================

  describe 'defaults' do
    it 'stackable? returns false by default' do
      item = build_item( character_instance: character_instance)
      expect(item.stackable?).to be false
    end

    it 'tradeable? returns true by default' do
      item = build_item( character_instance: character_instance)
      expect(item.tradeable?).to be true
    end
  end

  # ========================================
  # Timeline Visibility Methods
  # ========================================

  describe 'timeline visibility' do
    let(:timeline) { create(:timeline) }
    let(:item_with_timeline) { create_item(character_instance: character_instance, timeline_id: timeline.id) }
    let(:item_without_timeline) { create_item(character_instance: character_instance, timeline_id: nil) }

    describe '#visible_in_timeline?' do
      it 'returns true for item without timeline_id (visible everywhere)' do
        expect(item_without_timeline.visible_in_timeline?(timeline.id)).to be true
      end

      it 'returns true when item timeline matches' do
        expect(item_with_timeline.visible_in_timeline?(timeline.id)).to be true
      end

      it 'returns false when item timeline does not match' do
        other_timeline = create(:timeline)
        expect(item_with_timeline.visible_in_timeline?(other_timeline.id)).to be false
      end

      it 'accepts Timeline object instead of id' do
        expect(item_with_timeline.visible_in_timeline?(timeline)).to be true
      end
    end

    describe '#visible_to?' do
      let(:viewer_in_timeline) do
        ci = create(:character_instance, current_room: room, timeline_id: timeline.id)
        ci
      end
      let(:viewer_in_primary) do
        ci = create(:character_instance, current_room: room, timeline_id: nil)
        ci
      end

      it 'returns true for item without timeline (visible to all)' do
        expect(item_without_timeline.visible_to?(viewer_in_timeline)).to be true
        expect(item_without_timeline.visible_to?(viewer_in_primary)).to be true
      end

      it 'returns true when viewer is in same timeline' do
        expect(item_with_timeline.visible_to?(viewer_in_timeline)).to be true
      end

      it 'returns false when viewer is in primary timeline' do
        expect(item_with_timeline.visible_to?(viewer_in_primary)).to be false
      end

      it 'returns false when viewer is in different timeline' do
        other_timeline = create(:timeline)
        viewer_other = create(:character_instance, current_room: room, timeline_id: other_timeline.id)
        expect(item_with_timeline.visible_to?(viewer_other)).to be false
      end
    end

    describe '.visible_in_timeline' do
      before do
        item_with_timeline
        item_without_timeline
      end

      it 'returns items with nil timeline and items in specified timeline' do
        results = Item.visible_in_timeline(timeline.id)
        expect(results).to include(item_with_timeline)
        expect(results).to include(item_without_timeline)
      end

      it 'accepts Timeline object' do
        results = Item.visible_in_timeline(timeline)
        expect(results).to include(item_with_timeline)
      end
    end

    describe '.visible_to' do
      let(:viewer_in_timeline) { create(:character_instance, current_room: room, timeline_id: timeline.id) }
      let(:viewer_in_primary) { create(:character_instance, current_room: room, timeline_id: nil) }

      before do
        item_with_timeline
        item_without_timeline
      end

      it 'returns appropriate items for viewer in timeline' do
        results = Item.visible_to(viewer_in_timeline)
        expect(results).to include(item_with_timeline)
        expect(results).to include(item_without_timeline)
      end

      it 'returns only primary items for viewer in primary timeline' do
        results = Item.visible_to(viewer_in_primary)
        expect(results).not_to include(item_with_timeline)
        expect(results).to include(item_without_timeline)
      end
    end
  end

  # ========================================
  # Holster/Sheath Methods
  # ========================================

  describe 'holster methods' do
    let(:item) { create_item(character_instance: character_instance) }

    describe '#holstered?' do
      it 'returns false when not in a holster' do
        expect(item.holstered?).to be false
      end

      it 'returns true when holstered_in_id is set' do
        holster = create_item(character_instance: character_instance, name: 'Holster')
        item.update(holstered_in_id: holster.id)
        expect(item.holstered?).to be true
      end
    end

    describe '#holster_item' do
      it 'returns nil when not holstered' do
        expect(item.holster_item).to be_nil
      end

      it 'returns the holster container when holstered' do
        holster = create_item(character_instance: character_instance, name: 'Holster')
        item.update(holstered_in_id: holster.id)
        expect(item.holster_item).to eq(holster)
      end
    end

    describe '#holstered_weapons_count' do
      it 'returns 0 when no weapons holstered' do
        holster = create_item(character_instance: character_instance, name: 'Holster')
        expect(holster.holstered_weapons_count).to eq(0)
      end

      it 'returns count of weapons in holster' do
        holster = create_item(character_instance: character_instance, name: 'Holster')
        weapon1 = create_item(character_instance: character_instance, name: 'Weapon 1', holstered_in_id: holster.id)
        weapon2 = create_item(character_instance: character_instance, name: 'Weapon 2', holstered_in_id: holster.id)
        expect(holster.holstered_weapons_count).to eq(2)
      end
    end

    describe '#unholster!' do
      it 'returns false when not holstered' do
        expect(item.unholster!).to be false
      end

      it 'removes item from holster' do
        holster = create_item(character_instance: character_instance, name: 'Holster')
        item.update(holstered_in_id: holster.id)
        expect(item.unholster!).to be true
        item.refresh
        expect(item.holstered_in_id).to be_nil
      end
    end
  end

  # ========================================
  # Consumable Methods
  # ========================================

  describe 'consumable methods' do
    let(:item) { create_item(character_instance: character_instance) }

    describe '#being_consumed?' do
      it 'returns false when consume_remaining is nil' do
        expect(item.being_consumed?).to be false
      end

      it 'returns true when consume_remaining is set' do
        item.update(consume_remaining: 5)
        expect(item.being_consumed?).to be true
      end
    end

    describe '#start_consuming!' do
      it 'sets consume_remaining to default when pattern has no consume_time' do
        item.start_consuming!
        expect(item.consume_remaining).to eq(10) # Default
      end
    end

    describe '#consume_tick!' do
      it 'returns false when not being consumed' do
        expect(item.consume_tick!).to be false
      end

      it 'decrements consume_remaining' do
        item.update(consume_remaining: 5)
        item.consume_tick!
        item.refresh
        expect(item.consume_remaining).to eq(4)
      end

      it 'returns true when consumption completes' do
        item.update(consume_remaining: 1, quantity: 2)
        expect(item.consume_tick!).to be true
      end

      it 'reduces quantity when finishing consumption of stackable item' do
        item.update(consume_remaining: 1, quantity: 3)
        item.consume_tick!
        refreshed_item = Item[item.id]
        expect(refreshed_item.quantity).to eq(2)
      end
    end

    describe '#finish_consuming!' do
      it 'clears consume_remaining' do
        item.update(consume_remaining: 3, quantity: 2)
        item.finish_consuming!
        refreshed_item = Item[item.id]
        expect(refreshed_item.consume_remaining).to be_nil
        expect(refreshed_item.quantity).to eq(1)
      end

      it 'destroys item when quantity is 1' do
        item.update(consume_remaining: 3, quantity: 1)
        item_id = item.id
        item.finish_consuming!
        expect(Item[item_id]).to be_nil
      end
    end
  end

  # ========================================
  # Transfer Methods
  # ========================================

  describe 'transfer methods' do
    let(:item) { create_item(character_instance: character_instance, stored: true) }
    let(:destination_room) { create(:room) }

    describe '#in_transit?' do
      it 'returns false when transfer_started_at is nil' do
        expect(item.in_transit?).to be false
      end

      it 'returns true when transfer_started_at is set' do
        item.update(transfer_started_at: Time.now)
        expect(item.in_transit?).to be true
      end
    end

    describe '#transfer_ready?' do
      it 'returns false when not in transit' do
        expect(item.transfer_ready?).to be false
      end

      it 'returns false when not enough time has passed' do
        item.update(transfer_started_at: Time.now)
        expect(item.transfer_ready?).to be false
      end

      it 'returns true when transfer duration has passed' do
        item.update(transfer_started_at: Time.now - (13 * 3600)) # 13 hours ago (>12h duration)
        expect(item.transfer_ready?).to be true
      end
    end

    describe '#time_until_transfer_ready' do
      it 'returns 0 when not in transit' do
        expect(item.time_until_transfer_ready).to eq(0)
      end

      it 'returns positive seconds when in transit' do
        item.update(transfer_started_at: Time.now)
        expect(item.time_until_transfer_ready).to be > 0
      end

      it 'returns 0 when transfer is ready' do
        item.update(transfer_started_at: Time.now - (13 * 3600))
        expect(item.time_until_transfer_ready).to eq(0)
      end
    end

    describe '#start_transfer!' do
      it 'sets transfer_started_at and destination' do
        item.start_transfer!(destination_room)
        expect(item.transfer_started_at).to be_within(2).of(Time.now)
        expect(item.transfer_destination_room_id).to eq(destination_room.id)
      end
    end

    describe '#complete_transfer!' do
      it 'moves item to destination and clears transfer state' do
        item.update(stored_room_id: room.id)
        item.start_transfer!(destination_room)
        item.complete_transfer!
        item.refresh
        expect(item.stored_room_id).to eq(destination_room.id)
        expect(item.transfer_started_at).to be_nil
        expect(item.transfer_destination_room_id).to be_nil
      end
    end

    describe '#cancel_transfer!' do
      it 'clears transfer state without moving item' do
        original_room_id = room.id
        item.update(stored_room_id: original_room_id)
        item.start_transfer!(destination_room)
        item.cancel_transfer!
        item.refresh
        expect(item.stored_room_id).to eq(original_room_id)
        expect(item.transfer_started_at).to be_nil
        expect(item.transfer_destination_room_id).to be_nil
      end
    end

    describe '.stored_in_room' do
      let(:other_room) { create(:room) }

      it 'returns items stored in specified room' do
        stored_here = create_item(character_instance: character_instance, stored: true, stored_room_id: room.id)
        stored_elsewhere = create_item(character_instance: character_instance, stored: true, stored_room_id: other_room.id)

        results = Item.stored_in_room(character_instance, room)
        expect(results).to include(stored_here)
        expect(results).not_to include(stored_elsewhere)
      end

      it 'includes legacy items with nil stored_room_id' do
        legacy_item = create_item(character_instance: character_instance, stored: true, stored_room_id: nil)
        results = Item.stored_in_room(character_instance, room)
        expect(results).to include(legacy_item)
      end

      it 'excludes items in transit' do
        in_transit = create_item(character_instance: character_instance, stored: true, stored_room_id: room.id, transfer_started_at: Time.now)
        results = Item.stored_in_room(character_instance, room)
        expect(results).not_to include(in_transit)
      end
    end

    describe '.in_transit_for' do
      it 'returns items in transit for character' do
        in_transit = create_item(character_instance: character_instance, stored: true, transfer_started_at: Time.now)
        not_in_transit = create_item(character_instance: character_instance, stored: true, transfer_started_at: nil)

        results = Item.in_transit_for(character_instance)
        expect(results).to include(in_transit)
        expect(results).not_to include(not_in_transit)
      end
    end

    describe '.ready_for_transfer_completion' do
      it 'returns items ready for transfer' do
        ready = create_item(character_instance: character_instance, stored: true, transfer_started_at: Time.now - (13 * 3600))
        not_ready = create_item(character_instance: character_instance, stored: true, transfer_started_at: Time.now)

        results = Item.ready_for_transfer_completion.all
        expect(results).to include(ready)
        expect(results).not_to include(not_ready)
      end
    end
  end

  # ========================================
  # Pet Animation Additional Methods
  # ========================================

  describe 'pet animation additional methods' do
    let(:pet_item) { create_item(character_instance: character_instance, is_pet_instance: true) }

    describe '#pet_type_name' do
      it 'returns pet when no pattern' do
        expect(pet_item.pet_type_name).to eq('pet')
      end
    end

    describe '#pet_description' do
      it 'returns default when no pattern' do
        expect(pet_item.pet_description).to eq('a magical pet')
      end
    end

    describe '#pet_sounds' do
      it 'returns default when no pattern' do
        expect(pet_item.pet_sounds).to eq('makes soft sounds')
      end
    end

    describe '#add_emote_to_history' do
      it 'builds array and calls update with pg_array' do
        # Test the method logic - it should build array and call update
        expect(pet_item).to receive(:update).with(hash_including(:pet_emote_history))
        pet_item.add_emote_to_history('The pet yawns.')
      end

      it 'keeps only last 5 emotes when array grows' do
        # Simulate existing history
        existing_history = Sequel.pg_array(['e1', 'e2', 'e3', 'e4', 'e5'], :text)
        allow(pet_item).to receive(:pet_emote_history).and_return(existing_history)

        expect(pet_item).to receive(:update) do |args|
          # The new array should have 5 elements (dropped e1)
          arr = args[:pet_emote_history]
          expect(arr.to_a.length).to eq(5)
          expect(arr.to_a).not_to include('e1')
          expect(arr.to_a).to include('e6')
        end
        pet_item.add_emote_to_history('e6')
      end
    end

    describe '#recent_emote_context' do
      it 'returns no recent activity when history is empty' do
        expect(pet_item.recent_emote_context).to eq('(No recent activity in the room)')
      end

      it 'returns no recent activity when history is nil' do
        allow(pet_item).to receive(:pet_emote_history).and_return(nil)
        expect(pet_item.recent_emote_context).to eq('(No recent activity in the room)')
      end

      it 'returns joined history when present' do
        history = Sequel.pg_array(['First emote', 'Second emote'], :text)
        allow(pet_item).to receive(:pet_emote_history).and_return(history)
        expect(pet_item.recent_emote_context).to include('First emote')
        expect(pet_item.recent_emote_context).to include('Second emote')
      end
    end

    describe '.pets_held_in_room' do
      it 'returns pets held by characters in the room' do
        held_pet = create_item(character_instance: character_instance, is_pet_instance: true, held: true)
        # Make sure character_instance is in room
        character_instance.update(current_room_id: room.id)

        results = Item.pets_held_in_room(room.id).all
        expect(results.map(&:id)).to include(held_pet.id)
      end

      it 'excludes pets not held' do
        unheld_pet = create_item(character_instance: character_instance, is_pet_instance: true, held: false)
        character_instance.update(current_room_id: room.id)

        results = Item.pets_held_in_room(room.id).all
        expect(results.map(&:id)).not_to include(unheld_pet.id)
      end
    end
  end

  # ========================================
  # Body Position Methods
  # ========================================

  describe 'body position methods' do
    let(:item) { create_item(character_instance: character_instance) }
    let(:body_position) { create(:body_position) }
    let(:private_position) { create(:body_position, is_private: true) }

    describe '#body_position_ids_covered' do
      it 'returns empty array when no positions' do
        expect(item.body_position_ids_covered).to eq([])
      end

      it 'returns covered position ids' do
        ItemBodyPosition.create(item_id: item.id, body_position_id: body_position.id, covers: true)
        expect(item.body_position_ids_covered).to include(body_position.id)
      end

      it 'excludes non-covering positions' do
        ItemBodyPosition.create(item_id: item.id, body_position_id: body_position.id, covers: false)
        expect(item.body_position_ids_covered).not_to include(body_position.id)
      end
    end

    describe '#covers_position?' do
      it 'returns false when position not covered' do
        expect(item.covers_position?(body_position.id)).to be false
      end

      it 'returns true when position is covered' do
        ItemBodyPosition.create(item_id: item.id, body_position_id: body_position.id, covers: true)
        expect(item.covers_position?(body_position.id)).to be true
      end
    end

    describe '#covers_private_position?' do
      it 'returns false when no private positions covered' do
        expect(item.covers_private_position?).to be false
      end

      it 'returns true when a private position is covered' do
        ItemBodyPosition.create(item_id: item.id, body_position_id: private_position.id, covers: true)
        expect(item.covers_private_position?).to be true
      end

      it 'returns false when private position is not covering' do
        ItemBodyPosition.create(item_id: item.id, body_position_id: private_position.id, covers: false)
        expect(item.covers_private_position?).to be false
      end
    end
  end

  # ========================================
  # Image URL with Pattern Fallback
  # ========================================

  describe '#image_url with pattern fallback' do
    it 'returns pattern image_url when pattern has image' do
      pattern = create(:pattern)
      pattern.update(image_url: 'https://pattern.example.com/image.png')
      item = create_item(character_instance: character_instance, pattern: pattern)
      expect(item.image_url).to eq('https://pattern.example.com/image.png')
    end

    it 'returns own image_url when pattern has no image' do
      pattern = create(:pattern, image_url: nil)
      item = Item.create(
        name: 'Test Item',
        character_instance: character_instance,
        pattern: pattern,
        quantity: 1,
        condition: 'good'
      )
      # Directly update the database column bypassing model override
      DB[:objects].where(id: item.id).update(image_url: 'https://item.example.com/own.png')
      reloaded = Item[item.id]
      expect(reloaded.image_url).to eq('https://item.example.com/own.png')
    end
  end

  # ========================================
  # Clothing Class Detection
  # ========================================

  describe '#clothing_class' do
    describe 'jewelry detection' do
      it 'returns jewelry for items with is_jewelry flag' do
        item = create_item(character_instance: character_instance, name: 'Gold Ring', is_jewelry: true)
        expect(item.clothing_class).to eq('jewelry')
      end

      it 'returns jewelry for jewelry pattern items' do
        jewelry_type = create(:unified_object_type, category: 'Necklace')
        pattern = create(:pattern, unified_object_type: jewelry_type)
        item = create_item(character_instance: character_instance, name: 'Silver Necklace', pattern: pattern)
        expect(item.clothing_class).to eq('jewelry')
      end
    end

    describe 'name-based detection' do
      it 'detects top items by name keywords' do
        %w[shirt blouse t-shirt tshirt tank polo tunic camisole halter tee].each do |keyword|
          item = create_item(character_instance: character_instance, name: "Blue #{keyword.capitalize}")
          expect(item.clothing_class).to eq('top'), "Expected '#{keyword}' to be classified as top"
        end
      end

      it 'detects bottoms items by name keywords' do
        %w[pants trousers jeans shorts skirt leggings slacks].each do |keyword|
          item = create_item(character_instance: character_instance, name: "Black #{keyword.capitalize}")
          expect(item.clothing_class).to eq('bottoms'), "Expected '#{keyword}' to be classified as bottoms"
        end
      end

      it 'detects overwear items by name keywords' do
        %w[jacket coat sweater hoodie cardigan blazer vest poncho cloak robe].each do |keyword|
          item = create_item(character_instance: character_instance, name: "Warm #{keyword.capitalize}")
          expect(item.clothing_class).to eq('overwear'), "Expected '#{keyword}' to be classified as overwear"
        end
      end

      it 'detects underwear items by name keywords' do
        %w[underwear lingerie bra panties boxers briefs].each do |keyword|
          item = create_item(character_instance: character_instance, name: "Cotton #{keyword.capitalize}")
          expect(item.clothing_class).to eq('underwear'), "Expected '#{keyword}' to be classified as underwear"
        end
      end

      it 'detects jewelry items by name keywords' do
        %w[ring necklace bracelet earring anklet brooch pendant chain].each do |keyword|
          item = create_item(character_instance: character_instance, name: "Diamond #{keyword.capitalize}")
          expect(item.clothing_class).to eq('jewelry'), "Expected '#{keyword}' to be classified as jewelry"
        end
      end

      it 'detects accessories by name keywords' do
        %w[hat cap scarf gloves belt watch bag purse sunglasses glasses tie bandana beanie mask socks stockings].each do |keyword|
          item = create_item(character_instance: character_instance, name: "Fancy #{keyword.capitalize}")
          expect(item.clothing_class).to eq('accessories'), "Expected '#{keyword}' to be classified as accessories"
        end
      end

      it 'returns other for unrecognized items' do
        item = create_item(character_instance: character_instance, name: 'Mysterious Artifact')
        expect(item.clothing_class).to eq('other')
      end
    end

    describe 'priority' do
      it 'prioritizes jewelry flag over name' do
        item = create_item(character_instance: character_instance, name: 'Shirt-shaped Ring', is_jewelry: true)
        expect(item.clothing_class).to eq('jewelry')
      end
    end
  end
end
