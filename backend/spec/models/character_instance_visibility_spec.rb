# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterInstance, 'visibility methods' do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

  describe '#invisible?' do
    it 'returns false by default' do
      expect(character_instance.invisible?).to be false
    end

    it 'returns true when invisible is true' do
      character_instance.update(invisible: true)
      expect(character_instance.invisible?).to be true
    end
  end

  describe '#go_invisible!' do
    context 'when character cannot go invisible' do
      it 'returns false' do
        expect(character_instance.go_invisible!).to be false
      end

      it 'does not change invisible status' do
        character_instance.go_invisible!
        expect(character_instance.invisible?).to be false
      end
    end

    context 'when character can go invisible' do
      before do
        user.grant_permission!('can_create_staff_characters')
        user.grant_permission!('can_go_invisible')
        character.update(is_staff_character: true)
      end

      it 'returns true' do
        expect(character_instance.go_invisible!).to be true
      end

      it 'sets invisible to true' do
        character_instance.go_invisible!
        expect(character_instance.invisible?).to be true
      end
    end
  end

  describe '#go_visible!' do
    before { character_instance.update(invisible: true) }

    it 'sets invisible to false' do
      character_instance.go_visible!
      expect(character_instance.invisible?).to be false
    end
  end

  describe '#toggle_invisible!' do
    context 'when character can go invisible' do
      before do
        user.grant_permission!('can_create_staff_characters')
        user.grant_permission!('can_go_invisible')
        character.update(is_staff_character: true)
      end

      it 'toggles from visible to invisible' do
        character_instance.toggle_invisible!
        expect(character_instance.invisible?).to be true
      end

      it 'toggles from invisible to visible' do
        character_instance.update(invisible: true)
        character_instance.toggle_invisible!
        expect(character_instance.invisible?).to be false
      end
    end

    context 'when character cannot go invisible' do
      it 'can toggle to visible' do
        character_instance.update(invisible: true)
        character_instance.toggle_invisible!
        expect(character_instance.invisible?).to be false
      end

      it 'cannot toggle to invisible' do
        character_instance.toggle_invisible!
        expect(character_instance.invisible?).to be false
      end
    end
  end

  describe '#staff_vision_enabled?' do
    it 'returns false by default' do
      expect(character_instance.staff_vision_enabled?).to be false
    end

    it 'returns true when staff_vision_enabled is true' do
      character_instance.update(staff_vision_enabled: true)
      expect(character_instance.staff_vision_enabled?).to be true
    end
  end

  describe '#enable_staff_vision!' do
    context 'when character cannot receive staff broadcasts' do
      it 'returns false' do
        expect(character_instance.enable_staff_vision!).to be false
      end
    end

    context 'when character can receive staff broadcasts' do
      before do
        user.grant_permission!('can_create_staff_characters')
        user.grant_permission!('can_see_all_rp')
        character.update(is_staff_character: true)
      end

      it 'enables staff vision' do
        character_instance.enable_staff_vision!
        expect(character_instance.staff_vision_enabled?).to be true
      end
    end
  end

  describe '#disable_staff_vision!' do
    before { character_instance.update(staff_vision_enabled: true) }

    it 'disables staff vision' do
      character_instance.disable_staff_vision!
      expect(character_instance.staff_vision_enabled?).to be false
    end
  end

  describe '#toggle_staff_vision!' do
    context 'when character can receive staff broadcasts' do
      before do
        user.grant_permission!('can_create_staff_characters')
        user.grant_permission!('can_see_all_rp')
        character.update(is_staff_character: true)
      end

      it 'toggles on' do
        character_instance.toggle_staff_vision!
        expect(character_instance.staff_vision_enabled?).to be true
      end

      it 'toggles off' do
        character_instance.update(staff_vision_enabled: true)
        character_instance.toggle_staff_vision!
        expect(character_instance.staff_vision_enabled?).to be false
      end
    end
  end

  describe '#can_receive_staff_broadcasts?' do
    it 'returns false for non-staff characters' do
      expect(character_instance.can_receive_staff_broadcasts?).to be false
    end

    it 'returns false when staff vision is disabled' do
      user.grant_permission!('can_create_staff_characters')
      user.grant_permission!('can_see_all_rp')
      character.update(is_staff_character: true)
      expect(character_instance.can_receive_staff_broadcasts?).to be false
    end

    it 'returns false when character lacks can_see_all_rp permission' do
      user.grant_permission!('can_create_staff_characters')
      character.update(is_staff_character: true)
      character_instance.update(staff_vision_enabled: true)
      expect(character_instance.can_receive_staff_broadcasts?).to be false
    end

    it 'returns true when all conditions are met' do
      user.grant_permission!('can_create_staff_characters')
      user.grant_permission!('can_see_all_rp')
      character.update(is_staff_character: true)
      character_instance.update(staff_vision_enabled: true)
      expect(character_instance.can_receive_staff_broadcasts?).to be true
    end
  end
end
