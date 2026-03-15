# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterDescription do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room) }
  let(:body_position) { create(:body_position) }

  describe 'associations' do
    it 'belongs to character_instance' do
      description = CharacterDescription.new(character_instance_id: character_instance.id)
      expect(description.character_instance).to eq(character_instance)
    end

    it 'belongs to body_position (optional)' do
      description = CharacterDescription.new(body_position_id: body_position.id)
      expect(description.body_position).to eq(body_position)
    end
  end

  describe 'validations' do
    it 'requires character_instance_id' do
      description = CharacterDescription.new(content: 'Test', body_position_id: body_position.id)
      expect(description.valid?).to be false
      expect(description.errors[:character_instance_id]).not_to be_empty
    end

    it 'requires content' do
      description = CharacterDescription.new(character_instance_id: character_instance.id, body_position_id: body_position.id)
      expect(description.valid?).to be false
      expect(description.errors[:content]).not_to be_empty
    end

    it 'requires either description_type_id or body_position(s)' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test content'
      )
      expect(description.valid?).to be false
      expect(description.errors[:base]).to include('Must have either description_type_id or body_position(s)')
    end

    it 'validates aesthetic_type for body descriptions' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test content',
        body_position_id: body_position.id,
        aesthetic_type: 'invalid_type'
      )
      expect(description.valid?).to be false
      expect(description.errors[:aesthetic_type]).not_to be_empty
    end

    it 'accepts valid aesthetic types' do
      CharacterDescription::AESTHETIC_TYPES.each do |type|
        description = CharacterDescription.new(
          character_instance_id: character_instance.id,
          content: 'Test content',
          body_position_id: body_position.id,
          aesthetic_type: type
        )
        expect(description.valid?).to be true
      end
    end

    it 'is valid with body_position_id' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test content',
        body_position_id: body_position.id
      )
      expect(description.valid?).to be true
    end
  end

  describe 'schema contract' do
    it 'includes suffix and prefix columns' do
      expect(CharacterDescription.columns).to include(:suffix, :prefix)
    end
  end

  describe '#before_validation' do
    it 'sets default aesthetic_type to natural for body descriptions' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
      description.valid?
      expect(description.aesthetic_type).to eq('natural')
    end

    it 'sets default suffix to period' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
      description.valid?
      expect(description.suffix).to eq('period')
    end

    it 'sets default prefix to none' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
      description.valid?
      expect(description.prefix).to eq('none')
    end
  end

  describe 'suffix validation' do
    it 'accepts valid suffix types' do
      CharacterDescription::SUFFIX_TYPES.each do |type|
        description = CharacterDescription.new(
          character_instance_id: character_instance.id,
          content: 'Test content',
          body_position_id: body_position.id,
          suffix: type
        )
        expect(description.valid?).to be true
      end
    end

    it 'rejects invalid suffix types' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test content',
        body_position_id: body_position.id,
        suffix: 'invalid'
      )
      expect(description.valid?).to be false
      expect(description.errors[:suffix]).not_to be_empty
    end
  end

  describe 'prefix validation' do
    it 'accepts valid prefix types' do
      CharacterDescription::PREFIX_TYPES.each do |type|
        description = CharacterDescription.new(
          character_instance_id: character_instance.id,
          content: 'Test content',
          body_position_id: body_position.id,
          prefix: type
        )
        expect(description.valid?).to be true
      end
    end

    it 'rejects invalid prefix types' do
      description = CharacterDescription.new(
        character_instance_id: character_instance.id,
        content: 'Test content',
        body_position_id: body_position.id,
        prefix: 'invalid'
      )
      expect(description.valid?).to be false
      expect(description.errors[:prefix]).not_to be_empty
    end
  end

  describe '#suffix_text' do
    let(:description) do
      CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
    end

    it 'returns ". " for period suffix' do
      description.suffix = 'period'
      expect(description.suffix_text).to eq('. ')
    end

    it 'returns ", " for comma suffix' do
      description.suffix = 'comma'
      expect(description.suffix_text).to eq(', ')
    end

    it 'returns newline for newline suffix' do
      description.suffix = 'newline'
      expect(description.suffix_text).to eq(".\n")
    end

    it 'returns double newline for double_newline suffix' do
      description.suffix = 'double_newline'
      expect(description.suffix_text).to eq(".\n\n")
    end

    it 'returns period as default for unknown suffix' do
      # The model validates suffix types, but suffix_text has a fallback
      description.instance_variable_set(:@values, description.values.merge(suffix: 'invalid'))
      expect(description.suffix_text).to eq('. ')
    end
  end

  describe '#prefix_text' do
    let(:character) { create(:character, gender: 'male') }
    let(:character_instance) { create(:character_instance, character: character) }
    let(:description) do
      CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
    end

    it 'returns "He has " for pronoun_has with male character' do
      description.prefix = 'pronoun_has'
      expect(description.prefix_text(character)).to eq('He has ')
    end

    it 'returns "He is " for pronoun_is with male character' do
      description.prefix = 'pronoun_is'
      expect(description.prefix_text(character)).to eq('He is ')
    end

    it 'returns "and " for and prefix' do
      description.prefix = 'and'
      expect(description.prefix_text(character)).to eq('and ')
    end

    it 'returns empty string for none prefix' do
      description.prefix = 'none'
      expect(description.prefix_text(character)).to eq('')
    end

    context 'with female character' do
      let(:character) { create(:character, gender: 'female') }

      it 'returns "She has " for pronoun_has' do
        description.prefix = 'pronoun_has'
        expect(description.prefix_text(character)).to eq('She has ')
      end

      it 'returns "She is " for pronoun_is' do
        description.prefix = 'pronoun_is'
        expect(description.prefix_text(character)).to eq('She is ')
      end
    end

    context 'with neutral character' do
      let(:character) { create(:character, gender: 'neutral') }

      it 'returns "They have " for pronoun_has' do
        description.prefix = 'pronoun_has'
        expect(description.prefix_text(character)).to eq('They have ')
      end

      it 'returns "They are " for pronoun_is' do
        description.prefix = 'pronoun_is'
        expect(description.prefix_text(character)).to eq('They are ')
      end
    end
  end

  describe '#all_positions' do
    it 'returns body_position when set' do
      description = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
      expect(description.all_positions).to include(body_position)
    end

    it 'returns empty array when no positions' do
      description_type = create(:description_type)
      description = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        description_type_id: description_type.id
      )
      expect(description.all_positions).to eq([])
    end
  end

  describe '#position_labels' do
    it 'returns humanized position labels' do
      pos = create(:body_position, label: 'left_arm')
      description = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: pos.id
      )
      expect(description.position_labels).to include('Left Arm')
    end
  end

  describe 'aesthetic type helpers' do
    let(:description) do
      CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
    end

    describe '#tattoo?' do
      it 'returns true for tattoo type' do
        description.update(aesthetic_type: 'tattoo')
        expect(description.tattoo?).to be true
      end

      it 'returns false for other types' do
        description.update(aesthetic_type: 'natural')
        expect(description.tattoo?).to be false
      end
    end

    describe '#makeup?' do
      it 'returns true for makeup type' do
        description.update(aesthetic_type: 'makeup')
        expect(description.makeup?).to be true
      end

      it 'returns false for other types' do
        description.update(aesthetic_type: 'natural')
        expect(description.makeup?).to be false
      end
    end

    describe '#hairstyle?' do
      it 'returns true for hairstyle type' do
        description.update(aesthetic_type: 'hairstyle')
        expect(description.hairstyle?).to be true
      end

      it 'returns false for other types' do
        description.update(aesthetic_type: 'natural')
        expect(description.hairstyle?).to be false
      end
    end

    describe '#natural?' do
      it 'returns true for natural type' do
        description.update(aesthetic_type: 'natural')
        expect(description.natural?).to be true
      end

      it 'returns false for other types' do
        description.update(aesthetic_type: 'tattoo')
        expect(description.natural?).to be false
      end
    end
  end

  describe '#visible?' do
    let(:description) do
      CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id
      )
    end

    it 'returns true when no clothing coverage' do
      expect(description.visible?([])).to be true
    end

    it 'returns false when position is covered' do
      expect(description.visible?([body_position.id])).to be false
    end

    it 'returns true when no positions set' do
      description_type = create(:description_type)
      profile_desc = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        description_type_id: description_type.id
      )
      expect(profile_desc.visible?([body_position.id])).to be true
    end
  end

  describe '#body_description?' do
    it 'returns truthy when body_position_id is set' do
      description = CharacterDescription.new(body_position_id: body_position.id)
      expect(description.body_description?).to be_truthy
    end

    it 'returns falsey when no body position' do
      description = CharacterDescription.new
      expect(description.body_description?).to be_falsey
    end
  end

  describe '#profile_description?' do
    it 'returns truthy when description_type_id is set' do
      description_type = create(:description_type)
      description = CharacterDescription.new(description_type_id: description_type.id)
      expect(description.profile_description?).to be_truthy
    end

    it 'returns falsey when no description_type' do
      description = CharacterDescription.new
      expect(description.profile_description?).to be_falsey
    end
  end

  describe '#region' do
    it 'returns the body position region' do
      pos = create(:body_position, region: 'head')
      description = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: pos.id
      )
      expect(description.region).to eq('head')
    end

    it 'returns nil when no positions' do
      description_type = create(:description_type)
      description = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        description_type_id: description_type.id
      )
      expect(description.region).to be_nil
    end
  end

  describe 'dataset methods' do
    let!(:tattoo_desc) do
      CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Tattoo',
        body_position_id: body_position.id,
        aesthetic_type: 'tattoo',
        active: true
      )
    end

    let!(:makeup_desc) do
      CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Makeup',
        body_position_id: create(:body_position).id,
        aesthetic_type: 'makeup',
        active: true
      )
    end

    let!(:inactive_desc) do
      CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Inactive',
        body_position_id: create(:body_position).id,
        aesthetic_type: 'natural',
        active: false
      )
    end

    describe '.tattoos' do
      it 'returns only tattoo descriptions' do
        tattoos = CharacterDescription.tattoos.all
        expect(tattoos).to include(tattoo_desc)
        expect(tattoos).not_to include(makeup_desc)
      end
    end

    describe '.makeup' do
      it 'returns only makeup descriptions' do
        makeup = CharacterDescription.makeup.all
        expect(makeup).to include(makeup_desc)
        expect(makeup).not_to include(tattoo_desc)
      end
    end

    describe '.active_only' do
      it 'excludes inactive descriptions' do
        active = CharacterDescription.active_only.all
        expect(active).to include(tattoo_desc)
        expect(active).to include(makeup_desc)
        expect(active).not_to include(inactive_desc)
      end
    end

    describe '.by_body_position' do
      it 'returns descriptions with body positions' do
        results = CharacterDescription.by_body_position.all
        expect(results).to include(tattoo_desc)
        expect(results.length).to be >= 1
      end
    end
  end

  describe '#hidden_by_clothing?' do
    it 'returns true when concealed and active' do
      description = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id,
        concealed_by_clothing: true,
        active: true
      )
      expect(description.hidden_by_clothing?).to be true
    end

    it 'returns false when not concealed' do
      description = CharacterDescription.create(
        character_instance_id: character_instance.id,
        content: 'Test',
        body_position_id: body_position.id,
        concealed_by_clothing: false,
        active: true
      )
      expect(description.hidden_by_clothing?).to be false
    end
  end
end
