# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcDisplayService do
  let(:room) { create(:room) }
  let(:reality) { create(:reality, reality_type: 'primary') }

  # Create an NPC character with various attributes
  def create_npc(attrs = {})
    create(:character, :npc, attrs)
  end

  # Create a character instance for the NPC
  def create_npc_instance(character, attrs = {})
    create(:character_instance, { character: character, current_room: room, reality: reality }.merge(attrs))
  end

  describe '#initialize' do
    let(:npc) { create_npc }
    let(:npc_instance) { create_npc_instance(npc) }

    it 'sets target to the provided instance' do
      service = described_class.new(npc_instance)
      expect(service.target).to eq(npc_instance)
    end

    it 'extracts character from target' do
      service = described_class.new(npc_instance)
      expect(service.character).to eq(npc)
    end

    it 'accepts optional viewer instance' do
      viewer = create_npc_instance(create_npc)
      service = described_class.new(npc_instance, viewer_instance: viewer)
      expect(service.viewer).to eq(viewer)
    end

    it 'defaults viewer to nil' do
      service = described_class.new(npc_instance)
      expect(service.viewer).to be_nil
    end
  end

  describe '#build_display' do
    let(:npc) { create_npc(short_desc: 'a mysterious stranger') }
    let(:npc_instance) { create_npc_instance(npc, status: 'alive') }
    let(:service) { described_class.new(npc_instance) }

    it 'returns a hash' do
      expect(service.build_display).to be_a(Hash)
    end

    it 'includes is_npc flag as true' do
      expect(service.build_display[:is_npc]).to be true
    end

    it 'includes short_desc from character' do
      expect(service.build_display[:short_desc]).to eq('a mysterious stranger')
    end

    it 'includes status from instance' do
      expect(service.build_display[:status]).to eq('alive')
    end

    it 'includes profile_pic_url key' do
      # Just verify the key exists (may be nil)
      expect(service.build_display).to have_key(:profile_pic_url)
    end

    it 'includes empty held_items array' do
      expect(service.build_display[:held_items]).to eq([])
    end

    it 'includes name' do
      expect(service.build_display[:name]).not_to be_nil
    end

    it 'includes roomtitle from instance' do
      npc_instance.update(roomtitle: 'standing guard')
      result = described_class.new(npc_instance).build_display
      expect(result[:roomtitle]).to eq('standing guard')
    end

    describe 'appearance structure' do
      context 'for humanoid NPCs' do
        before do
          allow(npc).to receive(:humanoid_npc?).and_return(true)
        end

        it 'sets is_humanoid to true' do
          expect(service.build_display[:is_humanoid]).to be true
        end

        it 'returns humanoid appearance type' do
          expect(service.build_display[:appearance][:type]).to eq('humanoid')
        end
      end

      context 'for creature NPCs' do
        before do
          allow(npc).to receive(:humanoid_npc?).and_return(false)
        end

        it 'sets is_humanoid to false' do
          expect(service.build_display[:is_humanoid]).to be false
        end

        it 'returns creature appearance type' do
          expect(service.build_display[:appearance][:type]).to eq('creature')
        end
      end
    end

    describe 'thumbnails' do
      it 'returns empty array when no profile pic' do
        expect(service.build_display[:thumbnails]).to eq([])
      end

      it 'returns thumbnails key' do
        expect(service.build_display).to have_key(:thumbnails)
        expect(service.build_display[:thumbnails]).to be_an(Array)
      end
    end

    describe 'at_place' do
      it 'returns nil when not at a place' do
        expect(service.build_display[:at_place]).to be_nil
      end

      it 'returns place name when at a place' do
        place = create(:place, room: room, name: 'the bar')
        npc_instance.update(current_place_id: place.id)
        result = described_class.new(npc_instance).build_display
        expect(result[:at_place]).to eq('the bar')
      end
    end
  end

  describe 'clothing for humanoids' do
    let(:npc) { create_npc(npc_clothes_desc: 'a tattered cloak') }
    let(:npc_instance) { create_npc_instance(npc) }
    let(:service) { described_class.new(npc_instance) }

    before do
      allow(npc).to receive(:humanoid_npc?).and_return(true)
    end

    it 'returns clothing array with attire' do
      clothing = service.build_display[:clothing]
      expect(clothing).to be_an(Array)
      expect(clothing.first[:name]).to eq('attire')
    end

    it 'includes clothing description' do
      clothing = service.build_display[:clothing]
      expect(clothing.first[:description]).to eq('a tattered cloak')
    end

    it 'marks item as clothing' do
      clothing = service.build_display[:clothing]
      expect(clothing.first[:is_clothing]).to be true
    end
  end

  describe 'clothing for creatures' do
    let(:npc) { create_npc }
    let(:npc_instance) { create_npc_instance(npc) }
    let(:service) { described_class.new(npc_instance) }

    before do
      allow(npc).to receive(:humanoid_npc?).and_return(false)
    end

    it 'returns empty array' do
      expect(service.build_display[:clothing]).to eq([])
    end
  end

  describe 'intro for humanoids' do
    let(:npc) do
      create_npc(
        npc_body_desc: 'tall and lean',
        npc_eyes_desc: 'bright blue eyes',
        npc_hair_desc: 'long and silver',
        npc_skin_tone: 'pale'
      )
    end
    let(:npc_instance) { create_npc_instance(npc) }
    let(:service) { described_class.new(npc_instance) }

    before do
      allow(npc).to receive(:humanoid_npc?).and_return(true)
    end

    it 'includes body description' do
      expect(service.build_display[:intro]).to include('tall and lean')
    end

    it 'includes eyes description' do
      expect(service.build_display[:intro]).to include('bright blue eyes')
    end

    it 'includes hair description' do
      expect(service.build_display[:intro]).to include('long and silver')
    end

    it 'includes skin tone' do
      expect(service.build_display[:intro]).to include('pale')
    end
  end

  describe 'intro for creatures' do
    let(:npc) { create_npc(npc_creature_desc: 'A massive dragon with gleaming scales') }
    let(:npc_instance) { create_npc_instance(npc) }
    let(:service) { described_class.new(npc_instance) }

    before do
      allow(npc).to receive(:humanoid_npc?).and_return(false)
    end

    it 'uses creature description' do
      expect(service.build_display[:intro]).to eq('A massive dragon with gleaming scales')
    end
  end

  describe 'creature intro fallbacks' do
    let(:npc) { create_npc(npc_creature_desc: nil, npc_body_desc: 'four-legged beast', short_desc: 'a monster') }
    let(:npc_instance) { create_npc_instance(npc) }
    let(:service) { described_class.new(npc_instance) }

    before do
      allow(npc).to receive(:humanoid_npc?).and_return(false)
    end

    it 'falls back to body desc when creature_desc is nil' do
      expect(service.build_display[:intro]).to eq('four-legged beast')
    end

    it 'falls back to short_desc when both are nil' do
      npc.update(npc_body_desc: nil)
      result = described_class.new(create_npc_instance(npc)).build_display
      expect(result[:intro]).to eq('a monster')
    end
  end
end
