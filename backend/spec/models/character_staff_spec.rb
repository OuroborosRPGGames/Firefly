# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Character, 'staff character methods' do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe '#staff_character?' do
    it 'returns false by default' do
      expect(character.staff_character?).to be false
    end

    it 'returns true when is_staff_character is true' do
      user.grant_permission!('can_create_staff_characters')
      character.update(is_staff_character: true)
      expect(character.staff_character?).to be true
    end
  end

  describe '#staff?' do
    it 'is an alias for staff_character?' do
      expect(character.staff?).to eq(character.staff_character?)
    end
  end

  describe '#admin?' do
    let(:admin_user) { create(:user, :admin) }
    let(:admin_character) { create(:character, user: admin_user) }

    it 'returns true when user is admin' do
      expect(admin_character.admin?).to be true
    end

    it 'returns false when user is not admin' do
      expect(character.admin?).to be false
    end
  end

  describe '#has_user_permission?' do
    it 'returns true when user has the permission' do
      user.grant_permission!('can_build')
      expect(character.has_user_permission?('can_build')).to be true
    end

    it 'returns false when user lacks the permission' do
      expect(character.has_user_permission?('can_build')).to be false
    end
  end

  describe '#can_go_invisible?' do
    it 'returns false for non-staff characters' do
      expect(character.can_go_invisible?).to be false
    end

    it 'returns false for staff character without permission' do
      user.grant_permission!('can_create_staff_characters')
      character.update(is_staff_character: true)
      expect(character.can_go_invisible?).to be false
    end

    it 'returns true for staff character with permission' do
      user.grant_permission!('can_create_staff_characters')
      user.grant_permission!('can_go_invisible')
      character.update(is_staff_character: true)
      expect(character.can_go_invisible?).to be true
    end
  end

  describe '#can_see_all_rp?' do
    it 'returns false for non-staff characters' do
      expect(character.can_see_all_rp?).to be false
    end

    it 'returns true for staff character with permission' do
      user.grant_permission!('can_create_staff_characters')
      user.grant_permission!('can_see_all_rp')
      character.update(is_staff_character: true)
      expect(character.can_see_all_rp?).to be true
    end
  end

  describe 'staff character validation' do
    context 'when user cannot create staff characters' do
      it 'prevents creating staff characters' do
        character = Character.new(
          forename: 'Staff',
          user: user,
          is_npc: false,
          is_staff_character: true
        )
        expect(character.valid?).to be false
        expect(character.errors[:is_staff_character]).not_to be_empty
      end
    end

    context 'when user can create staff characters' do
      before { user.grant_permission!('can_create_staff_characters') }

      it 'allows creating staff characters' do
        character = Character.new(
          forename: 'Staff',
          user: user,
          is_npc: false,
          is_staff_character: true
        )
        expect(character.valid?).to be true
      end
    end

    context 'when user is admin' do
      let(:admin_user) { create(:user, :admin) }

      it 'allows creating staff characters' do
        character = Character.new(
          forename: 'Staff',
          user: admin_user,
          is_npc: false,
          is_staff_character: true
        )
        expect(character.valid?).to be true
      end
    end
  end
end
