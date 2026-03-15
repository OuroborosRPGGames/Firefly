# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ConcealmentService do
  describe '.ranged_penalty' do
    it 'returns 0 penalty for distance < 6' do
      expect(ConcealmentService.ranged_penalty(5)).to eq(0)
    end

    it 'returns -1 penalty for distance 6-11' do
      expect(ConcealmentService.ranged_penalty(6)).to eq(-1)
      expect(ConcealmentService.ranged_penalty(11)).to eq(-1)
    end

    it 'returns -2 penalty for distance 12-17' do
      expect(ConcealmentService.ranged_penalty(12)).to eq(-2)
      expect(ConcealmentService.ranged_penalty(17)).to eq(-2)
    end

    it 'returns -3 penalty for distance 18-23' do
      expect(ConcealmentService.ranged_penalty(18)).to eq(-3)
      expect(ConcealmentService.ranged_penalty(23)).to eq(-3)
    end

    it 'returns -4 penalty (max) for distance >= 24' do
      expect(ConcealmentService.ranged_penalty(24)).to eq(-4)
      expect(ConcealmentService.ranged_penalty(50)).to eq(-4)
    end
  end

  describe '.applies_to_attack?' do
    let(:room) { create(:room) }

    it 'returns false if target not in concealed hex' do
      target_hex = RoomHex.create(room: room, hex_x: 0, hex_y: 0, hex_type: 'normal', danger_level: 0)
      expect(ConcealmentService.applies_to_attack?(target_hex, 'ranged')).to be false
    end

    it 'returns false if attack is melee' do
      target_hex = RoomHex.create(room: room, hex_x: 0, hex_y: 0, hex_type: 'concealed', danger_level: 0)
      expect(ConcealmentService.applies_to_attack?(target_hex, 'melee')).to be false
    end

    it 'returns true if target in concealed hex and attack is ranged' do
      target_hex = RoomHex.create(room: room, hex_x: 0, hex_y: 0, hex_type: 'concealed', danger_level: 0)
      expect(ConcealmentService.applies_to_attack?(target_hex, 'ranged')).to be true
    end
  end
end
