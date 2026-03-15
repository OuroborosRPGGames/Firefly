# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Wardrobe API Routes', type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room, is_vault: true) }
  let(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room, online: true)
  end

  before do
    character_instance
    env 'rack.session', {
      'user_id' => user.id,
      'character_id' => character.id,
      'character_instance_id' => character_instance.id
    }
  end

  describe 'POST /api/wardrobe/items/:id/store' do
    it 'rejects storing worn items' do
      item = create(:item, character_instance: character_instance, stored: false, worn: true, equipped: false)

      post "/api/wardrobe/items/#{item.id}/store"

      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be false
      expect(json_response['error']).to include('remove')
      expect(item.reload.stored).to be false
    end

    it 'rejects storing equipped items' do
      item = create(:item, character_instance: character_instance, stored: false, worn: false, equipped: true)

      post "/api/wardrobe/items/#{item.id}/store"

      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be false
      expect(json_response['error']).to include('unequip')
      expect(item.reload.stored).to be false
    end
  end

  describe 'POST /api/wardrobe/items/:id/fetch-wear' do
    it 'returns piercing position metadata when multiple positions are available' do
      character_instance.add_piercing_position!('left ear')
      character_instance.add_piercing_position!('right ear')
      item = create(
        :item,
        character_instance: character_instance,
        stored: true,
        stored_room_id: room.id,
        is_piercing: true,
        name: 'Silver Stud'
      )

      post "/api/wardrobe/items/#{item.id}/fetch-wear"

      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be false
      expect(json_response['needs_position']).to be true
      expect(json_response['positions']).to match_array(%w[left\ ear right\ ear])
      expect(json_response.dig('data', 'needs_position')).to be true
    end
  end

  describe 'transfer state handling' do
    it 'does not fetch an item while it is still in transit' do
      item = create(
        :item,
        character_instance: character_instance,
        stored: true,
        stored_room_id: create(:room).id,
        transfer_started_at: Time.now,
        transfer_destination_room_id: room.id
      )

      post "/api/wardrobe/items/#{item.id}/fetch"

      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be false
      expect(json_response['error']).to eq('Item not found')
    end

    it 'auto-completes ready transfers when listing active transfers' do
      source_room = create(:room, is_vault: true)
      item = create(
        :item,
        character_instance: character_instance,
        stored: true,
        stored_room_id: source_room.id,
        transfer_started_at: Time.now - (Item::TRANSFER_DURATION_HOURS * 3600) - 60,
        transfer_destination_room_id: room.id
      )

      get '/api/wardrobe/transfers'

      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
      expect(json_response['transfers']).to eq([])

      refreshed = item.refresh
      expect(refreshed.transfer_started_at).to be_nil
      expect(refreshed.stored_room_id).to eq(room.id)
      expect(refreshed.transfer_destination_room_id).to be_nil
    end
  end
end
