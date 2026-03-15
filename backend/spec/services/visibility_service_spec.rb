# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe VisibilityService do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  let(:viewer_character) { create(:character) }
  let(:viewer_instance) { create(:character_instance, character: viewer_character, current_room: room) }

  let!(:chest_position) { BodyPosition.create(label: 'chest', region: 'torso', is_private: false) }

  describe '.position_exposed?' do
    context 'with no clothing' do
      it 'returns true for any body position' do
        expect(described_class.position_exposed?(character_instance, chest_position.id)).to be true
      end
    end

    context 'with xray mode' do
      it 'returns true regardless of clothing' do
        expect(described_class.position_exposed?(character_instance, chest_position.id, xray: true)).to be true
      end
    end
  end

  describe '.description_visible?' do
    let(:description) do
      create(
        :character_description,
        character_instance: character_instance,
        body_position: chest_position,
        concealed_by_clothing: true,
        content: 'A scar across the chest'
      )
    end

    it 'returns false for concealed body descriptions when the position is covered' do
      item = create(:item, character_instance: character_instance, worn: true)
      ItemBodyPosition.create(item_id: item.id, body_position_id: chest_position.id, covers: true)

      expect(
        described_class.description_visible?(description, character_instance, viewer: viewer_instance)
      ).to be false
    end

    it 'returns true for concealed body descriptions when the position is exposed' do
      expect(
        described_class.description_visible?(description, character_instance, viewer: viewer_instance)
      ).to be true
    end
  end

  describe '.show_private_content?' do
    context 'when both characters are in private mode' do
      before do
        character_instance.update(private_mode: true)
        viewer_instance.update(private_mode: true)
      end

      it 'returns true' do
        expect(described_class.show_private_content?(viewer_instance, character_instance)).to be true
      end
    end

    context 'when only one character is in private mode' do
      before do
        character_instance.update(private_mode: true)
        viewer_instance.update(private_mode: false)
      end

      it 'returns false' do
        expect(described_class.show_private_content?(viewer_instance, character_instance)).to be false
      end
    end

    context 'when neither character is in private mode' do
      before do
        character_instance.update(private_mode: false)
        viewer_instance.update(private_mode: false)
      end

      it 'returns false' do
        expect(described_class.show_private_content?(viewer_instance, character_instance)).to be false
      end
    end
  end

  describe '.visible_clothing' do
    context 'with no worn items' do
      it 'returns an empty array' do
        expect(described_class.visible_clothing(character_instance)).to eq([])
      end
    end
  end
end
