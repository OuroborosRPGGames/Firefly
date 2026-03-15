# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldBuilderImageService do
  let(:image_result) do
    { success: true, url: 'https://example.com/generated-image.png' }
  end

  let(:image_config) do
    { prefix: 'A detailed photo of', suffix: 'on black background', ratio: '1:1', style: 'product' }
  end

  # The production code references ::LLM::ImageGenerationService.
  # We stub the constant in the LLM namespace so the service code can find it.
  before do
    stub_const('LLM::ImageGenerationService', Class.new do
      class << self
        attr_accessor :generate_result, :available_result, :last_call

        def generate(**args)
          @last_call = args
          generate_result || { success: true, url: 'https://example.com/image.png' }
        end

        def available?
          available_result != false
        end
      end
    end)
    LLM::ImageGenerationService.generate_result = image_result
    LLM::ImageGenerationService.available_result = true
    allow(GamePrompts).to receive(:image_template).and_return(image_config)
    allow(GamePrompts).to receive(:setting_modifier).and_return(nil)
  end

  describe '.generate' do
    it 'returns success with url' do
      result = described_class.generate(type: :item_on_black, description: 'a sword')
      expect(result[:success]).to be true
      expect(result[:url]).to eq('https://example.com/generated-image.png')
    end

    it 'includes prompt used in response' do
      result = described_class.generate(type: :item_on_black, description: 'a sword')
      expect(result[:prompt_used]).to include('a sword')
    end

    it 'builds prompt with prefix and suffix' do
      described_class.generate(type: :item_on_black, description: 'test item')
      expect(LLM::ImageGenerationService.last_call[:prompt]).to include('A detailed photo of')
      expect(LLM::ImageGenerationService.last_call[:prompt]).to include('on black background')
      expect(LLM::ImageGenerationService.last_call[:prompt]).to include('test item')
    end

    it 'passes aspect ratio' do
      described_class.generate(type: :item_on_black, description: 'test')
      expect(LLM::ImageGenerationService.last_call[:options][:aspect_ratio]).to eq('1:1')
    end

    it 'passes style' do
      described_class.generate(type: :item_on_black, description: 'test')
      expect(LLM::ImageGenerationService.last_call[:options][:style]).to eq('product')
    end

    context 'with unknown image type' do
      before do
        allow(GamePrompts).to receive(:image_template).and_return(nil)
      end

      it 'returns error' do
        result = described_class.generate(type: :unknown, description: 'test')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown image type')
      end
    end

    context 'with setting modifier' do
      before do
        allow(GamePrompts).to receive(:setting_modifier).with(:fantasy).and_return('medieval fantasy style')
      end

      it 'includes setting modifier in prompt' do
        described_class.generate(type: :item_on_black, description: 'a sword', options: { setting: :fantasy })
        expect(LLM::ImageGenerationService.last_call[:prompt]).to include('medieval fantasy style')
      end
    end

    context 'with additional prompt' do
      it 'includes additional prompt text' do
        described_class.generate(
          type: :item_on_black,
          description: 'a sword',
          options: { additional_prompt: 'extra details' }
        )
        expect(LLM::ImageGenerationService.last_call[:prompt]).to include('extra details')
      end
    end

    context 'when image generation fails' do
      before do
        LLM::ImageGenerationService.generate_result = { success: false, error: 'API error' }
      end

      it 'returns error' do
        result = described_class.generate(type: :item_on_black, description: 'test')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('API error')
      end
    end

    context 'with save_locally option' do
      let(:room) { create(:room) }

      before do
        # Mock file operations
        allow(FileUtils).to receive(:mkdir_p)
        allow(File).to receive(:binwrite)

        # Mock HTTP download
        mock_response = instance_double(Net::HTTPSuccess, body: 'image data')
        allow(mock_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:get_response).and_return(mock_response)
      end

      it 'saves image locally' do
        expect(File).to receive(:binwrite)
        described_class.generate(
          type: :item_on_black,
          description: 'test',
          options: { save_locally: true }
        )
      end

      it 'returns local_url' do
        result = described_class.generate(
          type: :item_on_black,
          description: 'test',
          options: { save_locally: true }
        )
        expect(result[:local_url]).to include('/images/generated/')
      end

      it 'uses target for filename when provided' do
        result = described_class.generate(
          type: :room_background,
          description: 'test room',
          options: { target: room }
        )
        expect(result[:local_path]).to include("room_#{room.id}")
      end

      context 'when download fails' do
        before do
          mock_response = instance_double(Net::HTTPNotFound, code: '404', message: 'Not Found')
          allow(mock_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
          allow(Net::HTTP).to receive(:get_response).and_return(mock_response)
        end

        it 'returns save error' do
          result = described_class.generate(
            type: :item_on_black,
            description: 'test',
            options: { save_locally: true }
          )
          expect(result[:success]).to be true  # Generation succeeded
          expect(result[:save_error]).to include('404')
        end
      end

      context 'when exception occurs during download' do
        before do
          allow(Net::HTTP).to receive(:get_response).and_raise(SocketError.new('Connection failed'))
        end

        it 'returns download error' do
          result = described_class.generate(
            type: :item_on_black,
            description: 'test',
            options: { save_locally: true }
          )
          expect(result[:success]).to be true  # Generation succeeded
          expect(result[:save_error]).to include('Download failed')
        end
      end
    end

    it 'passes custom aspect ratio' do
      allow(GamePrompts).to receive(:image_template).and_return({
        prefix: '', suffix: '', ratio: '16:9', style: 'landscape'
      })
      described_class.generate(type: :room_background, description: 'test')
      expect(LLM::ImageGenerationService.last_call[:options][:aspect_ratio]).to eq('16:9')
    end

    it 'passes custom style' do
      allow(GamePrompts).to receive(:image_template).and_return({
        prefix: '', suffix: '', ratio: '1:1', style: 'portrait'
      })
      described_class.generate(type: :npc_portrait, description: 'test')
      expect(LLM::ImageGenerationService.last_call[:options][:style]).to eq('portrait')
    end
  end

  describe 'photographic prompt building' do
    let(:photographic_config) do
      {
        prefix: 'Portrait headshot, plain neutral background,',
        suffix: 'detailed face, expressive eyes',
        ratio: '3:4',
        style: :photographic,
        image_framing: {
          lens_override: '85mm f/1.4',
          framing: 'studio portrait, head and shoulders, shallow depth of field',
          lighting_extra: 'soft key light with warm fill',
          directives: '3:4 portrait composition'
        }
      }
    end

    let(:fantasy_profile) do
      {
        camera: 'Hasselblad 500C/CM',
        default_lens: '80mm f/2.8',
        film_stock: 'Kodak Portra 400',
        lighting: 'golden hour, volumetric fog',
        imperfections: 'film grain, natural material textures',
        genre_phrase: 'dark fantasy epic'
      }
    end

    let(:modern_profile) do
      {
        camera: 'Canon EOS R5',
        default_lens: '24mm f/1.4',
        film_stock: '',
        lighting: 'global illumination, practical lighting',
        imperfections: 'shallow depth of field, subtle lens flare',
        genre_phrase: 'contemporary drama'
      }
    end

    before do
      allow(GamePrompts).to receive(:image_template).and_return(photographic_config)
      allow(GamePrompts).to receive(:photo_profile).with(:fantasy).and_return(fantasy_profile)
      allow(GamePrompts).to receive(:photo_profile).with(:modern).and_return(modern_profile)
      allow(GamePrompts).to receive(:photo_profile).with(:unknown_setting).and_return(nil)
    end

    it 'activates photographic mode when image_framing and setting present' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'A weathered elven merchant',
        options: { setting: :fantasy }
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('Film still from a dark fantasy epic production')
      expect(prompt).to include('Hasselblad 500C/CM')
      expect(prompt).to include('85mm f/1.4')
      expect(prompt).to include('Kodak Portra 400')
      expect(prompt).to include('A weathered elven merchant')
    end

    it 'uses lens_override from framing over profile default_lens' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'test',
        options: { setting: :fantasy }
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('85mm f/1.4')
      expect(prompt).not_to include('80mm f/2.8')
    end

    it 'falls back to profile default_lens when lens_override is nil' do
      config_no_lens = photographic_config.merge(
        image_framing: photographic_config[:image_framing].merge(lens_override: nil)
      )
      allow(GamePrompts).to receive(:image_template).and_return(config_no_lens)

      result = described_class.generate(
        type: :npc_portrait,
        description: 'test',
        options: { setting: :fantasy }
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('80mm f/2.8')
    end

    it 'omits "shot on" when film_stock is empty (modern era)' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'A modern detective',
        options: { setting: :modern }
      )
      prompt = result[:prompt_used]
      expect(prompt).not_to include('shot on')
      expect(prompt).to include('Canon EOS R5')
    end

    it 'falls back to legacy prompt when no setting provided' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'An elf warrior',
        options: {}
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('Portrait headshot')
      expect(prompt).to include('detailed face')
      expect(prompt).not_to include('Film still')
    end

    it 'falls back to fantasy profile when unknown setting' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'test',
        options: { setting: :unknown_setting }
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('dark fantasy epic')
      expect(prompt).to include('Hasselblad 500C/CM')
    end

    it 'includes additional_prompt in photographic mode' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'test',
        options: { setting: :fantasy, additional_prompt: 'extra details here' }
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('extra details here')
    end

    it 'includes lighting and framing in photographic prompt' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'test',
        options: { setting: :fantasy }
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('golden hour, volumetric fog')
      expect(prompt).to include('soft key light with warm fill')
      expect(prompt).to include('studio portrait, head and shoulders')
    end

    it 'includes imperfections and directives in photographic prompt' do
      result = described_class.generate(
        type: :npc_portrait,
        description: 'test',
        options: { setting: :fantasy }
      )
      prompt = result[:prompt_used]
      expect(prompt).to include('film grain, natural material textures')
      expect(prompt).to include('3:4 portrait composition')
    end

    context 'NPC portrait vs building exterior directives' do
      it 'NPC portrait prompt does NOT include "No people"' do
        result = described_class.generate(
          type: :npc_portrait,
          description: 'A weathered warrior',
          options: { setting: :fantasy }
        )
        expect(result[:prompt_used]).not_to include('No people')
      end

      it 'building exterior prompt includes "No people"' do
        building_config = {
          prefix: 'Architectural exterior,',
          suffix: 'detailed facade',
          ratio: '4:3',
          style: :photographic,
          image_framing: {
            lens_override: '35mm',
            framing: 'architectural exterior, street level establishing shot',
            lighting_extra: 'natural environmental lighting',
            directives: 'No people. 4:3 composition'
          }
        }
        allow(GamePrompts).to receive(:image_template).and_return(building_config)

        result = described_class.generate(
          type: :building_exterior,
          description: 'A stone tavern',
          options: { setting: :fantasy }
        )
        expect(result[:prompt_used]).to include('No people')
      end
    end

    context 'legacy mode with no image_framing' do
      let(:legacy_config) do
        { prefix: 'Product shot,', suffix: 'on black background', ratio: '1:1', style: :product }
      end

      before do
        allow(GamePrompts).to receive(:image_template).and_return(legacy_config)
      end

      it 'uses legacy prompt even with setting when no image_framing' do
        allow(GamePrompts).to receive(:setting_modifier).with(:fantasy).and_return('medieval fantasy style')
        result = described_class.generate(
          type: :item_on_black,
          description: 'a sword',
          options: { setting: :fantasy }
        )
        prompt = result[:prompt_used]
        expect(prompt).to include('Product shot,')
        expect(prompt).to include('medieval fantasy style')
        expect(prompt).to include('on black background')
        expect(prompt).not_to include('Film still')
      end
    end
  end

  describe '.generate_batch' do
    it 'generates multiple images' do
      items = [
        { type: :item_on_black, description: 'sword' },
        { type: :npc_portrait, description: 'elf' }
      ]
      results = described_class.generate_batch(items)
      expect(results.length).to eq(2)
    end

    it 'returns results for each item' do
      items = [
        { type: :item_on_black, description: 'sword' },
        { type: :npc_portrait, description: 'elf' }
      ]
      results = described_class.generate_batch(items)
      expect(results).to all(include(success: true))
    end
  end

  describe '.available?' do
    it 'returns true when service is available' do
      LLM::ImageGenerationService.available_result = true
      expect(described_class.available?).to be true
    end

    it 'returns false when unavailable' do
      LLM::ImageGenerationService.available_result = false
      expect(described_class.available?).to be false
    end
  end

  describe '.available_types' do
    it 'delegates to GamePrompts' do
      expect(GamePrompts).to receive(:image_template_types).and_return([:item_on_black, :npc_portrait])
      expect(described_class.available_types).to eq([:item_on_black, :npc_portrait])
    end
  end

  describe '.type_info' do
    it 'returns type information' do
      allow(GamePrompts).to receive(:image_template).with(:item_on_black).and_return({
        ratio: '1:1',
        style: 'product',
        prefix: 'test',
        suffix: 'test'
      })
      result = described_class.type_info(:item_on_black)
      expect(result[:type]).to eq(:item_on_black)
      expect(result[:ratio]).to eq('1:1')
      expect(result[:style]).to eq('product')
    end

    it 'returns nil for unknown type' do
      allow(GamePrompts).to receive(:image_template).and_return(nil)
      expect(described_class.type_info(:unknown)).to be_nil
    end

    it 'includes human-readable description' do
      allow(GamePrompts).to receive(:image_template).with(:item_on_black).and_return(image_config)
      result = described_class.type_info(:item_on_black)
      expect(result[:description]).to eq('Product shot on black background')
    end

    it 'handles npc_portrait type' do
      allow(GamePrompts).to receive(:image_template).with(:npc_portrait).and_return(image_config)
      result = described_class.type_info(:npc_portrait)
      expect(result[:description]).to eq('Character portrait headshot')
    end

    it 'handles room_background type' do
      allow(GamePrompts).to receive(:image_template).with(:room_background).and_return(image_config)
      result = described_class.type_info(:room_background)
      expect(result[:description]).to eq('Interior scene background (HD)')
    end

    it 'handles room_background_4k type' do
      allow(GamePrompts).to receive(:image_template).with(:room_background_4k).and_return(image_config)
      result = described_class.type_info(:room_background_4k)
      expect(result[:description]).to eq('Interior scene background (4K)')
    end

    it 'handles furniture type' do
      allow(GamePrompts).to receive(:image_template).with(:furniture).and_return(image_config)
      result = described_class.type_info(:furniture)
      expect(result[:description]).to eq('Furniture product shot')
    end

    it 'handles building_exterior type' do
      allow(GamePrompts).to receive(:image_template).with(:building_exterior).and_return(image_config)
      result = described_class.type_info(:building_exterior)
      expect(result[:description]).to eq('Building exterior shot')
    end

    it 'handles city_overview type' do
      allow(GamePrompts).to receive(:image_template).with(:city_overview).and_return(image_config)
      result = described_class.type_info(:city_overview)
      expect(result[:description]).to eq('City aerial overview')
    end

    it 'handles street_scene type' do
      allow(GamePrompts).to receive(:image_template).with(:street_scene).and_return(image_config)
      result = described_class.type_info(:street_scene)
      expect(result[:description]).to eq('Street level scene')
    end
  end
end
