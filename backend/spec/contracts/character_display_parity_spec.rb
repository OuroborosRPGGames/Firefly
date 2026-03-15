# frozen_string_literal: true

require 'spec_helper'

# Character Display Parity Contract Tests
#
# These tests ensure that characters appear identically whether viewed in:
# 1. Character creator preview (DraftCharacterPreviewService)
# 2. In-game look command (CharacterDisplayService)
#
# Note: The two services use different data sources:
# - Draft preview uses CharacterDefaultDescription (template descriptions)
# - In-game uses CharacterDescription (instance-level descriptions)
#
# When testing with descriptions, we create both types with identical content
# to verify the rendering logic produces identical output.

RSpec.describe 'Character Display Parity', type: :contract do
  let!(:user) { create(:user) }
  let!(:reality) { create(:reality) }
  let!(:room) { create(:room, name: 'Test Room') }

  # Create a fully-specified character to test all display fields
  let!(:character) do
    create(:character,
      user: user,
      forename: 'Test',
      surname: 'Character',
      short_desc: 'A mysterious figure',
      gender: 'Male',
      body_type: 'Athletic',
      ethnicity: 'Caucasian',
      height_cm: 180,
      hair_color: 'Black',
      hair_style: 'Short',
      eye_color: 'Blue',
      picture_url: 'https://example.com/portrait.jpg'
    )
  end

  let!(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true
    )
  end

  # Helper to get draft preview display data
  def draft_display
    DraftCharacterPreviewService.new(character).build_display
  end

  # Helper to get in-game display data
  def ingame_display
    CharacterDisplayService.new(character_instance).build_display
  end

  # Helper to create matching descriptions for both draft and in-game
  # Creates CharacterDefaultDescription (for draft) and CharacterDescription (for in-game)
  # with identical content to test rendering parity
  def create_paired_description(body_position:, content:, suffix: 'period', prefix: 'none', image_url: nil, display_order: 1)
    # Create draft description (CharacterDefaultDescription)
    CharacterDefaultDescription.create(
      character: character,
      body_position: body_position,
      content: content,
      suffix: suffix,
      prefix: prefix,
      image_url: image_url,
      display_order: display_order,
      active: true
    )

    # Create instance description (CharacterDescription)
    CharacterDescription.create(
      character_instance: character_instance,
      body_position: body_position,
      content: content,
      suffix: suffix,
      prefix: prefix,
      image_url: image_url,
      display_order: display_order,
      active: true
    )
  end

  describe 'basic character fields' do
    it 'produces identical name' do
      expect(draft_display[:name]).to eq(ingame_display[:name])
    end

    it 'produces identical short_desc' do
      expect(draft_display[:short_desc]).to eq(ingame_display[:short_desc])
    end

    it 'produces identical name_line' do
      expect(draft_display[:name_line]).to eq(ingame_display[:name_line])
    end

    it 'produces identical profile_pic_url' do
      expect(draft_display[:profile_pic_url]).to eq(ingame_display[:profile_pic_url])
    end

    it 'produces identical intro' do
      expect(draft_display[:intro]).to eq(ingame_display[:intro])
    end

    it 'produces identical eyes_hair_line' do
      expect(draft_display[:eyes_hair_line]).to eq(ingame_display[:eyes_hair_line])
    end
  end

  describe 'with body descriptions' do
    let!(:body_position) do
      BodyPosition.find_or_create(label: 'chest') do |bp|
        bp.region = 'torso'
        bp.display_order = 10
      end
    end

    before do
      create_paired_description(
        body_position: body_position,
        content: 'has a large tattoo of a dragon',
        suffix: 'period',
        display_order: 1
      )
    end

    it 'includes body descriptions in both displays' do
      draft_descs = draft_display[:descriptions]
      ingame_descs = ingame_display[:descriptions]

      # Both should have the chest description
      draft_chest = draft_descs.find { |d| d[:body_position] == 'chest' }
      ingame_chest = ingame_descs.find { |d| d[:body_position] == 'chest' }

      expect(draft_chest).not_to be_nil, "Draft display missing chest description. Descs: #{draft_descs.map { |d| d[:body_position] }}"
      expect(ingame_chest).not_to be_nil, "In-game display missing chest description. Descs: #{ingame_descs.map { |d| d[:body_position] }}"
    end

    it 'produces identical description content' do
      draft_descs = draft_display[:descriptions]
      ingame_descs = ingame_display[:descriptions]

      draft_chest = draft_descs.find { |d| d[:body_position] == 'chest' }
      ingame_chest = ingame_descs.find { |d| d[:body_position] == 'chest' }

      expect(draft_chest[:content]).to eq(ingame_chest[:content])
    end

    it 'produces identical separators' do
      draft_descs = draft_display[:descriptions]
      ingame_descs = ingame_display[:descriptions]

      draft_chest = draft_descs.find { |d| d[:body_position] == 'chest' }
      ingame_chest = ingame_descs.find { |d| d[:body_position] == 'chest' }

      expect(draft_chest[:suffix]).to eq(ingame_chest[:suffix])
      expect(draft_chest[:prefix]).to eq(ingame_chest[:prefix])
    end
  end

  describe 'with multiple descriptions and suffixes' do
    let!(:chest_position) do
      BodyPosition.find_or_create(label: 'chest') do |bp|
        bp.region = 'torso'
        bp.display_order = 10
      end
    end

    let!(:arms_position) do
      BodyPosition.find_or_create(label: 'upper_arms') do |bp|
        bp.region = 'arms'
        bp.display_order = 20
      end
    end

    before do
      create_paired_description(
        body_position: chest_position,
        content: 'A scar runs across the chest',
        suffix: 'comma',
        display_order: 1
      )

      create_paired_description(
        body_position: arms_position,
        content: 'Both arms are covered in tattoos',
        suffix: 'period',
        display_order: 2
      )
    end

    it 'preserves description order' do
      draft_descs = draft_display[:descriptions].select { |d| d[:body_position] }
      ingame_descs = ingame_display[:descriptions].select { |d| d[:body_position] }

      # Compare positions in order (excluding default eyes/hair)
      draft_positions = draft_descs.reject { |d| %w[eyes scalp].include?(d[:body_position]) }
                                   .map { |d| d[:body_position] }
      ingame_positions = ingame_descs.reject { |d| %w[eyes scalp].include?(d[:body_position]) }
                                     .map { |d| d[:body_position] }

      expect(draft_positions).to eq(ingame_positions)
    end

    it 'preserves suffix values for each description' do
      draft_descs = draft_display[:descriptions]
      ingame_descs = ingame_display[:descriptions]

      # Check comma suffix
      draft_comma = draft_descs.find { |d| d[:body_position] == 'chest' }
      ingame_comma = ingame_descs.find { |d| d[:body_position] == 'chest' }

      expect(draft_comma[:suffix]).to eq('comma')
      expect(ingame_comma[:suffix]).to eq('comma')

      # Check period suffix
      draft_period = draft_descs.find { |d| d[:body_position] == 'upper_arms' }
      ingame_period = ingame_descs.find { |d| d[:body_position] == 'upper_arms' }

      expect(draft_period[:suffix]).to eq('period')
      expect(ingame_period[:suffix]).to eq('period')
    end
  end

  describe 'with description images' do
    let!(:chest_position) do
      BodyPosition.find_or_create(label: 'chest') do |bp|
        bp.region = 'torso'
        bp.display_order = 10
      end
    end

    before do
      create_paired_description(
        body_position: chest_position,
        content: 'A detailed tattoo',
        image_url: 'https://example.com/tattoo.jpg',
        suffix: 'period',
        display_order: 1
      )
    end

    it 'includes image_url in both displays' do
      draft_descs = draft_display[:descriptions]
      ingame_descs = ingame_display[:descriptions]

      draft_chest = draft_descs.find { |d| d[:body_position] == 'chest' }
      ingame_chest = ingame_descs.find { |d| d[:body_position] == 'chest' }

      expect(draft_chest[:image_url]).to eq('https://example.com/tattoo.jpg')
      expect(ingame_chest[:image_url]).to eq('https://example.com/tattoo.jpg')
    end

    it 'includes thumbnails in both displays' do
      draft_thumbs = draft_display[:thumbnails]
      ingame_thumbs = ingame_display[:thumbnails]

      # Both should include the chest description thumbnail
      draft_thumb = draft_thumbs.find { |t| t[:body_position] == 'chest' }
      ingame_thumb = ingame_thumbs.find { |t| t[:body_position] == 'chest' }

      expect(draft_thumb).not_to be_nil, "Draft display missing chest thumbnail. Thumbs: #{draft_thumbs}"
      expect(ingame_thumb).not_to be_nil, "In-game display missing chest thumbnail. Thumbs: #{ingame_thumbs}"
      expect(draft_thumb[:url]).to eq(ingame_thumb[:url])
    end
  end

  describe 'gender-specific language parity' do
    context 'with male character' do
      it 'uses same pronouns in intro' do
        expect(draft_display[:intro]).to include('He is')
        expect(ingame_display[:intro]).to include('He is')
      end

      it 'uses same pronouns in eyes_hair_line' do
        expect(draft_display[:eyes_hair_line]).to include('He has')
        expect(ingame_display[:eyes_hair_line]).to include('He has')
      end
    end

    context 'with female character' do
      let!(:female_character) do
        create(:character,
          user: user,
          forename: 'Jane',
          surname: 'Doe',
          gender: 'Female',
          body_type: 'Slim'
        )
      end

      let!(:female_instance) do
        create(:character_instance,
          character: female_character,
          reality: reality,
          current_room: room,
          online: true
        )
      end

      def female_draft_display
        DraftCharacterPreviewService.new(female_character).build_display
      end

      def female_ingame_display
        CharacterDisplayService.new(female_instance).build_display
      end

      it 'uses same pronouns in intro' do
        expect(female_draft_display[:intro]).to include('She is')
        expect(female_ingame_display[:intro]).to include('She is')
      end
    end

    context 'with non-binary character' do
      let!(:nb_character) do
        create(:character,
          user: user,
          forename: 'Alex',
          surname: 'Smith',
          gender: nil,
          body_type: 'Average'
        )
      end

      let!(:nb_instance) do
        create(:character_instance,
          character: nb_character,
          reality: reality,
          current_room: room,
          online: true
        )
      end

      def nb_draft_display
        DraftCharacterPreviewService.new(nb_character).build_display
      end

      def nb_ingame_display
        CharacterDisplayService.new(nb_instance).build_display
      end

      it 'uses same pronouns (they/are) in intro' do
        expect(nb_draft_display[:intro]).to include('They are')
        expect(nb_ingame_display[:intro]).to include('They are')
      end
    end
  end

  describe 'structural parity' do
    it 'returns same top-level keys' do
      # Note: Some keys may differ (e.g., draft won't have clothing/held_items populated)
      # We check the common keys that should always exist
      common_keys = %i[name short_desc name_line profile_pic_url intro eyes_hair_line descriptions thumbnails]

      common_keys.each do |key|
        expect(draft_display).to have_key(key), "Draft display missing key: #{key}"
        expect(ingame_display).to have_key(key), "In-game display missing key: #{key}"
      end
    end

    it 'descriptions have consistent structure' do
      draft_descs = draft_display[:descriptions]
      ingame_descs = ingame_display[:descriptions]

      # All descriptions should have these keys
      required_keys = %i[content separator]

      draft_descs.each do |desc|
        required_keys.each do |key|
          expect(desc).to have_key(key), "Draft description missing key: #{key}"
        end
      end

      ingame_descs.each do |desc|
        required_keys.each do |key|
          expect(desc).to have_key(key), "In-game description missing key: #{key}"
        end
      end
    end
  end

  describe 'complete display parity with identical descriptions' do
    let!(:chest_position) do
      BodyPosition.find_or_create(label: 'chest') do |bp|
        bp.region = 'torso'
        bp.display_order = 10
      end
    end

    before do
      create_paired_description(
        body_position: chest_position,
        content: 'A prominent scar',
        suffix: 'period',
        display_order: 1
      )
    end

    it 'produces identical description data when given equivalent input' do
      draft_chest = draft_display[:descriptions].find { |d| d[:body_position] == 'chest' }
      ingame_chest = ingame_display[:descriptions].find { |d| d[:body_position] == 'chest' }

      # Core fields that affect rendering should match
      expect(draft_chest[:content]).to eq(ingame_chest[:content])
      expect(draft_chest[:separator]).to eq(ingame_chest[:separator])
      expect(draft_chest[:body_position]).to eq(ingame_chest[:body_position])
      expect(draft_chest[:image_url]).to eq(ingame_chest[:image_url])
    end
  end

  # Custom matcher for full display parity on comparable fields
  RSpec::Matchers.define :match_display_core_fields do |expected|
    match do |actual|
      @mismatches = []

      # Compare key fields that should always match
      %i[name short_desc name_line profile_pic_url intro eyes_hair_line].each do |key|
        if actual[key] != expected[key]
          @mismatches << "#{key}: expected #{expected[key].inspect}, got #{actual[key].inspect}"
        end
      end

      @mismatches.empty?
    end

    failure_message do |actual|
      "Expected display core fields to match, but found differences:\n  #{@mismatches.join("\n  ")}"
    end
  end

  describe 'core fields parity' do
    it 'draft and in-game displays have matching core fields' do
      expect(draft_display).to match_display_core_fields(ingame_display)
    end
  end
end
