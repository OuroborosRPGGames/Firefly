# frozen_string_literal: true

require 'spec_helper'
require_relative '../../config/game_prompts'

RSpec.describe GamePrompts do
  describe '.get' do
    it 'retrieves a simple prompt by path' do
      prompt = described_class.get('combat.prose_enhancement', paragraph: 'test')
      expect(prompt).to include('Rewrite this combat')
      expect(prompt).to include('test')
    end

    it 'retrieves a nested prompt by path' do
      prompt = described_class.get('activities.free_roll.assess',
                                   situation: 'dungeon',
                                   participant_name: 'Bob',
                                   assessment_text: 'check trap')
      expect(prompt).to include('GM')
      expect(prompt).to include('Bob')
      expect(prompt).to include('check trap')
    end

    it 'interpolates variables correctly' do
      prompt = described_class.get('triggers.behavior_matching',
                                   content: 'The guard draws a sword',
                                   trigger_condition: 'guard becomes hostile')
      expect(prompt).to include('The guard draws a sword')
      expect(prompt).to include('guard becomes hostile')
    end

    it 'raises ArgumentError for non-existent path' do
      expect { described_class.get('nonexistent.path') }
        .to raise_error(ArgumentError, /Prompt not found/)
    end

    it 'raises ArgumentError for path to hash (not string)' do
      expect { described_class.get('activities') }
        .to raise_error(ArgumentError, /not a string prompt/)
    end

    it 'leaves unmatched placeholders as-is' do
      prompt = described_class.get('combat.prose_enhancement', paragraph: 'test')
      # The prompt template has %{paragraph} which should be replaced
      expect(prompt).not_to include('%{paragraph}')
    end
  end

  describe '.get_safe' do
    it 'returns nil for non-existent path instead of raising' do
      result = described_class.get_safe('nonexistent.path')
      expect(result).to be_nil
    end

    it 'returns prompt for valid path' do
      result = described_class.get_safe('combat.prose_enhancement', paragraph: 'test')
      expect(result).to include('Rewrite this combat')
    end
  end

  describe '.exists?' do
    it 'returns true for existing string prompt' do
      expect(described_class.exists?('combat.prose_enhancement')).to be true
    end

    it 'returns false for non-existent path' do
      expect(described_class.exists?('fake.path.here')).to be false
    end

    it 'returns false for path to hash (not string)' do
      expect(described_class.exists?('activities')).to be false
    end
  end

  describe '.image_template' do
    it 'returns prefix and suffix for valid template' do
      template = described_class.image_template(:npc_portrait)
      expect(template).to be_a(Hash)
      expect(template[:prefix]).to include('Portrait headshot')
      expect(template[:suffix]).to include('character portrait')
    end

    it 'returns nil for non-existent template' do
      result = described_class.image_template(:nonexistent)
      expect(result).to be_nil
    end
  end

  describe '.image_template image_framing' do
    before { described_class.reload! }

    it 'returns image_framing hash for npc_portrait' do
      template = described_class.image_template(:npc_portrait)
      expect(template[:image_framing]).to be_a(Hash)
      expect(template[:image_framing][:lens_override]).to eq('85mm f/1.4')
      expect(template[:image_framing][:framing]).to include('studio portrait')
      expect(template[:image_framing][:lighting_extra]).to include('key light')
      expect(template[:image_framing][:directives]).to include('portrait composition')
    end

    it 'returns nil image_framing for item_on_black (no framing)' do
      template = described_class.image_template(:item_on_black)
      expect(template[:image_framing]).to be_nil
    end

    it 'all 5 new types have image_framing with required keys' do
      %i[npc_portrait npc_full_body building_exterior city_overview street_scene].each do |type|
        template = described_class.image_template(type)
        expect(template[:image_framing]).to be_a(Hash), "Expected image_framing for #{type}"
        expect(template[:image_framing]).to have_key(:lens_override)
        expect(template[:image_framing]).to have_key(:framing)
        expect(template[:image_framing]).to have_key(:lighting_extra)
        expect(template[:image_framing]).to have_key(:directives)
      end
    end

    it 'all 5 new types have style: :photographic' do
      %i[npc_portrait npc_full_body building_exterior city_overview street_scene].each do |type|
        template = described_class.image_template(type)
        expect(template[:style]).to eq(:photographic), "Expected photographic style for #{type}"
      end
    end
  end

  describe '.setting_modifier' do
    it 'returns modifier for valid setting' do
      modifier = described_class.setting_modifier(:fantasy)
      expect(modifier).to include('fantasy')
      expect(modifier).to include('magical')
    end

    it 'returns nil for non-existent setting' do
      result = described_class.setting_modifier(:nonexistent)
      expect(result).to be_nil
    end
  end

  describe '.photo_profile' do
    it 'returns profile hash for valid era' do
      profile = described_class.photo_profile(:fantasy)
      expect(profile).to be_a(Hash)
      expect(profile[:camera]).to eq('Hasselblad 500C/CM')
      expect(profile[:film_stock]).to eq('Kodak Portra 400')
      expect(profile[:genre_phrase]).to eq('dark fantasy epic')
    end

    it 'returns profile for all five eras' do
      %i[fantasy gaslight modern cyberpunk scifi].each do |era|
        profile = described_class.photo_profile(era)
        expect(profile).to be_a(Hash), "Expected profile for #{era}"
        expect(profile[:camera]).to be_a(String)
        expect(profile[:genre_phrase]).to be_a(String)
      end
    end

    it 'returns nil for unknown era' do
      expect(described_class.photo_profile(:unknown)).to be_nil
    end
  end

  describe '.room_framing' do
    it 'returns framing hash for valid category' do
      framing = described_class.room_framing(:indoor)
      expect(framing).to be_a(Hash)
      expect(framing[:lens_override]).to eq('24mm wide angle')
      expect(framing[:framing]).to include('interior')
    end

    it 'returns framing for all four categories' do
      %i[indoor outdoor_urban outdoor_nature underground].each do |cat|
        framing = described_class.room_framing(cat)
        expect(framing).to be_a(Hash), "Expected framing for #{cat}"
        expect(framing[:lens_override]).to be_a(String)
      end
    end

    it 'returns nil for unknown category' do
      expect(described_class.room_framing(:unknown)).to be_nil
    end
  end

  describe '.all_paths' do
    it 'returns array of all prompt paths' do
      paths = described_class.all_paths
      expect(paths).to be_an(Array)
      expect(paths).to include('combat.prose_enhancement')
      expect(paths).to include('triggers.behavior_matching')
      expect(paths).to include('activities.free_roll.assess')
    end

    it 'includes deeply nested paths' do
      paths = described_class.all_paths
      expect(paths.any? { |p| p.count('.') >= 2 }).to be true
    end
  end

  describe '.reload!' do
    it 'reloads prompts from disk' do
      # First access caches the prompts
      described_class.get('combat.prose_enhancement', paragraph: 'x')

      # Reload should work without error
      described_class.reload!

      # Should still work after reload
      prompt = described_class.get('combat.prose_enhancement', paragraph: 'y')
      expect(prompt).to include('y')
    end
  end

  describe '.raw' do
    it 'returns the raw prompts hash' do
      raw = described_class.raw
      expect(raw).to be_a(Hash)
      expect(raw).to have_key('combat')
      expect(raw).to have_key('activities')
      expect(raw).to have_key('abuse_detection')
    end
  end

  describe 'prompt content validation' do
    it 'abuse_detection.first_pass has required sections' do
      prompt = described_class.get('abuse_detection.first_pass',
                                   message_type: 'say',
                                   content: 'test content')
      expect(prompt).to include('content moderation')
      expect(prompt).to include('JSON')
      expect(prompt).to include('flagged')
    end

    it 'npc_generation.physical_appearance has required sections' do
      prompt = described_class.get('npc_generation.physical_appearance',
                                   name: 'Bob',
                                   gender: 'male',
                                   role: 'guard',
                                   setting: 'fantasy',
                                   terms_str: 'brave, stoic')
      expect(prompt).to include('Bob')
      expect(prompt).to include('male')
      expect(prompt).to include('guard')
      expect(prompt).to include('fantasy')
    end

    it 'missions.brainstorm has required sections' do
      prompt = described_class.get('missions.brainstorm',
                                   description: 'Rescue the princess',
                                   setting: 'fantasy',
                                   seed_terms: 'dragon, castle')
      expect(prompt).to include('Rescue the princess')
      expect(prompt).to include('NARRATIVE ARC')
      expect(prompt).to include('KEY SCENES')
      expect(prompt).to include('MEANINGFUL CHOICES')
    end
  end
end
