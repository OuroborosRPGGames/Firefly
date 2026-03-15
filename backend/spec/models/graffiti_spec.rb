# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Graffiti do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:graffiti) { Graffiti.create(room_id: room.id, gdesc: 'Test graffiti', g_x: 10, g_y: 20) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(graffiti).to be_valid
    end

    it 'requires room_id' do
      g = Graffiti.new(gdesc: 'Test', g_x: 10, g_y: 20)
      expect(g).not_to be_valid
    end

    it 'requires gdesc' do
      g = Graffiti.new(room_id: room.id, g_x: 10, g_y: 20)
      expect(g).not_to be_valid
    end

    it 'validates max length of gdesc' do
      g = Graffiti.new(room_id: room.id, gdesc: 'x' * 221, g_x: 10, g_y: 20)
      expect(g).not_to be_valid
    end

    it 'allows gdesc up to MAX_LENGTH' do
      g = Graffiti.create(room_id: room.id, gdesc: 'x' * 220, g_x: 10, g_y: 20)
      expect(g).to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to room' do
      expect(graffiti.room).to eq(room)
    end
  end

  describe 'alias methods' do
    it 'aliases x to g_x' do
      expect(graffiti.x).to eq(10)
    end

    it 'aliases y to g_y' do
      expect(graffiti.y).to eq(20)
    end

    it 'aliases text to gdesc' do
      expect(graffiti.text).to eq('Test graffiti')
    end

    it 'allows setting x through alias' do
      graffiti.x = 50
      expect(graffiti.g_x).to eq(50)
    end

    it 'allows setting y through alias' do
      graffiti.y = 60
      expect(graffiti.g_y).to eq(60)
    end

    it 'allows setting text through alias' do
      graffiti.text = 'New text'
      expect(graffiti.gdesc).to eq('New text')
    end
  end

  describe 'before_create' do
    it 'sets made_at if not set' do
      g = Graffiti.create(room_id: room.id, gdesc: 'Test', g_x: 0, g_y: 0)
      expect(g.made_at).not_to be_nil
    end

    it 'preserves made_at if already set' do
      past_time = Time.now - 3600
      g = Graffiti.create(room_id: room.id, gdesc: 'Test', g_x: 0, g_y: 0, made_at: past_time)
      expect(g.made_at).to be_within(1).of(past_time)
    end
  end

  describe 'MAX_LENGTH constant' do
    it 'is 220' do
      expect(described_class::MAX_LENGTH).to eq(220)
    end
  end
end
