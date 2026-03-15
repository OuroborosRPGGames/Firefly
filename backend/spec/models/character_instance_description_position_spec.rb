# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterInstanceDescriptionPosition do
  describe 'associations' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:instance) { create(:character_instance, character: character, current_room: room) }
    let(:body_position) { create(:body_position) }
    let(:description) { CharacterDescription.create(character_instance_id: instance.id, body_position_id: body_position.id, content: 'Test', active: true) }

    it 'belongs to a character_description' do
      position = CharacterInstanceDescriptionPosition.create(
        character_description_id: description.id,
        body_position_id: body_position.id
      )

      expect(position.character_description).to eq(description)
    end

    it 'belongs to a body_position' do
      position = CharacterInstanceDescriptionPosition.create(
        character_description_id: description.id,
        body_position_id: body_position.id
      )

      expect(position.body_position).to eq(body_position)
    end
  end

  describe 'validations' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:instance) { create(:character_instance, character: character, current_room: room) }
    let(:body_position) { create(:body_position) }
    let(:other_body_position) { create(:body_position) }
    let(:description) { CharacterDescription.create(character_instance_id: instance.id, body_position_id: body_position.id, content: 'Test', active: true) }

    describe 'presence validations' do
      it 'requires character_description_id' do
        position = CharacterInstanceDescriptionPosition.new(
          character_description_id: nil,
          body_position_id: body_position.id
        )

        expect(position.valid?).to be false
        expect(position.errors[:character_description_id]).to include('is not present')
      end

      it 'requires body_position_id' do
        position = CharacterInstanceDescriptionPosition.new(
          character_description_id: description.id,
          body_position_id: nil
        )

        expect(position.valid?).to be false
        expect(position.errors[:body_position_id]).to include('is not present')
      end

      it 'is valid with both IDs present' do
        position = CharacterInstanceDescriptionPosition.new(
          character_description_id: description.id,
          body_position_id: other_body_position.id
        )

        expect(position.valid?).to be true
      end
    end

    describe 'uniqueness validations' do
      before do
        CharacterInstanceDescriptionPosition.create(
          character_description_id: description.id,
          body_position_id: other_body_position.id
        )
      end

      it 'prevents duplicate description-position pairs' do
        duplicate = CharacterInstanceDescriptionPosition.new(
          character_description_id: description.id,
          body_position_id: other_body_position.id
        )

        expect(duplicate.valid?).to be false
        expect(duplicate.errors[[:character_description_id, :body_position_id]]).to include('is already taken')
      end

      it 'allows same position on different descriptions' do
        other_description = CharacterDescription.create(
          character_instance_id: instance.id,
          body_position_id: body_position.id,
          content: 'Other desc',
          active: true,
          aesthetic_type: 'tattoo'
        )
        position = CharacterInstanceDescriptionPosition.new(
          character_description_id: other_description.id,
          body_position_id: other_body_position.id
        )

        expect(position.valid?).to be true
      end

      it 'allows same description with different positions' do
        third_position = create(:body_position)
        position = CharacterInstanceDescriptionPosition.new(
          character_description_id: description.id,
          body_position_id: third_position.id
        )

        expect(position.valid?).to be true
      end
    end
  end

  describe 'timestamps' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:instance) { create(:character_instance, character: character, current_room: room) }
    let(:body_position) { create(:body_position) }
    let(:other_body_position) { create(:body_position) }
    let(:description) { CharacterDescription.create(character_instance_id: instance.id, body_position_id: body_position.id, content: 'Test', active: true) }

    it 'sets created_at on create' do
      position = CharacterInstanceDescriptionPosition.create(
        character_description_id: description.id,
        body_position_id: other_body_position.id
      )

      expect(position.created_at).not_to be_nil
      expect(position.created_at).to be_within(5).of(Time.now)
    end

    it 'can be saved multiple times' do
      position = CharacterInstanceDescriptionPosition.create(
        character_description_id: description.id,
        body_position_id: other_body_position.id
      )

      expect { position.save }.not_to raise_error
    end
  end
end
