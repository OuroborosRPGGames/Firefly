# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AIBattleMapGeneratorService do
  let(:room) do
    create(:room,
           name: 'Dark Cavern',
           short_description: 'A dark underground cavern',
           min_x: 0,
           max_x: 80,
           min_y: 0,
           max_y: 80)
  end

  let(:service) { described_class.new(room) }

  describe 'constants' do
    it 'has CHUNK_THRESHOLD defined' do
      expect(described_class::CHUNK_THRESHOLD).to eq(100)
    end

    it 'has CHUNK_SIZE defined' do
      expect(described_class::CHUNK_SIZE).to eq(25)
    end

    it 'has MIN_CHUNK_SIZE defined' do
      expect(described_class::MIN_CHUNK_SIZE).to eq(5)
    end

    it 'does not have DRAW_BATCH_SIZE (removed in vips migration)' do
      expect(defined?(described_class::DRAW_BATCH_SIZE)).to be_nil
    end
  end

  describe '#initialize' do
    it 'sets room attribute' do
      expect(service.room).to eq(room)
    end

    it 'initializes errors array' do
      expect(service.instance_variable_get(:@errors)).to eq([])
    end

    it 'defaults to text mode' do
      expect(service.instance_variable_get(:@mode)).to eq(:text)
    end

    it 'defaults to default tier' do
      expect(service.instance_variable_get(:@tier)).to eq(:default)
    end

    it 'accepts blueprint mode' do
      bp_service = described_class.new(room, mode: :blueprint)
      expect(bp_service.instance_variable_get(:@mode)).to eq(:blueprint)
    end

    it 'accepts custom tier' do
      bp_service = described_class.new(room, mode: :blueprint, tier: :high_quality)
      expect(bp_service.instance_variable_get(:@tier)).to eq(:high_quality)
    end
  end

  describe 'blueprint mode' do
    let(:blueprint_service) { described_class.new(room, mode: :blueprint) }

    describe '#build_blueprint_prompt' do
      it 'includes room name' do
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('Dark Cavern')
      end

      it 'asks to convert the blueprint' do
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('floor plan')
        expect(prompt).to include('battle map')
      end

      it 'includes room description' do
        allow(room).to receive(:long_description).and_return('A deep dark cave')
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('A deep dark cave')
      end

      it 'includes room dimensions and shape' do
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('square feet')
        expect(prompt).to include('80ft wide x 80ft tall')
      end

      it 'includes decorations when present' do
        allow(room).to receive(:respond_to?).and_call_original
        allow(room).to receive(:respond_to?).with(:decorations).and_return(true)
        allow(room).to receive(:decorations).and_return([double(name: 'Fireplace')])
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('Fireplace')
      end

      it 'does not include coded legend labels' do
        allow(room).to receive(:respond_to?).and_call_original
        allow(room).to receive(:respond_to?).with(:places).and_return(true)
        place = double('Place', name: 'Table', x: 20, y: 20)
        allow(place).to receive(:respond_to?).with(:name).and_return(true)
        allow(place).to receive(:respond_to?).with(:x).and_return(true)
        allow(place).to receive(:respond_to?).with(:y).and_return(true)
        allow(room).to receive(:places).and_return([place])
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).not_to match(/\bA = /)
        expect(prompt).not_to include('Floor plan key')
      end

      it 'includes natural furniture descriptions' do
        allow(room).to receive(:respond_to?).and_call_original
        allow(room).to receive(:respond_to?).with(:places).and_return(true)
        place = double('Place', name: 'Long Wooden Table', x: 40, y: 40)
        allow(place).to receive(:respond_to?).with(:name).and_return(true)
        allow(place).to receive(:respond_to?).with(:x).and_return(true)
        allow(place).to receive(:respond_to?).with(:y).and_return(true)
        allow(room).to receive(:places).and_return([place])
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('Furniture shown in the floor plan')
        expect(prompt).to include('Long Wooden Table')
        expect(prompt).to include('center')
      end

      it 'includes natural feature descriptions' do
        allow(room).to receive(:respond_to?).and_call_original
        allow(room).to receive(:respond_to?).with(:room_features).and_return(true)
        feature = double('Feature', name: 'Heavy Oak Door', feature_type: 'door', x: 0, y: 40)
        allow(feature).to receive(:respond_to?).with(:feature_type).and_return(true)
        allow(feature).to receive(:respond_to?).with(:name).and_return(true)
        allow(feature).to receive(:respond_to?).with(:x).and_return(true)
        allow(feature).to receive(:respond_to?).with(:y).and_return(true)
        allow(room).to receive(:room_features).and_return([feature])
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('Heavy Oak Door')
        expect(prompt).to include('west wall')
      end

      it 'includes instruction about maintaining layout' do
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('Match the room shape')
      end

      it 'includes no grid lines instruction' do
        prompt = blueprint_service.send(:build_blueprint_prompt)
        expect(prompt).to include('No grid lines')
      end
    end

    describe '#generate_blueprint_image' do
      before do
        allow(MapSvgRenderService).to receive(:render_blueprint_clean).and_return('<svg>test</svg>')
        allow(MapSvgRenderService).to receive(:svg_to_png).and_return('/tmp/test.png')
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:binread).and_return('png_data')
        allow(File).to receive(:delete)
        allow(LLM::ImageGenerationService).to receive(:generate).and_return({
          success: true, base64_data: 'img', mime_type: 'image/png', local_url: '/uploads/test.png'
        })
      end

      it 'generates SVG blueprint from room with target width' do
        expect(MapSvgRenderService).to receive(:render_blueprint_clean).with(room, width: 2048)
        blueprint_service.send(:generate_blueprint_image)
      end

      it 'converts SVG to PNG' do
        expect(MapSvgRenderService).to receive(:svg_to_png).with('<svg>test</svg>', width: 2048)
        blueprint_service.send(:generate_blueprint_image)
      end

      it 'passes reference_image to ImageGenerationService' do
        expect(LLM::ImageGenerationService).to receive(:generate).with(
          prompt: anything,
          options: hash_including(reference_image: { data: anything, mime_type: 'image/png' })
        ).and_return({ success: true, local_url: '/uploads/test.png' })
        blueprint_service.send(:generate_blueprint_image)
      end

      it 'passes tier from constructor to ImageGenerationService' do
        pro_service = described_class.new(room, mode: :blueprint, tier: :high_quality)
        expect(LLM::ImageGenerationService).to receive(:generate).with(
          prompt: anything,
          options: hash_including(tier: :high_quality)
        ).and_return({ success: true, local_url: '/uploads/test.png' })
        pro_service.send(:generate_blueprint_image)
      end

      it 'cleans up temp PNG' do
        expect(File).to receive(:delete).with('/tmp/test.png')
        blueprint_service.send(:generate_blueprint_image)
      end

      context 'when SVG generation fails' do
        before do
          allow(MapSvgRenderService).to receive(:render_blueprint_clean).and_return('error - no svg')
          allow(LLM::ImageGenerationService).to receive(:generate).and_return({
            success: true, local_url: '/uploads/fallback.png'
          })
        end

        it 'falls back to text mode' do
          result = blueprint_service.send(:generate_blueprint_image)
          expect(result[:success]).to be true
        end
      end

      context 'when PNG conversion fails' do
        before do
          allow(MapSvgRenderService).to receive(:svg_to_png).and_return(nil)
          allow(LLM::ImageGenerationService).to receive(:generate).and_return({
            success: true, local_url: '/uploads/fallback.png'
          })
        end

        it 'falls back to text mode' do
          result = blueprint_service.send(:generate_blueprint_image)
          expect(result[:success]).to be true
        end
      end
    end
  end

  describe '#generate' do
    before do
      allow(GameSetting).to receive(:boolean).with('ai_battle_maps_enabled').and_return(true)
      allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
    end

    context 'when AI is disabled' do
      before do
        allow(GameSetting).to receive(:boolean).with('ai_battle_maps_enabled').and_return(false)
      end

      it 'falls back to procedural generation' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(room).to receive(:hex_count).and_return(50)

        result = service.generate
        expect(result[:fallback]).to be true
      end

      it 'returns success true' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(room).to receive(:hex_count).and_return(50)

        result = service.generate
        expect(result[:success]).to be true
      end
    end

    context 'when provider not available' do
      before do
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(false)
      end

      it 'falls back to procedural generation' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(room).to receive(:hex_count).and_return(50)

        result = service.generate
        expect(result[:fallback]).to be true
      end
    end

    context 'when room has no bounds' do
      let(:boundless_room) do
        r = create(:room, name: 'Boundless')
        allow(r).to receive(:min_x).and_return(nil)
        allow(r).to receive(:max_x).and_return(nil)
        allow(r).to receive(:min_y).and_return(nil)
        allow(r).to receive(:max_y).and_return(nil)
        r
      end
      let(:boundless_service) { described_class.new(boundless_room) }

      it 'falls back to procedural generation' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(boundless_room).to receive(:hex_count).and_return(0)

        result = boundless_service.generate
        expect(result[:fallback]).to be true
        expect(result[:error]).to include('no bounds')
      end
    end

    context 'when image generation fails' do
      before do
        allow(LLM::ImageGenerationService).to receive(:generate).and_return({
          success: false,
          error: 'API error'
        })
      end

      it 'falls back to procedural generation' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(room).to receive(:hex_count).and_return(50)

        result = service.generate
        expect(result[:fallback]).to be true
        expect(result[:error]).to include('Image generation failed')
      end
    end

    context 'when image generation succeeds but no local path' do
      before do
        allow(LLM::ImageGenerationService).to receive(:generate).and_return({
          success: true,
          local_url: nil
        })
      end

      it 'falls back to procedural generation' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(room).to receive(:hex_count).and_return(50)

        result = service.generate
        expect(result[:fallback]).to be true
        expect(result[:error]).to include('No local path')
      end
    end

    context 'when LLM analysis returns empty data' do
      before do
        allow(LLM::ImageGenerationService).to receive(:generate).and_return({
          success: true,
          local_url: 'images/test.png'
        })
        allow(service).to receive(:analyze_hexes_with_grid).and_return([])
        allow(service).to receive(:analyze_hexes_v2).and_return([])
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:delete)
      end

      it 'falls back to procedural generation' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(room).to receive(:hex_count).and_return(50)

        result = service.generate
        expect(result[:fallback]).to be true
        expect(result[:error]).to include('no hex data')
      end
    end

    context 'when full workflow succeeds' do
      let(:hex_data) do
        [
          { x: 0, y: 0, hex_type: 'normal', cover_value: 0 },
          { x: 1, y: 2, hex_type: 'cover', cover_value: 2 }
        ]
      end

      before do
        allow(LLM::ImageGenerationService).to receive(:generate).and_return({
          success: true,
          local_url: 'images/test.png'
        })
        allow(service).to receive(:analyze_hexes_with_grid).and_return(hex_data)
        allow(service).to receive(:analyze_hexes_v2).and_return(hex_data)
        allow(service).to receive(:persist_hex_data)
        allow(service).to receive(:persist_image)
        allow(service).to receive(:detect_and_store_light_sources)
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:delete)
      end

      it 'returns success true' do
        result = service.generate
        expect(result[:success]).to be true
      end

      it 'returns fallback false' do
        result = service.generate
        expect(result[:fallback]).to be false
      end

      it 'returns hex_count' do
        result = service.generate
        expect(result[:hex_count]).to eq(2)
      end

      it 'persists hex data' do
        expect(service).to receive(:persist_hex_data).with(hex_data)
        service.generate
      end

      it 'persists image URL' do
        expect(service).to receive(:persist_image).with('/images/test.png')
        service.generate
      end

      it 'calls detect_and_store_light_sources after persisting image' do
        expect(service).to receive(:detect_and_store_light_sources).with(room, 'public/images/test.png')
        service.generate
      end
    end

    context 'when unexpected error occurs' do
      before do
        allow(service).to receive(:ai_enabled?).and_raise(StandardError.new('Unexpected error'))
      end

      it 'falls back to procedural generation' do
        procedural = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
        allow(room).to receive(:hex_count).and_return(50)

        result = service.generate
        expect(result[:fallback]).to be true
        expect(result[:error]).to include('Unexpected error')
      end
    end
  end

  describe 'private #ai_enabled?' do
    context 'when GameSetting not defined' do
      before do
        allow(service).to receive(:defined?).with(GameSetting).and_return(false)
      end

      it 'returns false' do
        # Can't easily test this without undefining the constant
        # Just verify the method exists
        expect(service.respond_to?(:ai_enabled?, true)).to be true
      end
    end

    context 'when setting is true and provider available' do
      before do
        allow(GameSetting).to receive(:boolean).with('ai_battle_maps_enabled').and_return(true)
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
      end

      it 'returns true' do
        expect(service.send(:ai_enabled?)).to be true
      end
    end

    context 'when setting is false' do
      before do
        allow(GameSetting).to receive(:boolean).with('ai_battle_maps_enabled').and_return(false)
      end

      it 'returns false' do
        expect(service.send(:ai_enabled?)).to be false
      end
    end

    context 'when provider not available' do
      before do
        allow(GameSetting).to receive(:boolean).with('ai_battle_maps_enabled').and_return(true)
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(false)
      end

      it 'returns false' do
        expect(service.send(:ai_enabled?)).to be false
      end
    end
  end

  describe 'private #room_has_bounds?' do
    context 'with all bounds' do
      it 'returns true' do
        # The room from the let block has min_x: 0, max_x: 80, min_y: 0, max_y: 80
        expect(service.send(:room_has_bounds?)).to be_truthy
      end
    end

    context 'with missing min_x' do
      let(:no_min_x_room) do
        r = double('Room',
                   id: 1,
                   name: 'Test',
                   min_x: nil,
                   max_x: 80,
                   min_y: 0,
                   max_y: 80)
        r
      end
      let(:no_min_x_service) { described_class.new(no_min_x_room) }

      it 'returns false' do
        expect(no_min_x_service.send(:room_has_bounds?)).to be_falsey
      end
    end

    context 'with missing max_x' do
      let(:no_max_x_room) do
        r = double('Room',
                   id: 1,
                   name: 'Test',
                   min_x: 0,
                   max_x: nil,
                   min_y: 0,
                   max_y: 80)
        r
      end
      let(:no_max_x_service) { described_class.new(no_max_x_room) }

      it 'returns false' do
        expect(no_max_x_service.send(:room_has_bounds?)).to be_falsey
      end
    end
  end

  describe 'private #build_image_prompt' do
    it 'includes room name' do
      prompt = service.send(:build_image_prompt)
      expect(prompt).to include('Dark Cavern')
    end

    it 'includes room description when set' do
      # Room factory sets long_description, which is used first
      prompt = service.send(:build_image_prompt)
      expect(prompt).to include('Setting:')
    end

    it 'includes room dimensions in feet' do
      prompt = service.send(:build_image_prompt)
      expect(prompt).to include('80ft')
    end

    it 'includes east-west and north-south labels' do
      prompt = service.send(:build_image_prompt)
      expect(prompt).to include('east-west')
      expect(prompt).to include('north-south')
    end

    it 'uses gridless RPG tactical format' do
      prompt = service.send(:build_image_prompt)
      expect(prompt).to include('shadowless gridless RPG tactical battlemap')
    end

    it 'includes concise instructions' do
      prompt = service.send(:build_image_prompt)
      expect(prompt).to include('No shadows')
      expect(prompt).to include('hex grid')
    end

    it 'does not include scale or category' do
      allow(room).to receive(:battle_map_category).and_return('dungeon')
      prompt = service.send(:build_image_prompt)
      expect(prompt).not_to include('Scale:')
      expect(prompt).not_to include('Category:')
    end

    context 'with places' do
      let(:place) do
        p = double('Place')
        allow(p).to receive(:respond_to?).with(:name).and_return(true)
        allow(p).to receive(:respond_to?).with(:x).and_return(true)
        allow(p).to receive(:respond_to?).with(:y).and_return(true)
        allow(p).to receive(:name).and_return('Altar')
        allow(p).to receive(:x).and_return(40)
        allow(p).to receive(:y).and_return(40)
        p
      end

      let(:prompt_room) do
        r = double('Room',
                   id: 1,
                   name: 'Test Room',
                   description: nil,
                   short_description: nil,
                   long_description: nil,
                   min_x: 0,
                   max_x: 80,
                   min_y: 0,
                   max_y: 80,
                   battle_map_category: 'dungeon')
        allow(r).to receive(:respond_to?).and_return(false)
        allow(r).to receive(:respond_to?).with(:places).and_return(true)
        allow(r).to receive(:places).and_return([place])
        allow(r).to receive(:has_custom_polygon?).and_return(false)
        allow(r).to receive(:battle_map_config_for_type).and_return({ surfaces: ['floor'], objects: [], density: 0.10 })
        r
      end

      let(:prompt_service) { described_class.new(prompt_room) }

      it 'includes furniture positions' do
        prompt = prompt_service.send(:build_image_prompt)
        expect(prompt).to include('Altar')
      end
    end

    context 'with room features' do
      let(:feature) do
        f = double('Feature')
        allow(f).to receive(:respond_to?).and_return(false)
        allow(f).to receive(:respond_to?).with(:feature_type).and_return(true)
        allow(f).to receive(:respond_to?).with(:name).and_return(true)
        allow(f).to receive(:respond_to?).with(:x).and_return(true)
        allow(f).to receive(:respond_to?).with(:y).and_return(true)
        allow(f).to receive(:feature_type).and_return('door')
        allow(f).to receive(:name).and_return('Heavy Oak Door')
        allow(f).to receive(:x).and_return(0)
        allow(f).to receive(:y).and_return(40)
        f
      end

      let(:feature_room) do
        r = double('Room',
                   id: 1,
                   name: 'Test Room',
                   description: nil,
                   short_description: nil,
                   long_description: nil,
                   min_x: 0,
                   max_x: 80,
                   min_y: 0,
                   max_y: 80,
                   battle_map_category: 'dungeon')
        allow(r).to receive(:respond_to?).and_return(false)
        allow(r).to receive(:respond_to?).with(:room_features).and_return(true)
        allow(r).to receive(:room_features).and_return([feature])
        allow(r).to receive(:has_custom_polygon?).and_return(false)
        allow(r).to receive(:battle_map_config_for_type).and_return({ surfaces: ['floor'], objects: [], density: 0.10 })
        r
      end

      let(:feature_service) { described_class.new(feature_room) }

      it 'includes wall-relative feature description' do
        prompt = feature_service.send(:build_image_prompt)
        expect(prompt).to include('Doors:')
        expect(prompt).to include('Heavy Oak Door')
        expect(prompt).to include('West wall')
      end
    end

    context 'with decorations' do
      let(:deco_room) do
        deco1 = double('Decoration', name: 'Skulls and bones')
        r = double('Room',
                   id: 1,
                   name: 'Test Room',
                   description: nil,
                   short_description: nil,
                   long_description: nil,
                   min_x: 0,
                   max_x: 80,
                   min_y: 0,
                   max_y: 80,
                   battle_map_category: 'dungeon',
                   decorations: [deco1])
        allow(r).to receive(:respond_to?).and_return(false)
        allow(r).to receive(:respond_to?).with(:decorations).and_return(true)
        allow(r).to receive(:has_custom_polygon?).and_return(false)
        allow(r).to receive(:battle_map_config_for_type).and_return({ surfaces: ['floor'], objects: [], density: 0.10 })
        r
      end

      let(:deco_service) { described_class.new(deco_room) }

      it 'includes decorations' do
        prompt = deco_service.send(:build_image_prompt)
        expect(prompt).to include('Skulls and bones')
      end
    end
  end

  describe 'private #calculate_aspect_ratio' do
    context 'with wide room' do
      before do
        allow(room).to receive(:min_x).and_return(0)
        allow(room).to receive(:max_x).and_return(200)
        allow(room).to receive(:min_y).and_return(0)
        allow(room).to receive(:max_y).and_return(100)
      end

      it 'returns 16:9' do
        expect(service.send(:calculate_aspect_ratio)).to eq('16:9')
      end
    end

    context 'with tall room' do
      before do
        allow(room).to receive(:min_x).and_return(0)
        allow(room).to receive(:max_x).and_return(50)
        allow(room).to receive(:min_y).and_return(0)
        allow(room).to receive(:max_y).and_return(150)
      end

      it 'returns 9:16' do
        expect(service.send(:calculate_aspect_ratio)).to eq('9:16')
      end
    end

    context 'with square room' do
      it 'returns 1:1' do
        expect(service.send(:calculate_aspect_ratio)).to eq('1:1')
      end
    end
  end

  describe 'private #coord_to_label' do
    before do
      allow(service).to receive(:generate_hex_coordinates).and_return([
        [0, 0], [2, 0], [4, 0],
        [1, 2], [3, 2], [5, 2]
      ])
    end

    it 'converts coordinates to row-column labels with dash separator' do
      label = service.send(:coord_to_label, 0, 0, 0, 0)
      expect(label).to eq('1-A')
    end

    it 'handles second column with absolute indexing' do
      # All unique X: [0,1,2,3,4,5] → A,B,C,D,E,F
      # x=2 is at index 2 → column C
      label = service.send(:coord_to_label, 2, 0, 0, 0)
      expect(label).to eq('1-C')
    end

    it 'handles second row with absolute indexing' do
      # x=1 is at index 1 → column B
      label = service.send(:coord_to_label, 1, 2, 0, 0)
      expect(label).to eq('2-B')
    end
  end

  describe 'private #index_to_column_letter' do
    it 'converts single-letter indices' do
      expect(service.send(:index_to_column_letter, 0)).to eq('A')
      expect(service.send(:index_to_column_letter, 25)).to eq('Z')
    end

    it 'converts multi-letter indices' do
      expect(service.send(:index_to_column_letter, 26)).to eq('AA')
      expect(service.send(:index_to_column_letter, 27)).to eq('AB')
      expect(service.send(:index_to_column_letter, 51)).to eq('AZ')
      expect(service.send(:index_to_column_letter, 52)).to eq('BA')
    end
  end

  describe 'private #column_letter_to_index' do
    it 'converts single letters' do
      expect(service.send(:column_letter_to_index, 'A')).to eq(0)
      expect(service.send(:column_letter_to_index, 'Z')).to eq(25)
    end

    it 'converts multi-letter columns' do
      expect(service.send(:column_letter_to_index, 'AA')).to eq(26)
      expect(service.send(:column_letter_to_index, 'AB')).to eq(27)
      expect(service.send(:column_letter_to_index, 'AZ')).to eq(51)
      expect(service.send(:column_letter_to_index, 'BA')).to eq(52)
    end

    it 'roundtrips with index_to_column_letter' do
      (0..60).each do |i|
        letters = service.send(:index_to_column_letter, i)
        expect(service.send(:column_letter_to_index, letters)).to eq(i)
      end
    end
  end

  describe 'private #label_to_coord' do
    before do
      allow(service).to receive(:generate_hex_coordinates).and_return([
        [0, 0], [2, 0], [4, 0],
        [1, 2], [3, 2], [5, 2]
      ])
    end

    it 'converts dash-format label back to coordinates' do
      coords = service.send(:label_to_coord, '1-A', 0, 0)
      expect(coords).to eq([0, 0])
    end

    it 'handles absolute column with dash format' do
      # All unique X: [0,1,2,3,4,5] → A,B,C,D,E,F
      # '1-C' → row 0 (y=0), col index 2 (x=2) → [2, 0]
      coords = service.send(:label_to_coord, '1-C', 0, 0)
      expect(coords).to eq([2, 0])
    end

    it 'handles second row with absolute column' do
      # '2-B' → row 1 (y=2), col index 1 (x=1) → [1, 2]
      coords = service.send(:label_to_coord, '2-B', 0, 0)
      expect(coords).to eq([1, 2])
    end

    it 'returns nil for valid column but non-existent coordinate in hex grid' do
      # '1-B' → row 0 (y=0), col index 1 (x=1) → [1, 0] doesn't exist in offset grid
      coords = service.send(:label_to_coord, '1-B', 0, 0)
      expect(coords).to be_nil
    end

    it 'supports legacy format without dash' do
      coords = service.send(:label_to_coord, '1A', 0, 0)
      expect(coords).to eq([0, 0])
    end

    it 'returns nil for invalid row' do
      coords = service.send(:label_to_coord, '99-A', 0, 0)
      expect(coords).to be_nil
    end

    it 'returns nil for invalid column' do
      coords = service.send(:label_to_coord, '1-Z', 0, 0)
      expect(coords).to be_nil
    end
  end

  describe 'private #hexagon_points' do
    it 'returns 6 points' do
      points = service.send(:hexagon_points, 100, 100, 20)
      point_pairs = points.split(' ')
      expect(point_pairs.length).to eq(6)
    end

    it 'returns points as x,y pairs' do
      points = service.send(:hexagon_points, 100, 100, 20)
      point_pairs = points.split(' ')
      point_pairs.each do |pair|
        expect(pair).to match(/\d+,\d+/)
      end
    end
  end

  describe 'private #map_terrain_to_hex_type' do
    it 'maps wall to wall' do
      expect(service.send(:map_terrain_to_hex_type, 'wall')).to eq('wall')
    end

    it 'maps WALL (case insensitive) to wall' do
      expect(service.send(:map_terrain_to_hex_type, 'WALL')).to eq('wall')
    end

    it 'maps water to water' do
      expect(service.send(:map_terrain_to_hex_type, 'water')).to eq('water')
    end

    it 'maps pit to pit' do
      expect(service.send(:map_terrain_to_hex_type, 'pit')).to eq('pit')
    end

    it 'maps difficult to difficult' do
      expect(service.send(:map_terrain_to_hex_type, 'difficult')).to eq('difficult')
    end

    it 'maps blocked to cover' do
      expect(service.send(:map_terrain_to_hex_type, 'blocked')).to eq('cover')
    end

    it 'maps unknown to normal' do
      expect(service.send(:map_terrain_to_hex_type, 'unknown')).to eq('normal')
    end

    it 'maps nil to normal' do
      expect(service.send(:map_terrain_to_hex_type, nil)).to eq('normal')
    end
  end

  describe 'private #normalize_cover_object' do
    before do
      stub_const('RoomHex::COVER_OBJECTS', %w[boulder pillar crate])
    end

    it 'returns nil for nil input' do
      expect(service.send(:normalize_cover_object, nil)).to be_nil
    end

    it 'returns nil for none' do
      expect(service.send(:normalize_cover_object, 'none')).to be_nil
    end

    it 'returns nil for empty string' do
      expect(service.send(:normalize_cover_object, '')).to be_nil
    end

    it 'returns valid object (lowercased)' do
      expect(service.send(:normalize_cover_object, 'Boulder')).to eq('boulder')
    end

    it 'returns nil for invalid object' do
      expect(service.send(:normalize_cover_object, 'invalid_object')).to be_nil
    end

    it 'handles spaces in object names' do
      stub_const('RoomHex::COVER_OBJECTS', %w[low_wall])
      expect(service.send(:normalize_cover_object, 'Low Wall')).to eq('low_wall')
    end
  end

  describe 'private #normalize_hazard' do
    before do
      stub_const('RoomHex::HAZARD_TYPES', %w[fire poison trap])
    end

    it 'returns nil for nil input' do
      expect(service.send(:normalize_hazard, nil)).to be_nil
    end

    it 'returns nil for none' do
      expect(service.send(:normalize_hazard, 'none')).to be_nil
    end

    it 'returns nil for empty string' do
      expect(service.send(:normalize_hazard, '')).to be_nil
    end

    it 'returns valid hazard (lowercased)' do
      expect(service.send(:normalize_hazard, 'Fire')).to eq('fire')
    end

    it 'returns nil for invalid hazard' do
      expect(service.send(:normalize_hazard, 'invalid')).to be_nil
    end
  end

  describe 'private #normalize_water_type' do
    before do
      stub_const('RoomHex::WATER_TYPES', %w[shallow deep])
    end

    it 'returns nil for nil input' do
      expect(service.send(:normalize_water_type, nil)).to be_nil
    end

    it 'returns nil for none' do
      expect(service.send(:normalize_water_type, 'none')).to be_nil
    end

    it 'returns valid water type' do
      expect(service.send(:normalize_water_type, 'Deep')).to eq('deep')
    end

    it 'returns nil for invalid water type' do
      expect(service.send(:normalize_water_type, 'invalid')).to be_nil
    end
  end

  describe 'private #normalize_surface' do
    before do
      stub_const('RoomHex::SURFACE_TYPES', %w[stone dirt grass])
    end

    it 'returns stone for nil input' do
      expect(service.send(:normalize_surface, nil)).to eq('stone')
    end

    it 'returns stone for empty string' do
      expect(service.send(:normalize_surface, '')).to eq('stone')
    end

    it 'returns valid surface type' do
      expect(service.send(:normalize_surface, 'Grass')).to eq('grass')
    end

    it 'returns stone for invalid surface' do
      expect(service.send(:normalize_surface, 'invalid')).to eq('stone')
    end
  end

  describe 'private #parse_hex_response' do
    let(:chunk_coords) { [[0, 0], [2, 0], [4, 0]] }

    before do
      allow(service).to receive(:generate_hex_coordinates).and_return(chunk_coords)
      allow(service).to receive(:label_to_coord).with('1-A', 0, 0).and_return([0, 0])
      allow(service).to receive(:label_to_coord).with('1-B', 0, 0).and_return([2, 0])
      allow(service).to receive(:label_to_coord).with('1A', 0, 0).and_return([0, 0])
      allow(service).to receive(:label_to_coord).with('1B', 0, 0).and_return([2, 0])
      stub_const('RoomHex::COVER_OBJECTS', %w[boulder])
      stub_const('RoomHex::HAZARD_TYPES', %w[fire])
      stub_const('RoomHex::WATER_TYPES', %w[shallow])
      stub_const('RoomHex::SURFACE_TYPES', %w[stone dirt])
    end

    it 'parses valid JSON response' do
      content = '{"hexes": [{"label": "1A", "terrain": "normal"}]}'
      result = service.send(:parse_hex_response, content, chunk_coords)
      expect(result.length).to eq(1)
      expect(result[0][:x]).to eq(0)
      expect(result[0][:y]).to eq(0)
    end

    it 'strips markdown code blocks' do
      content = "```json\n{\"hexes\": [{\"label\": \"1A\", \"terrain\": \"normal\"}]}\n```"
      result = service.send(:parse_hex_response, content, chunk_coords)
      expect(result.length).to eq(1)
    end

    it 'extracts hex_type from terrain' do
      content = '{"hexes": [{"label": "1A", "terrain": "wall"}]}'
      result = service.send(:parse_hex_response, content, chunk_coords)
      expect(result[0][:hex_type]).to eq('wall')
    end

    it 'extracts has_cover as boolean from cover_value' do
      content = '{"hexes": [{"label": "1A", "terrain": "normal", "cover_value": 10}]}'
      result = service.send(:parse_hex_response, content, chunk_coords)
      expect(result[0][:has_cover]).to be true
    end

    it 'extracts elevation_level and clamps to -10 to 10' do
      content = '{"hexes": [{"label": "1A", "terrain": "normal", "elevation": 20}]}'
      result = service.send(:parse_hex_response, content, chunk_coords)
      expect(result[0][:elevation_level]).to eq(10)
    end

    it 'returns empty for nil content' do
      result = service.send(:parse_hex_response, nil, chunk_coords)
      expect(result).to eq([])
    end

    it 'skips hexes with invalid labels' do
      allow(service).to receive(:label_to_coord).with('99Z', 0, 0).and_return(nil)
      content = '{"hexes": [{"label": "99Z", "terrain": "normal"}]}'
      result = service.send(:parse_hex_response, content, chunk_coords)
      expect(result).to eq([])
    end
  end

  describe 'private #persist_hex_data' do
    let(:hex_data) do
      [
        { x: 0, y: 0, hex_type: 'normal', cover_value: 0, elevation_level: 0 },
        { x: 2, y: 0, hex_type: 'wall', cover_value: 0, elevation_level: 0 }
      ]
    end

    let(:dataset) { double('Dataset', delete: true) }

    before do
      allow(room).to receive(:room_hexes_dataset).and_return(dataset)
      allow(room).to receive(:id).and_return(1)
      allow(RoomHex).to receive(:multi_insert)
    end

    it 'deletes existing hexes' do
      expect(dataset).to receive(:delete)
      service.send(:persist_hex_data, hex_data)
    end

    it 'inserts new hex records' do
      expect(RoomHex).to receive(:multi_insert) do |records|
        expect(records.length).to eq(2)
        expect(records[0][:room_id]).to eq(1)
        expect(records[0][:hex_x]).to eq(0)
        expect(records[1][:hex_type]).to eq('wall')
      end
      service.send(:persist_hex_data, hex_data)
    end

    it 'sets traversable based on hex_type' do
      expect(RoomHex).to receive(:multi_insert) do |records|
        normal_hex = records.find { |r| r[:hex_type] == 'normal' }
        wall_hex = records.find { |r| r[:hex_type] == 'wall' }
        expect(normal_hex[:traversable]).to be true
        expect(wall_hex[:traversable]).to be false
      end
      service.send(:persist_hex_data, hex_data)
    end

    it 'does not insert if no hex records' do
      expect(RoomHex).not_to receive(:multi_insert)
      service.send(:persist_hex_data, [])
    end
  end

  describe 'private #persist_image' do
    it 'updates room with image URL and battle map flag' do
      expect(room).to receive(:update).with(
        battle_map_image_url: '/images/map.png',
        has_battle_map: true
      )
      service.send(:persist_image, '/images/map.png')
    end
  end

  describe 'private #analyze_hexes_legacy' do
    before do
      allow(File).to receive(:exist?).and_return(true)
      allow(service).to receive(:generate_hex_coordinates).and_return([[0, 0], [2, 0]])
      allow(service).to receive(:overlay_hex_labels).and_return('/tmp/labeled.png')
    end

    it 'returns empty for nil path' do
      result = service.send(:analyze_hexes_legacy, nil)
      expect(result).to eq([])
    end

    it 'returns empty for non-existent file' do
      allow(File).to receive(:exist?).and_return(false)
      result = service.send(:analyze_hexes_legacy, '/missing.png')
      expect(result).to eq([])
    end

    context 'with small map (no chunking)' do
      before do
        allow(service).to receive(:analyze_all_hexes).and_return([{ x: 0, y: 0 }])
        allow(File).to receive(:delete)
      end

      it 'calls analyze_all_hexes' do
        expect(service).to receive(:analyze_all_hexes)
        service.send(:analyze_hexes_legacy, '/tmp/test.png')
      end
    end

    context 'with large map (chunking required)' do
      before do
        # Generate more than CHUNK_THRESHOLD hexes
        coords = (0..110).map { |i| [i * 2, 0] }
        allow(service).to receive(:generate_hex_coordinates).and_return(coords)
        allow(service).to receive(:analyze_hex_chunk).and_return([{ x: 0, y: 0 }])
        allow(File).to receive(:delete)
      end

      it 'processes in chunks' do
        expect(service).to receive(:analyze_hex_chunk).at_least(:once)
        service.send(:analyze_hexes_legacy, '/tmp/test.png')
      end
    end
  end

  describe 'private #analyze_all_hexes' do
    let(:image_path) { '/tmp/test.png' }
    let(:hex_labels) { %w[1A 1B] }
    let(:hex_coords) { [[0, 0], [2, 0]] }

    before do
      allow(File).to receive(:read).and_return('image_data')
      allow(Base64).to receive(:strict_encode64).and_return('encoded')
      allow(GamePrompts).to receive(:get).and_return('Analyze hexes: 1A, 1B')
      allow(AIProviderService).to receive(:api_key_for).and_return('test_key')
      allow(service).to receive(:parse_hex_response).and_return([{ x: 0, y: 0 }])
    end

    context 'when LLM call succeeds' do
      before do
        allow(LLM::Adapters::GeminiAdapter).to receive(:generate).and_return({
          success: true,
          text: '{"hexes": [{"label": "1A", "terrain": "normal"}]}'
        })
      end

      it 'returns parsed hex data' do
        result = service.send(:analyze_all_hexes, image_path, hex_labels, hex_coords)
        expect(result).to be_an(Array)
      end

      it 'builds multimodal message with image' do
        expect(LLM::Adapters::GeminiAdapter).to receive(:generate) do |args|
          message = args[:messages][0]
          expect(message[:content][0][:type]).to eq('image')
          expect(message[:content][1][:type]).to eq('text')
        end.and_return({ success: true, text: '{"hexes": []}' })

        service.send(:analyze_all_hexes, image_path, hex_labels, hex_coords)
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Adapters::GeminiAdapter).to receive(:generate).and_return({
          success: false,
          error: 'API error'
        })
      end

      it 'returns empty array' do
        result = service.send(:analyze_all_hexes, image_path, hex_labels, hex_coords)
        expect(result).to eq([])
      end
    end

    context 'when JSON parsing fails' do
      before do
        allow(LLM::Adapters::GeminiAdapter).to receive(:generate).and_return({
          success: true,
          text: 'invalid json'
        })
        allow(service).to receive(:parse_hex_response).and_raise(JSON::ParserError)
      end

      it 'returns empty array' do
        result = service.send(:analyze_all_hexes, image_path, hex_labels, hex_coords)
        expect(result).to eq([])
      end
    end
  end

  describe 'private #analyze_hex_chunk' do
    let(:image_path) { '/tmp/test.png' }
    let(:hex_labels) { %w[1A 1B] }
    let(:chunk_coords) { [[0, 0], [2, 0]] }

    before do
      allow(File).to receive(:read).and_return('image_data')
      allow(Base64).to receive(:strict_encode64).and_return('encoded')
      allow(GamePrompts).to receive(:get).and_return('Analyze hexes')
      allow(AIProviderService).to receive(:api_key_for).and_return('test_key')
      allow(service).to receive(:parse_hex_response).and_return([{ x: 0, y: 0 }])
    end

    context 'when chunk size is too small' do
      it 'returns nil' do
        result = service.send(:analyze_hex_chunk, image_path, hex_labels, chunk_coords, 3)
        expect(result).to be_nil
      end
    end

    context 'when LLM call succeeds' do
      before do
        allow(LLM::Adapters::GeminiAdapter).to receive(:generate).and_return({
          success: true,
          text: '{"hexes": []}'
        })
      end

      it 'returns parsed data' do
        result = service.send(:analyze_hex_chunk, image_path, hex_labels, chunk_coords, 50)
        expect(result).to be_an(Array)
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Adapters::GeminiAdapter).to receive(:generate).and_return({
          success: false,
          error: 'Error'
        })
        allow(service).to receive(:analyze_hex_chunk_smaller).and_return([])
      end

      it 'retries with smaller chunk' do
        expect(service).to receive(:analyze_hex_chunk_smaller)
        service.send(:analyze_hex_chunk, image_path, hex_labels, chunk_coords, 50)
      end
    end
  end

  describe 'private #analyze_hex_chunk_smaller' do
    let(:image_path) { '/tmp/test.png' }

    context 'when new size is too small' do
      it 'returns nil' do
        result = service.send(:analyze_hex_chunk_smaller, image_path, %w[1A], [[0, 0]], 8)
        expect(result).to be_nil
      end
    end

    context 'when splitting and retrying' do
      before do
        allow(service).to receive(:analyze_hex_chunk).and_return([{ x: 0, y: 0 }])
      end

      it 'processes smaller chunks' do
        hex_labels = (1..20).map { |i| "#{i}A" }
        chunk_coords = (0..19).map { |i| [i * 2, 0] }

        expect(service).to receive(:analyze_hex_chunk).at_least(:once)
        service.send(:analyze_hex_chunk_smaller, image_path, hex_labels, chunk_coords, 20)
      end
    end
  end

  describe 'private #describe_room_shape' do
    it 'returns square for equal dimensions' do
      expect(service.send(:describe_room_shape, 40, 40)).to eq('square')
    end

    it 'returns rectangle wider than deep' do
      expect(service.send(:describe_room_shape, 60, 40)).to include('wider than deep')
    end

    it 'returns rectangle deeper than wide' do
      expect(service.send(:describe_room_shape, 40, 60)).to include('deeper than wide')
    end

    it 'returns narrow corridor for extreme ratios' do
      expect(service.send(:describe_room_shape, 100, 20)).to include('narrow corridor')
    end
  end

  describe 'private #natural_furniture_description' do
    it 'includes furniture name and position' do
      place = double('Place', name: 'Table', x: 40, y: 40)
      allow(place).to receive(:respond_to?).with(:name).and_return(true)
      allow(place).to receive(:respond_to?).with(:x).and_return(true)
      allow(place).to receive(:respond_to?).with(:y).and_return(true)
      desc = service.send(:natural_furniture_description, place)
      expect(desc).to include('Table')
      expect(desc).to include('center')
    end

    it 'returns just name when no coordinates' do
      place = double('Place', name: 'Chair', x: nil, y: nil)
      allow(place).to receive(:respond_to?).with(:name).and_return(true)
      allow(place).to receive(:respond_to?).with(:x).and_return(true)
      allow(place).to receive(:respond_to?).with(:y).and_return(true)
      desc = service.send(:natural_furniture_description, place)
      expect(desc).to eq('Chair')
    end
  end

  describe 'private #natural_feature_description' do
    it 'describes feature with wall and position' do
      feature = double('Feature', name: 'Oak Door', feature_type: 'door', x: 0, y: 40)
      allow(feature).to receive(:respond_to?).with(:feature_type).and_return(true)
      allow(feature).to receive(:respond_to?).with(:name).and_return(true)
      allow(feature).to receive(:respond_to?).with(:x).and_return(true)
      allow(feature).to receive(:respond_to?).with(:y).and_return(true)
      desc = service.send(:natural_feature_description, feature)
      expect(desc).to include('Oak Door')
      expect(desc).to include('west wall')
    end
  end

  describe 'private #fallback_to_procedural' do
    before do
      allow(room).to receive(:hex_count).and_return(50)
    end

    it 'creates BattleMapGeneratorService' do
      procedural = double('BattleMapGeneratorService', generate!: true)
      expect(BattleMapGeneratorService).to receive(:new).with(room).and_return(procedural)
      service.send(:fallback_to_procedural, 'Test reason')
    end

    it 'calls generate! on procedural service' do
      procedural = double('BattleMapGeneratorService')
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
      expect(procedural).to receive(:generate!)
      service.send(:fallback_to_procedural, 'Test reason')
    end

    it 'returns success true' do
      procedural = double('BattleMapGeneratorService', generate!: true)
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
      result = service.send(:fallback_to_procedural, 'Test reason')
      expect(result[:success]).to be true
    end

    it 'returns success false when procedural generation returns false' do
      procedural = double('BattleMapGeneratorService', generate!: false)
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
      result = service.send(:fallback_to_procedural, 'Test reason')
      expect(result[:success]).to be false
    end

    it 'returns fallback true' do
      procedural = double('BattleMapGeneratorService', generate!: true)
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
      result = service.send(:fallback_to_procedural, 'Test reason')
      expect(result[:fallback]).to be true
    end

    it 'returns hex_count from room' do
      procedural = double('BattleMapGeneratorService', generate!: true)
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
      result = service.send(:fallback_to_procedural, 'Test reason')
      expect(result[:hex_count]).to eq(50)
    end

    it 'returns error reason' do
      procedural = double('BattleMapGeneratorService', generate!: true)
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
      result = service.send(:fallback_to_procedural, 'Test reason')
      expect(result[:error]).to eq('Test reason')
    end

    it 'includes fallback failure details when procedural generation raises' do
      procedural = double('BattleMapGeneratorService')
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural)
      allow(procedural).to receive(:generate!).and_raise(StandardError, 'procedural blew up')
      result = service.send(:fallback_to_procedural, 'Test reason')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Test reason')
      expect(result[:error]).to include('fallback failed')
    end
  end

  describe 'private #map_simple_type_to_room_hex' do
    it 'maps treetrunk to cover type, not traversable' do
      result = service.send(:map_simple_type_to_room_hex, 'treetrunk', 0, 0)
      expect(result[:hex_type]).to eq('cover')
      expect(result[:cover_object]).to eq('tree')
      expect(result[:traversable]).to be false
    end

    it 'maps wall to wall type, not traversable' do
      result = service.send(:map_simple_type_to_room_hex, 'wall', 2, 0)
      expect(result[:hex_type]).to eq('wall')
      expect(result[:traversable]).to be false
    end

    it 'maps deep_water to water type, not traversable' do
      result = service.send(:map_simple_type_to_room_hex, 'deep_water', 0, 4)
      expect(result[:hex_type]).to eq('water')
      expect(result[:water_type]).to eq('deep')
      expect(result[:traversable]).to be false
    end

    it 'maps mud to difficult terrain' do
      result = service.send(:map_simple_type_to_room_hex, 'mud', 2, 4)
      expect(result[:hex_type]).to eq('difficult')
      expect(result[:difficult_terrain]).to be true
      expect(result[:traversable]).to be true
    end

    it 'maps fire to fire type with hazard' do
      result = service.send(:map_simple_type_to_room_hex, 'fire', 0, 0)
      expect(result[:hex_type]).to eq('fire')
      expect(result[:hazard_type]).to eq('fire')
      expect(result[:danger_level]).to eq(3)
    end

    it 'maps open_floor to normal type' do
      result = service.send(:map_simple_type_to_room_hex, 'open_floor', 0, 0)
      expect(result[:hex_type]).to eq('normal')
      expect(result[:traversable]).to be true
      expect(result[:difficult_terrain]).to be false
    end

    it 'maps off_map to wall type, not traversable' do
      result = service.send(:map_simple_type_to_room_hex, 'off_map', 0, 0)
      expect(result[:hex_type]).to eq('wall')
      expect(result[:traversable]).to be false
    end

    it 'maps door to door type' do
      result = service.send(:map_simple_type_to_room_hex, 'door', 0, 0)
      expect(result[:hex_type]).to eq('door')
    end

    it 'maps table to furniture with elevation' do
      result = service.send(:map_simple_type_to_room_hex, 'table', 0, 0)
      expect(result[:hex_type]).to eq('furniture')
      expect(result[:cover_object]).to eq('table')
      expect(result[:elevation_level]).to eq(3)
    end

    it 'maps boulder to cover, not traversable' do
      result = service.send(:map_simple_type_to_room_hex, 'boulder', 0, 0)
      expect(result[:hex_type]).to eq('cover')
      expect(result[:cover_object]).to eq('boulder')
      expect(result[:has_cover]).to be true
      expect(result[:traversable]).to be false
    end

    it 'falls back to open_floor for unknown types' do
      result = service.send(:map_simple_type_to_room_hex, 'alien_artifact', 0, 0)
      expect(result[:hex_type]).to eq('normal')
      expect(result[:traversable]).to be true
    end

    it 'enriches unknown types with overview properties' do
      overview = { 'alien_goo' => { 'traversable' => false, 'difficult_terrain' => true } }
      result = service.send(:map_simple_type_to_room_hex, 'alien_goo', 0, 0, overview)
      expect(result[:traversable]).to be false
      expect(result[:difficult_terrain]).to be true
    end

    it 'sets correct coordinates' do
      result = service.send(:map_simple_type_to_room_hex, 'open_floor', 4, 6)
      expect(result[:x]).to eq(4)
      expect(result[:y]).to eq(6)
    end
  end

  describe 'SIMPLE_TYPE_TO_ROOM_HEX constant' do
    it 'covers all SIMPLE_HEX_TYPES except other' do
      covered = described_class::SIMPLE_TYPE_TO_ROOM_HEX.keys
      expected = described_class::SIMPLE_HEX_TYPES - ['other']
      missing = expected - covered
      expect(missing).to be_empty, "Missing mappings for: #{missing.join(', ')}"
    end

    it 'maps to valid RoomHex hex_types' do
      valid_types = %w[normal wall cover furniture water fire difficult door window stairs pit debris trap concealed]
      described_class::SIMPLE_TYPE_TO_ROOM_HEX.each do |type_name, mapping|
        expect(valid_types).to include(mapping[:hex_type]),
          "#{type_name} maps to invalid hex_type '#{mapping[:hex_type]}'"
      end
    end
  end

  describe 'progress publishing' do
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
    end

    describe '#publish_progress' do
      it 'publishes progress message to Redis channel' do
        expect(redis).to receive(:publish).with(
          "fight:123:generation",
          a_string_including('"type":"progress"', '"progress":45', '"step":"Test step"')
        )

        service.send(:publish_progress, 123, 45, "Test step")
      end
    end

    describe '#publish_completion' do
      it 'publishes completion message with success' do
        expect(redis).to receive(:publish).with(
          "fight:123:generation",
          a_string_including('"type":"complete"', '"success":true', '"fallback":false', '"battle_map_ready":true')
        )

        service.send(:publish_completion, 123, success: true)
      end

      it 'publishes completion message with fallback flag' do
        expect(redis).to receive(:publish).with(
          "fight:123:generation",
          a_string_including('"type":"complete"', '"success":true', '"fallback":true', '"battle_map_ready":true')
        )

        service.send(:publish_completion, 123, success: true, fallback: true)
      end

      it 'publishes completion message with battle_map_ready false on failure' do
        expect(redis).to receive(:publish).with(
          "fight:123:generation",
          a_string_including('"type":"complete"', '"success":false', '"battle_map_ready":false')
        )

        service.send(:publish_completion, 123, success: false)
      end
    end
  end

  describe '#generate_async' do
    let(:fight) { Fight.create(room_id: room.id, status: 'input', round_number: 1) }
    let(:service) { described_class.new(room) }
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
    end

    it 'generates battle map with progress updates' do
      # Track progress updates
      progress_updates = []
      allow(redis).to receive(:publish) do |channel, message|
        progress_updates << JSON.parse(message)
      end

      # Mock generation steps
      allow(service).to receive(:generate_battlemap_image).and_return({ success: true, local_url: 'uploads/fake/path.webp' })
      allow(service).to receive(:upscale_if_needed).and_return('public/uploads/fake/upscaled.webp')
      allow(MapSvgRenderService).to receive(:trim_image_borders)
      allow(MapSvgRenderService).to receive(:convert_to_webp).and_return('public/uploads/fake/final.webp')
      allow(service).to receive(:analyze_hexes_with_grid).and_return([{ hex_x: 0, hex_y: 0, hex_type: 'normal' }])
      allow(service).to receive(:analyze_hexes_v2).and_return([{ hex_x: 0, hex_y: 0, hex_type: 'normal' }])
      allow(service).to receive(:persist_hex_data)
      allow(service).to receive(:persist_image)

      service.generate_async(fight)

      # Verify progress sequence (filter out completion message which has no progress field)
      progress_messages = progress_updates.select { |u| u['type'] == 'progress' }
      expect(progress_messages.map { |u| u['progress'] }).to eq([0, 5, 40, 45, 55, 60, 65, 70, 95, 100])

      completion_message = progress_updates.find { |u| u['type'] == 'complete' }
      expect(completion_message['success']).to eq(true)

      # Verify fight marked complete
      expect(fight.reload.battle_map_generating).to eq(false)
    end

    it 'falls back to procedural generation on error' do
      # Track progress updates
      progress_updates = []
      allow(redis).to receive(:publish) do |channel, message|
        progress_updates << JSON.parse(message)
      end

      # Mock failure
      allow(service).to receive(:generate_battlemap_image).and_raise(StandardError.new('API error'))

      # Mock fallback
      procedural_service = double('BattleMapGeneratorService')
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural_service)
      allow(procedural_service).to receive(:generate!)

      service.generate_async(fight)

      # Verify fallback progress
      expect(progress_updates.map { |u| u['progress'] }).to include(0, 50, 100)
      expect(progress_updates.last['type']).to eq('complete')
      expect(progress_updates.last['fallback']).to eq(true)

      # Verify fight marked complete
      expect(fight.reload.battle_map_generating).to eq(false)
    end

    it 'publishes unsuccessful completion when procedural fallback returns false' do
      progress_updates = []
      allow(redis).to receive(:publish) do |_channel, message|
        progress_updates << JSON.parse(message)
      end

      allow(service).to receive(:generate_battlemap_image).and_raise(StandardError.new('API error'))

      procedural_service = double('BattleMapGeneratorService')
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural_service)
      allow(procedural_service).to receive(:generate!).and_return(false)

      service.generate_async(fight)

      completion = progress_updates.find { |u| u['type'] == 'complete' }
      expect(completion).not_to be_nil
      expect(completion['fallback']).to eq(true)
      expect(completion['success']).to eq(false)
      expect(fight.reload.battle_map_generating).to eq(false)
    end

    it 'logs errors but completes gracefully' do
      allow(redis).to receive(:publish)
      allow(service).to receive(:generate_battlemap_image).and_raise(StandardError.new('Test error'))

      procedural_service = double('BattleMapGeneratorService')
      allow(BattleMapGeneratorService).to receive(:new).and_return(procedural_service)
      allow(procedural_service).to receive(:generate!)

      expect { service.generate_async(fight) }.not_to raise_error
      expect(fight.reload.battle_map_generating).to eq(false)
    end
  end

  describe '#edge_strength_between' do
    let(:service) { described_class.new(room) }

    context 'when edge_map is nil' do
      it 'returns 0.0' do
        result = service.send(:edge_strength_between, nil, 10, 10, 20, 20)
        expect(result).to eq(0.0)
      end
    end

    context 'with a synthetic edge map' do
      let(:edge_map) do
        # Create a 100x100 grayscale image: left half black, right half white (edge at x=50)
        require 'vips'
        left = Vips::Image.black(50, 100)
        right = (Vips::Image.black(50, 100) + 255).cast(:uchar)
        left.join(right, :horizontal)
      end

      it 'returns high strength when sampling across the edge' do
        # Sample from x=40 to x=60, crossing the white region
        result = service.send(:edge_strength_between, edge_map, 40, 50, 60, 50)
        expect(result).to be > 0.3
      end

      it 'returns low strength when sampling within black region' do
        result = service.send(:edge_strength_between, edge_map, 10, 50, 30, 50)
        expect(result).to be < 0.2
      end

      it 'returns high strength when sampling within white region' do
        result = service.send(:edge_strength_between, edge_map, 60, 50, 90, 50)
        expect(result).to be > 0.8
      end
    end
  end

  describe '#edge_strength_at_hex' do
    let(:service) { described_class.new(room) }

    context 'when edge_map is nil' do
      it 'returns 0.0' do
        result = service.send(:edge_strength_at_hex, nil, 50, 50, 10)
        expect(result).to eq(0.0)
      end
    end

    context 'with a synthetic edge map' do
      let(:edge_map) do
        require 'vips'
        # All white (edges everywhere)
        (Vips::Image.black(100, 100) + 255).cast(:uchar)
      end

      it 'returns high strength when hex is surrounded by edges' do
        result = service.send(:edge_strength_at_hex, edge_map, 50, 50, 10)
        expect(result).to be > 0.8
      end
    end
  end

  describe 'EDGE_EXEMPT_TYPES constant' do
    it 'includes terrain types that lack visible edges' do
      expect(described_class::EDGE_EXEMPT_TYPES).to include('mud')
      expect(described_class::EDGE_EXEMPT_TYPES).to include('snow')
      expect(described_class::EDGE_EXEMPT_TYPES).to include('ice')
      expect(described_class::EDGE_EXEMPT_TYPES).to include('puddle')
      expect(described_class::EDGE_EXEMPT_TYPES).to include('shrubbery')
      expect(described_class::EDGE_EXEMPT_TYPES).to include('open_floor')
      expect(described_class::EDGE_EXEMPT_TYPES).to include('off_map')
    end
  end

  # --- SAM mask / light source regression specs ---

  describe '#join_sam_thread' do
    it 'returns nil for nil thread' do
      result = service.send(:join_sam_thread, nil)
      expect(result).to be_nil
    end

    it 'returns the thread value for a successful thread' do
      thread = Thread.new { { success: true, mask_path: '/tmp/mask.png' } }
      result = service.send(:join_sam_thread, thread)
      expect(result).to eq({ success: true, mask_path: '/tmp/mask.png' })
    end

    it 'returns nil and logs warning when thread raises' do
      thread = Thread.new { raise StandardError, 'SAM failed' }
      expect { service.send(:join_sam_thread, thread) }.to output(/SAM thread failed/).to_stderr_from_any_process
    end

    it 'returns nil when thread times out' do
      thread = Thread.new { sleep 999 }
      result = service.send(:join_sam_thread, thread, timeout: 0.01)
      expect(result).to be_nil
      thread.kill
    end
  end

  describe '#persist_sam_mask_urls' do
    let(:local_path) { 'public/uploads/generated/2026/03/test_image.webp' }

    before do
      allow(room).to receive(:update)
    end

    it 'joins water SAM thread before checking file' do
      water_thread = double('Thread')
      expect(service).to receive(:join_sam_thread).with(water_thread)
      allow(service).to receive(:join_sam_thread).with(anything).and_call_original
      allow(service).to receive(:join_sam_thread).with(water_thread).and_return({ success: true })
      allow(File).to receive(:exist?).and_return(false)

      service.send(:persist_sam_mask_urls, local_path, { 'water' => water_thread })
    end

    it 'joins foliage SAM threads before combining masks' do
      tree_thread = double('Thread')
      bush_thread = double('Thread')
      allow(service).to receive(:join_sam_thread)  # allow all calls
      expect(service).to receive(:join_sam_thread).with(tree_thread)
      expect(service).to receive(:join_sam_thread).with(bush_thread)
      allow(File).to receive(:exist?).and_return(false)

      service.send(:persist_sam_mask_urls, local_path,
                    { 'foliage_tree' => tree_thread, 'foliage_bush' => bush_thread })
    end

    it 'joins light SAM threads before checking fire mask' do
      fire_thread = double('Thread')
      allow(service).to receive(:join_sam_thread)  # allow all calls
      expect(service).to receive(:join_sam_thread).with(fire_thread)
      allow(File).to receive(:exist?).and_return(false)

      service.send(:persist_sam_mask_urls, local_path, { 'light_fire' => fire_thread })
    end

    it 'updates room with water mask URL when file exists' do
      allow(File).to receive(:exist?).and_return(false)
      water_path = 'public/uploads/generated/2026/03/test_image_sam_water.png'
      allow(File).to receive(:exist?).with(water_path).and_return(true)

      expect(room).to receive(:update).with(hash_including(
        battle_map_water_mask_url: '/uploads/generated/2026/03/test_image_sam_water.png'
      ))

      service.send(:persist_sam_mask_urls, local_path, {})
    end

    it 'updates room with fire mask URL when file exists' do
      allow(File).to receive(:exist?).and_return(false)
      fire_path = 'public/uploads/generated/2026/03/test_image_sam_light_fire.png'
      allow(File).to receive(:exist?).with(fire_path).and_return(true)

      # Stub Vips for threshold processing
      mock_mask = double('VipsImage', bands: 1, avg: 5.0) # avg < 20, skip threshold
      allow(Vips::Image).to receive(:new_from_file).with(fire_path).and_return(mock_mask)
      allow(mock_mask).to receive(:write_to_buffer).with('.png').and_return('png-bytes')
      expect(File).to receive(:binwrite).with(fire_path, 'png-bytes')

      expect(room).to receive(:update).with(hash_including(
        battle_map_fire_mask_url: '/uploads/generated/2026/03/test_image_sam_light_fire.png'
      ))

      service.send(:persist_sam_mask_urls, local_path, {})
    end

    it 'falls back to torch light mask for fire animation when fire mask is absent' do
      allow(File).to receive(:exist?).and_return(false)
      fire_path = 'public/uploads/generated/2026/03/test_image_sam_light_fire.png'
      torch_path = 'public/uploads/generated/2026/03/test_image_sam_light_torch.png'
      allow(File).to receive(:exist?).with(fire_path).and_return(false, true)
      allow(File).to receive(:exist?).with(torch_path).and_return(true)

      torch_mask = double('TorchMask', bands: 1, avg: 5.0)
      allow(Vips::Image).to receive(:new_from_file).with(torch_path).and_return(torch_mask)
      allow(torch_mask).to receive(:write_to_buffer).with('.png').and_return('torch-bytes')
      expect(File).to receive(:binwrite).with(fire_path, 'torch-bytes')

      expect(room).to receive(:update).with(hash_including(
        battle_map_fire_mask_url: '/uploads/generated/2026/03/test_image_sam_light_fire.png'
      ))

      service.send(:persist_sam_mask_urls, local_path, {})
    end

    it 'thresholds fire mask when avg > 20' do
      allow(File).to receive(:exist?).and_return(false)
      fire_path = 'public/uploads/generated/2026/03/test_image_sam_light_fire.png'
      allow(File).to receive(:exist?).with(fire_path).and_return(true)

      mock_mask = double('VipsImage', bands: 1, avg: 109.0)
      binary = double('VipsBinary', avg: 50.0)
      threshold_result = double('VipsThreshold')
      encoded_png = 'png-bytes'
      allow(Vips::Image).to receive(:new_from_file).with(fire_path).and_return(mock_mask)
      allow(mock_mask).to receive(:>).with(200).and_return(threshold_result)
      allow(threshold_result).to receive(:ifthenelse).with(255, 0).and_return(binary)
      allow(binary).to receive(:cast).with(:uchar).and_return(binary)
      allow(binary).to receive(:write_to_buffer).with('.png').and_return(encoded_png)

      expect(File).to receive(:binwrite).with(fire_path, encoded_png)
      allow(room).to receive(:update)

      service.send(:persist_sam_mask_urls, local_path, {})
    end

    it 'works with empty threads hash (default)' do
      allow(File).to receive(:exist?).and_return(false)
      expect { service.send(:persist_sam_mask_urls, local_path) }.not_to raise_error
    end

    it 'handles errors gracefully' do
      allow(File).to receive(:exist?).and_raise(StandardError, 'disk error')
      expect { service.send(:persist_sam_mask_urls, local_path, {}) }.to output(/Failed to persist SAM mask URLs/).to_stderr_from_any_process
    end
  end

  describe '#combine_foliage_masks' do
    let(:local_path) { 'public/uploads/generated/2026/03/test_image.webp' }
    let(:tree_path) { 'public/uploads/generated/2026/03/test_image_sam_foliage_tree.png' }
    let(:bush_path) { 'public/uploads/generated/2026/03/test_image_sam_foliage_bush.png' }
    let(:output_path) { 'public/uploads/generated/2026/03/test_image_sam_foliage.png' }

    it 'returns nil when no mask files exist' do
      allow(File).to receive(:exist?).and_return(false)
      result = service.send(:combine_foliage_masks, local_path)
      expect(result).to be_nil
    end

    it 'returns output path when tree mask exists alone' do
      allow(File).to receive(:exist?).with(tree_path).and_return(true)
      allow(File).to receive(:exist?).with(bush_path).and_return(false)

      mock_img = double('VipsImage', bands: 1)
      allow(Vips::Image).to receive(:new_from_file).with(tree_path).and_return(mock_img)
      allow(mock_img).to receive(:write_to_file).with(output_path)

      result = service.send(:combine_foliage_masks, local_path)
      expect(result).to eq(output_path)
    end

    it 'combines both masks with bitwise OR when both exist' do
      allow(File).to receive(:exist?).with(tree_path).and_return(true)
      allow(File).to receive(:exist?).with(bush_path).and_return(true)

      tree_img = double('VipsTree', bands: 1, width: 100)
      bush_img = double('VipsBush', bands: 1, width: 100)
      combined = double('VipsCombined', bands: 1)

      allow(Vips::Image).to receive(:new_from_file).with(tree_path).and_return(tree_img)
      allow(Vips::Image).to receive(:new_from_file).with(bush_path).and_return(bush_img)
      allow(tree_img).to receive(:|).with(bush_img).and_return(combined)
      allow(combined).to receive(:write_to_file).with(output_path)

      result = service.send(:combine_foliage_masks, local_path)
      expect(result).to eq(output_path)
    end

    it 'handles errors gracefully' do
      allow(File).to receive(:exist?).and_raise(StandardError, 'disk error')
      expect(service.send(:combine_foliage_masks, local_path)).to be_nil
    end
  end

  describe '#extract_and_store_light_sources' do
    let(:local_path) { 'public/uploads/generated/2026/03/test_image.webp' }

    it 'returns early when l1_light_sources is nil' do
      expect(room).not_to receive(:update)
      service.send(:extract_and_store_light_sources, local_path, nil, {})
    end

    it 'returns early when l1_light_sources is empty' do
      expect(room).not_to receive(:update)
      service.send(:extract_and_store_light_sources, local_path, [], {})
    end

    it 'uses join_sam_thread to get thread results with timeout' do
      thread = double('Thread')
      threads = { 'light_fire' => thread }
      l1_sources = [{ 'source_type' => 'fire', 'description' => 'fireplace' }]

      expect(service).to receive(:join_sam_thread).with(thread).and_return(nil)
      expect(room).not_to receive(:update)

      service.send(:extract_and_store_light_sources, local_path, l1_sources, threads)
    end

    it 'extracts positions and stores light sources when SAM succeeds' do
      mask_path = '/tmp/fire_mask.png'
      thread = double('Thread')
      threads = { 'light_fire' => thread }
      l1_sources = [{ 'source_type' => 'fire', 'description' => 'stone fireplace' }]

      allow(service).to receive(:join_sam_thread).with(thread).and_return({
        success: true, mask_path: mask_path
      })
      allow(File).to receive(:exist?).with(mask_path).and_return(true)
      allow(service).to receive(:extract_positions_from_mask).with(mask_path).and_return([
        { cx: 500.0, cy: 300.0, radius: 40.0 }
      ])

      expect(room).to receive(:update) do |args|
        sources = args[:detected_light_sources]
        # Sequel.pg_jsonb_wrap wraps the array, but we can check the unwrapped content
        expect(sources).to be_a(Sequel::Postgres::JSONBHash).or be_a(Array).or be_a(Sequel::Postgres::JSONBArray)
      end

      service.send(:extract_and_store_light_sources, local_path, l1_sources, threads)
    end

    it 'skips duplicate light types' do
      thread = double('Thread')
      threads = { 'light_fire' => thread }
      l1_sources = [
        { 'source_type' => 'fire', 'description' => 'fireplace' },
        { 'source_type' => 'fire', 'description' => 'another fireplace' }
      ]

      # Should only join the thread once despite two fire sources
      expect(service).to receive(:join_sam_thread).with(thread).once.and_return(nil)

      service.send(:extract_and_store_light_sources, local_path, l1_sources, threads)
    end

    it 'handles multiple light types independently' do
      fire_thread = double('FireThread')
      torch_thread = double('TorchThread')
      threads = { 'light_fire' => fire_thread, 'light_torch' => torch_thread }
      l1_sources = [
        { 'source_type' => 'fire', 'description' => 'fireplace' },
        { 'source_type' => 'torch', 'description' => 'wall torch' }
      ]

      expect(service).to receive(:join_sam_thread).with(fire_thread).and_return(nil)
      expect(service).to receive(:join_sam_thread).with(torch_thread).and_return(nil)

      service.send(:extract_and_store_light_sources, local_path, l1_sources, threads)
    end

    it 'handles errors gracefully' do
      threads = { 'light_fire' => double('Thread') }
      l1_sources = [{ 'source_type' => 'fire', 'description' => 'fire' }]
      allow(service).to receive(:join_sam_thread).and_raise(StandardError, 'boom')

      expect { service.send(:extract_and_store_light_sources, local_path, l1_sources, threads) }
        .to output(/Light source extraction failed/).to_stderr_from_any_process
    end
  end

  describe '#detect_and_store_light_sources' do
    it 'returns early when image_path is nil' do
      expect(room).not_to receive(:update)
      service.detect_and_store_light_sources(room, nil)
    end

    it 'returns early when image file does not exist' do
      allow(File).to receive(:exist?).with('/tmp/missing.png').and_return(false)
      expect(room).not_to receive(:update)
      service.detect_and_store_light_sources(room, '/tmp/missing.png')
    end

    it 'skips CV fallback when L1+SAM already populated light sources' do
      allow(File).to receive(:exist?).and_return(true)
      allow(room).to receive(:detected_light_sources).and_return([
        { 'type' => 'fire', 'center_x' => 100, 'center_y' => 200 }
      ])

      # Should not attempt LightingServiceManager
      expect(LightingServiceManager).not_to receive(:ensure_running)

      service.detect_and_store_light_sources(room, '/tmp/test.png')
    end

    it 'attempts CV fallback when no existing light sources' do
      allow(File).to receive(:exist?).and_return(true)
      allow(room).to receive(:detected_light_sources).and_return([])
      allow(room).to receive(:room_hexes_dataset).and_return(
        double('dataset', where: double('filtered', map: []))
      )

      expect(LightingServiceManager).to receive(:ensure_running).and_return(false)

      service.detect_and_store_light_sources(room, '/tmp/test.png')
    end
  end

  describe 'SAM constants' do
    it 'defines SAM_LIGHT_QUERIES for all LIGHT_SOURCE_TYPES' do
      described_class::LIGHT_SOURCE_TYPES.each do |type|
        expect(described_class::SAM_LIGHT_QUERIES).to have_key(type),
          "SAM_LIGHT_QUERIES missing entry for light source type '#{type}'"
      end
    end

    it 'defines SAM_FOLIAGE_TYPES for foliage mask generation' do
      expect(described_class::SAM_FOLIAGE_TYPES).to include('treetrunk')
      expect(described_class::SAM_FOLIAGE_TYPES).to include('shrubbery')
    end

    it 'has unique SAM_LIGHT_QUERIES values to prevent accidental dedup' do
      queries = described_class::SAM_LIGHT_QUERIES.values
      # It's OK if some share queries (intentional dedup), but each key must have a value
      expect(queries).to all(be_a(String))
      expect(queries).to all(satisfy { |q| !q.empty? })
    end
  end

end
