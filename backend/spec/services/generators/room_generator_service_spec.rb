# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::RoomGeneratorService do
  let(:location) { double('Location', id: 1, name: 'Test Location') }
  let(:place_sofa) { double('Place', name: 'leather sofa', is_furniture: true) }
  let(:place_bar)  { double('Place', name: 'bar counter', is_furniture: true) }
  let(:decoration_tapestry) { double('Decoration', name: 'tapestry') }
  let(:room) do
    double('Room',
           id: 1,
           name: 'Common Room',
           room_type: 'bar',
           location: location,
           description: 'A busy tavern common room',
           short_description: 'Busy tavern',
           visible_places: [place_sofa, place_bar],
           visible_decorations: [decoration_tapestry])
  end
  let(:seed_terms) { %w[cozy warm inviting] }

  before do
    allow(SeedTermService).to receive(:for_generation).and_return(seed_terms)
    allow(GamePrompts).to receive(:get).and_return('Generated prompt')
  end

  describe '.generate' do
    before do
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true,
        data: {
          'name' => 'The Cozy Hearth',
          'description' => 'A warm and inviting room with wooden furnishings.'
        }
      })
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'A warm and inviting room with wooden furnishings.'
      })
    end

    it 'generates name and description in a single call' do
      result = described_class.generate(
        parent: location,
        room_type: 'bar',
        setting: :fantasy
      )

      expect(result[:success]).to be true
      expect(result[:name]).to eq('The Cozy Hearth')
      expect(result[:description]).to include('warm')
    end

    it 'includes seed terms in results' do
      result = described_class.generate(parent: location, room_type: 'shop')

      expect(result[:seed_terms]).to eq(seed_terms)
    end

    it 'uses provided name and only generates description' do
      expect(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'Custom name description.'
      })
      expect(GenerationPipelineService).not_to receive(:generate_structured)

      result = described_class.generate(
        parent: location,
        room_type: 'bar',
        name: 'My Custom Name'
      )

      expect(result[:name]).to eq('My Custom Name')
      expect(result[:description]).to eq('Custom name description.')
    end

    context 'when generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: false,
          error: 'Service unavailable'
        })
      end

      it 'uses fallback name' do
        result = described_class.generate(
          parent: location,
          room_type: 'bar'
        )

        expect(result[:name]).to include('Bar')
        expect(result[:errors]).to include('Service unavailable')
      end
    end

    context 'with generate_background: true' do
      before do
        allow(WorldBuilderImageService).to receive(:generate).and_return({
          success: true,
          local_url: '/images/room_bg.png'
        })
      end

      it 'generates background image' do
        result = described_class.generate(
          parent: location,
          room_type: 'bar',
          generate_background: true
        )

        expect(result[:background_url]).to eq('/images/room_bg.png')
      end
    end
  end

  describe '.generate_named_room' do
    before do
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true,
        data: {
          'name' => 'The Dusty Cellar',
          'description' => 'Stone walls lined with aging wine barrels.'
        }
      })
    end

    it 'returns name and description from a single call' do
      result = described_class.generate_named_room(
        room_type: 'basement',
        parent: location,
        setting: :fantasy,
        seed_terms: seed_terms
      )

      expect(result[:success]).to be true
      expect(result[:name]).to eq('The Dusty Cellar')
      expect(result[:description]).to include('wine barrels')
    end

    it 'strips quotes from name' do
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true,
        data: { 'name' => '"Quoted Name"', 'description' => 'Desc.' }
      })

      result = described_class.generate_named_room(room_type: 'shop', parent: location)

      expect(result[:name]).to eq('Quoted Name')
    end

    it 'uses the name_and_description prompt' do
      expect(GamePrompts).to receive(:get).with('room_generation.name_and_description', anything)

      described_class.generate_named_room(room_type: 'bar', parent: location)
    end

    context 'when generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: false, error: 'LLM error'
        })
      end

      it 'returns error' do
        result = described_class.generate_named_room(room_type: 'bar', parent: location)

        expect(result[:success]).to be false
        expect(result[:error]).to include('LLM error')
      end
    end
  end

  describe '.generate_name' do
    before do
      allow(GenerationPipelineService).to receive(:generate_simple).and_return({
        success: true,
        content: '"The Rusty Anchor"'
      })
    end

    it 'generates room name' do
      result = described_class.generate_name(
        room_type: 'bar',
        parent_name: 'Test City',
        setting: :fantasy,
        seed_terms: seed_terms
      )

      expect(result[:success]).to be true
      expect(result[:name]).to eq('The Rusty Anchor')
    end

    it 'strips quotes from name' do
      result = described_class.generate_name(room_type: 'shop')

      expect(result[:name]).not_to include('"')
    end

    context 'when generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_simple).and_return({
          success: false,
          error: 'LLM error'
        })
      end

      it 'returns error' do
        result = described_class.generate_name(room_type: 'bar')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('LLM error')
      end
    end
  end

  describe '.generate_description' do
    before do
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'A cozy room with wooden beams.'
      })
    end

    it 'generates description for existing room' do
      result = described_class.generate_description(room: room, setting: :fantasy)

      expect(result[:success]).to be true
      expect(result[:content]).to include('cozy')
    end

    it 'uses provided seed terms' do
      custom_terms = %w[elegant refined]
      result = described_class.generate_description(
        room: room,
        seed_terms: custom_terms
      )

      expect(result[:success]).to be true
    end
  end

  describe '.generate_seasonal_descriptions' do
    before do
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'Seasonal variant description'
      })
    end

    it 'generates descriptions for all time/season combinations' do
      result = described_class.generate_seasonal_descriptions(
        room: room,
        setting: :fantasy
      )

      expect(result[:success]).to be true
      expect(result[:descriptions].keys).to include('dawn_spring', 'day_summer', 'dusk_fall', 'night_winter')
    end

    it 'generates 16 variants by default' do
      result = described_class.generate_seasonal_descriptions(room: room)

      expect(result[:descriptions].length).to eq(16)
    end

    it 'respects custom times filter' do
      result = described_class.generate_seasonal_descriptions(
        room: room,
        times: %i[day night]
      )

      expect(result[:descriptions].keys).to all(match(/day|night/))
    end

    it 'respects custom seasons filter' do
      result = described_class.generate_seasonal_descriptions(
        room: room,
        seasons: %i[summer winter]
      )

      expect(result[:descriptions].keys).to all(match(/summer|winter/))
    end

    context 'when room has no base description' do
      let(:room_no_desc) do
        double('Room',
               id: 2,
               name: 'Empty Room',
               room_type: 'storage',
               location: location,
               description: nil,
               short_description: nil)
      end

      it 'generates base description first' do
        expect(described_class).to receive(:generate_description).with(
          hash_including(room: room_no_desc)
        ).and_return({ success: false, content: nil, error: 'Failed' })

        result = described_class.generate_seasonal_descriptions(room: room_no_desc)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No base description')
      end
    end

    context 'when variant generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
          success: false,
          error: 'LLM error'
        })
      end

      it 'collects errors' do
        result = described_class.generate_seasonal_descriptions(
          room: room,
          times: %i[day],
          seasons: %i[summer]
        )

        expect(result[:errors]).to include('day_summer: LLM error')
      end
    end
  end

  describe '.generate_seasonal_variant' do
    before do
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'Morning light streams through...'
      })
    end

    it 'generates variant for specific time/season' do
      result = described_class.generate_seasonal_variant(
        base_description: 'A cozy room',
        room_type: 'bar',
        time_of_day: :dawn,
        season: :spring,
        setting: :fantasy
      )

      expect(result[:success]).to be true
      expect(result[:content]).to include('light')
    end

    it 'uses GamePrompts with correct parameters' do
      expect(GamePrompts).to receive(:get).with(
        'room_generation.seasonal_variant',
        hash_including(
          time_of_day: :dusk,
          season: :fall
        )
      )

      described_class.generate_seasonal_variant(
        base_description: 'Test',
        room_type: 'shop',
        time_of_day: :dusk,
        season: :fall
      )
    end
  end

  describe '.generate_background' do
    let(:gen_result) do
      { success: true, url: 'https://r2.example.com/bg.png',
        local_url: '/images/bg.png', local_path: '/app/public/images/bg.png' }
    end

    before do
      allow(WorldBuilderImageService).to receive(:generate).and_return(gen_result)
      allow(ReplicateUpscalerService).to receive(:available?).and_return(false)
      allow(MaskGenerationJob).to receive(:perform_async)
      # Allow real GamePrompts calls for prompt building
      allow(GamePrompts).to receive(:get).and_call_original
      allow(GamePrompts).to receive(:photo_profile).and_call_original
      allow(GamePrompts).to receive(:room_framing).and_call_original
    end

    it 'requires room: kwarg' do
      expect {
        described_class.generate_background(description: 'old call', room_type: 'bar')
      }.to raise_error(ArgumentError)
    end

    it 'includes film still framing in prompt' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('Film still from a')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'includes camera body from era profile' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('Hasselblad 500C/CM')
        gen_result
      end
      described_class.generate_background(room: room, options: { setting: :fantasy })
    end

    it 'includes film stock from era profile' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('Kodak Portra 400')
        gen_result
      end
      described_class.generate_background(room: room, options: { setting: :fantasy })
    end

    it 'omits shot on line for modern era (digital)' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).not_to include('shot on')
        gen_result
      end
      described_class.generate_background(room: room, options: { setting: :modern })
    end

    it 'includes room description in prompt' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('A busy tavern common room')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'includes furniture names in prompt' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('leather sofa')
        expect(args[:description]).to include('bar counter')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'includes decoration names in prompt' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('tapestry')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'omits Furniture line when room has no furniture' do
      allow(room).to receive(:visible_places).and_return([])
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).not_to include('Furniture:')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'omits Decorations line when room has no decorations' do
      allow(room).to receive(:visible_decorations).and_return([])
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).not_to include('Decorations:')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'includes imperfections from era profile' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('film grain')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'includes no people directive' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('No people')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'uses indoor framing for bar room type' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('interior architectural shot')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    context 'with outdoor nature room type' do
      let(:forest_room) do
        double('Room',
               id: 3, name: 'Deep Forest',
               room_type: 'forest',
               description: 'A dense ancient forest with towering oaks.',
               short_description: 'Dense forest',
               visible_places: [], visible_decorations: [])
      end

      it 'uses outdoor nature framing' do
        expect(WorldBuilderImageService).to receive(:generate) do |args|
          expect(args[:description]).to include('landscape shot')
          gen_result
        end
        described_class.generate_background(room: forest_room)
      end
    end

    context 'with outdoor urban room type' do
      let(:street_room) do
        double('Room',
               id: 4, name: 'Market Street',
               room_type: 'street',
               description: 'A bustling market street lined with vendor stalls.',
               short_description: 'Market street',
               visible_places: [], visible_decorations: [])
      end

      it 'uses outdoor urban framing' do
        expect(WorldBuilderImageService).to receive(:generate) do |args|
          expect(args[:description]).to include('street-level establishing shot')
          gen_result
        end
        described_class.generate_background(room: street_room)
      end
    end

    context 'with underground room type' do
      let(:cave_room) do
        double('Room',
               id: 5, name: 'Dark Cavern',
               room_type: 'cave',
               description: 'A damp cavern with stalactites dripping water.',
               short_description: 'Dark cavern',
               visible_places: [], visible_decorations: [])
      end

      it 'uses underground framing' do
        expect(WorldBuilderImageService).to receive(:generate) do |args|
          expect(args[:description]).to include('moody interior shot')
          gen_result
        end
        described_class.generate_background(room: cave_room)
      end
    end

    context 'with cyberpunk era' do
      it 'uses CineStill 800T and RED Komodo' do
        expect(WorldBuilderImageService).to receive(:generate) do |args|
          expect(args[:description]).to include('CineStill 800T')
          expect(args[:description]).to include('RED Komodo')
          gen_result
        end
        described_class.generate_background(room: room, options: { setting: :cyberpunk })
      end
    end

    it 'falls back to fantasy profile for unknown setting' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('Hasselblad 500C/CM')
        gen_result
      end
      described_class.generate_background(room: room, options: { setting: :unknown_era })
    end

    it 'falls back to room name when description is nil' do
      allow(room).to receive(:description).and_return(nil)
      allow(room).to receive(:short_description).and_return(nil)
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('Common Room')
        gen_result
      end
      described_class.generate_background(room: room)
    end

    it 'returns success with url' do
      result = described_class.generate_background(room: room)
      expect(result[:success]).to be true
    end

    it 'enqueues mask generation job for persisted Room records' do
      real_room = create(
        :room,
        room_type: 'bar',
        long_description: 'A lively tavern room.',
        short_description: 'A tavern room.'
      )

      described_class.generate_background(room: real_room)

      expect(MaskGenerationJob).to have_received(:perform_async).with(real_room.id)
    end

    context 'when Replicate is available' do
      let(:upscaled_path) { '/app/public/images/bg_upscaled.png' }

      before do
        allow(ReplicateUpscalerService).to receive(:available?).and_return(true)
        allow(ReplicateUpscalerService).to receive(:upscale).and_return({
          success: true, output_path: upscaled_path
        })
        allow(File).to receive(:binread).with(upscaled_path).and_return('imagedata')
        allow(File).to receive(:extname).with(upscaled_path).and_return('.png')
        allow(CloudStorageService).to receive(:upload).and_return('https://r2.example.com/bg_4k.png')
      end

      it 'calls Replicate upscaler with scale 4' do
        expect(ReplicateUpscalerService).to receive(:upscale).with(
          '/app/public/images/bg.png', scale: 4
        )
        described_class.generate_background(room: room)
      end

      it 'uploads upscaled image to cloud storage' do
        expect(CloudStorageService).to receive(:upload)
        described_class.generate_background(room: room)
      end

      it 'returns upscaled URL' do
        result = described_class.generate_background(room: room)
        expect(result[:url]).to eq('https://r2.example.com/bg_4k.png')
      end

      it 'uploads webp upscaled images with image/webp content type' do
        webp_path = '/app/public/images/bg_upscaled.webp'
        allow(ReplicateUpscalerService).to receive(:upscale).and_return({
          success: true, output_path: webp_path
        })
        allow(File).to receive(:binread).with(webp_path).and_return('webpdata')
        allow(File).to receive(:extname).with(webp_path).and_return('.webp')

        expect(CloudStorageService).to receive(:upload).with(
          'webpdata',
          an_instance_of(String),
          content_type: 'image/webp'
        ).and_return('https://r2.example.com/bg_4k.webp')

        result = described_class.generate_background(room: room)
        expect(result[:url]).to eq('https://r2.example.com/bg_4k.webp')
      end
    end

    context 'when Replicate upscaling fails' do
      before do
        allow(ReplicateUpscalerService).to receive(:available?).and_return(true)
        allow(ReplicateUpscalerService).to receive(:upscale).and_return({
          success: false, error: 'API error'
        })
      end

      it 'falls back to original image without failing' do
        result = described_class.generate_background(room: room)
        expect(result[:success]).to be true
        expect(result[:url]).to eq('https://r2.example.com/bg.png')
      end
    end
  end

  describe '.generate_descriptions_batch' do
    let(:rooms) { [room, room] }

    before do
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'Batch description'
      })
    end

    it 'generates descriptions for multiple rooms' do
      results = described_class.generate_descriptions_batch(
        rooms: rooms,
        setting: :fantasy
      )

      expect(results.length).to eq(2)
      expect(results).to all(include(:room_id, :success))
    end
  end

  describe '.generate_description_for_type' do
    before do
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'Generated description'
      })
    end

    it 'generates description for room type' do
      result = described_class.generate_description_for_type(
        name: 'Test Room',
        room_type: 'bar',
        parent: location,
        setting: :fantasy,
        seed_terms: seed_terms,
        options: {}
      )

      expect(result[:success]).to be true
    end

    it 'includes existing description when provided' do
      result = described_class.generate_description_for_type(
        name: 'Test',
        room_type: 'shop',
        parent: location,
        setting: :fantasy,
        seed_terms: [],
        existing_description: 'Old description',
        options: {}
      )

      expect(result[:success]).to be true
    end
  end

  describe 'ROOM_CATEGORIES constant' do
    it 'has residential rooms' do
      expect(described_class::ROOM_CATEGORIES[:residential]).to include('bedroom', 'kitchen')
    end

    it 'has commercial rooms' do
      expect(described_class::ROOM_CATEGORIES[:commercial]).to include('shop', 'office')
    end

    it 'has outdoor nature rooms' do
      expect(described_class::ROOM_CATEGORIES[:outdoor_nature]).to include('forest', 'beach')
    end

    it 'has underground rooms' do
      expect(described_class::ROOM_CATEGORIES[:underground]).to include('cave', 'dungeon')
    end
  end

  describe '.generate_location_background' do
    let(:location_obj) do
      double('Location',
             id: 10,
             name: 'The Silver Quarter',
             default_description: 'A prosperous merchant district with wide cobblestone streets.')
    end

    let(:gen_result) do
      { success: true, url: 'https://r2.example.com/area.png',
        local_url: '/images/area.png', local_path: '/app/public/images/area.png' }
    end

    before do
      allow(WorldBuilderImageService).to receive(:generate).and_return(gen_result)
      allow(ReplicateUpscalerService).to receive(:available?).and_return(false)
      allow(GamePrompts).to receive(:get).and_call_original
      allow(GamePrompts).to receive(:photo_profile).and_call_original
      allow(GamePrompts).to receive(:room_framing).and_call_original
    end

    it 'includes film still framing' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('Film still from a')
        gen_result
      end
      described_class.generate_location_background(location: location_obj)
    end

    it 'includes location description in prompt' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('prosperous merchant district')
        gen_result
      end
      described_class.generate_location_background(location: location_obj)
    end

    it 'uses panoramic establishing shot' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('panoramic establishing shot')
        gen_result
      end
      described_class.generate_location_background(location: location_obj)
    end

    it 'does not include Furniture or Decorations' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).not_to include('Furniture:')
        expect(args[:description]).not_to include('Decorations:')
        gen_result
      end
      described_class.generate_location_background(location: location_obj)
    end

    it 'uses era profile from setting option' do
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('RED Komodo')
        expect(args[:description]).to include('CineStill 800T')
        gen_result
      end
      described_class.generate_location_background(
        location: location_obj,
        options: { setting: :cyberpunk }
      )
    end

    it 'falls back to location name when no default_description' do
      allow(location_obj).to receive(:default_description).and_return(nil)
      expect(WorldBuilderImageService).to receive(:generate) do |args|
        expect(args[:description]).to include('The Silver Quarter')
        gen_result
      end
      described_class.generate_location_background(location: location_obj)
    end

    it 'returns success result' do
      result = described_class.generate_location_background(location: location_obj)
      expect(result[:success]).to be true
    end

    context 'when Replicate is available' do
      before do
        allow(ReplicateUpscalerService).to receive(:available?).and_return(true)
        allow(ReplicateUpscalerService).to receive(:upscale).and_return({
          success: true, output_path: '/app/public/images/area_upscaled.png'
        })
        allow(File).to receive(:binread).and_return('data')
        allow(File).to receive(:extname).and_return('.png')
        allow(CloudStorageService).to receive(:upload).and_return('https://r2.example.com/area_4k.png')
      end

      it 'upscales and returns 4K URL' do
        result = described_class.generate_location_background(location: location_obj)
        expect(result[:url]).to eq('https://r2.example.com/area_4k.png')
      end
    end
  end

  describe 'TIMES_OF_DAY constant' do
    it 'has all four times' do
      expect(described_class::TIMES_OF_DAY).to eq(%i[dawn day dusk night])
    end
  end

  describe 'SEASONS constant' do
    it 'has all four seasons' do
      expect(described_class::SEASONS).to eq(%i[spring summer fall winter])
    end
  end

  describe 'private methods' do
    describe '.categorize_room_type' do
      it 'categorizes bedroom as residential' do
        result = described_class.send(:categorize_room_type, 'bedroom')
        expect(result).to eq(:residential)
      end

      it 'categorizes shop as commercial' do
        result = described_class.send(:categorize_room_type, 'shop')
        expect(result).to eq(:commercial)
      end

      it 'categorizes forest as outdoor_nature' do
        result = described_class.send(:categorize_room_type, 'forest')
        expect(result).to eq(:outdoor_nature)
      end

      it 'returns general for unknown types' do
        result = described_class.send(:categorize_room_type, 'unknown')
        expect(result).to eq(:general)
      end
    end

    describe '.lighting_for_time' do
      it 'returns dawn lighting' do
        result = described_class.send(:lighting_for_time, :dawn)
        expect(result).to include('golden light')
      end

      it 'returns night lighting' do
        result = described_class.send(:lighting_for_time, :night)
        expect(result).to include('Darkness')
      end
    end

    describe '.weather_hints_for_season' do
      it 'returns spring weather' do
        result = described_class.send(:weather_hints_for_season, :spring)
        expect(result).to include('Fresh air')
      end

      it 'returns winter weather' do
        result = described_class.send(:weather_hints_for_season, :winter)
        expect(result).to include('Cold')
      end
    end

    describe '.tech_constraints_for_setting' do
      it 'returns fantasy constraints' do
        result = described_class.send(:tech_constraints_for_setting, :fantasy)
        expect(result).to include('medieval')
        expect(result).to include('NO electricity')
      end

      it 'returns scifi constraints' do
        result = described_class.send(:tech_constraints_for_setting, :scifi)
        expect(result).to include('futuristic')
      end

      it 'returns empty for unknown settings' do
        result = described_class.send(:tech_constraints_for_setting, :modern)
        expect(result).to eq('')
      end
    end

    describe '.room_category_guidance' do
      it 'returns residential guidance' do
        result = described_class.send(:room_category_guidance, :residential, 'bedroom')
        expect(result).to include('comfort')
      end

      it 'returns commercial guidance' do
        result = described_class.send(:room_category_guidance, :commercial, 'shop')
        expect(result).to include('purpose')
      end

      it 'returns default guidance for unknown category' do
        result = described_class.send(:room_category_guidance, :unknown, 'custom_room')
        expect(result).to include('custom_room')
      end
    end
  end
end
