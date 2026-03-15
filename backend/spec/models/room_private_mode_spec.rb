# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Room, 'private mode methods' do
  let(:room) { create(:room) }

  describe '#private_mode?' do
    it 'returns false by default' do
      expect(room.private_mode?).to be false
    end

    it 'returns true when private_mode is true' do
      room.update(private_mode: true)
      expect(room.private_mode?).to be true
    end
  end

  describe '#enable_private_mode!' do
    it 'enables private mode' do
      room.enable_private_mode!
      expect(room.private_mode?).to be true
    end

    it 'persists the change' do
      room.enable_private_mode!
      room.reload
      expect(room.private_mode?).to be true
    end
  end

  describe '#disable_private_mode!' do
    before { room.update(private_mode: true) }

    it 'disables private mode' do
      room.disable_private_mode!
      expect(room.private_mode?).to be false
    end

    it 'persists the change' do
      room.disable_private_mode!
      room.reload
      expect(room.private_mode?).to be false
    end
  end

  describe '#toggle_private_mode!' do
    it 'toggles from false to true' do
      room.toggle_private_mode!
      expect(room.private_mode?).to be true
    end

    it 'toggles from true to false' do
      room.update(private_mode: true)
      room.toggle_private_mode!
      expect(room.private_mode?).to be false
    end
  end

  describe '#excludes_staff_vision?' do
    it 'returns false by default' do
      expect(room.excludes_staff_vision?).to be false
    end

    it 'returns true when private mode is enabled' do
      room.update(private_mode: true)
      expect(room.excludes_staff_vision?).to be true
    end

    it 'is an alias for private_mode?' do
      expect(room.excludes_staff_vision?).to eq(room.private_mode?)
      room.update(private_mode: true)
      expect(room.excludes_staff_vision?).to eq(room.private_mode?)
    end
  end
end
