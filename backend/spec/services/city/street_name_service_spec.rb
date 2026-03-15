# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/city/street_name_service'
require_relative '../../../app/services/llm/client'

RSpec.describe StreetNameService do
  # Build proper association chain
  let(:fantasy_universe) { create(:universe, theme: 'fantasy', name: 'Fantasy World') }
  let(:fantasy_world) { create(:world, universe: fantasy_universe, name: 'Middle Earth') }
  let(:fantasy_area) { create(:area, world: fantasy_world, name: 'Downtown') }
  let(:location) { create(:location, zone: fantasy_area, name: 'Test City') }

  describe '.generate' do
    context 'with a test universe' do
      # Use valid theme but 'Test' in the name - service detects test universes by name
      let(:test_universe) { create(:universe, name: 'Test Universe', theme: 'fantasy') }
      let(:test_world) { create(:world, universe: test_universe, name: 'Test World') }
      let(:test_area) { create(:area, world: test_world, name: 'Test Area') }
      let(:test_location) { create(:location, zone: test_area, name: 'Test Location') }

      it 'generates numbered street names' do
        # Force reload to ensure associations are loaded
        test_location.reload
        result = described_class.generate(location: test_location, count: 5, direction: :street)

        expect(result).to eq(['1st Street', '2nd Street', '3rd Street', '4th Street', '5th Street'])
      end

      it 'generates numbered avenue names' do
        test_location.reload
        result = described_class.generate(location: test_location, count: 3, direction: :avenue)

        expect(result).to eq(['1st Avenue', '2nd Avenue', '3rd Avenue'])
      end
    end

    context 'with a fantasy universe' do
      before do
        # Create the location first to ensure associations exist
        location.reload
        # Mock NameGeneratorService to avoid full initialization
        allow(NameGeneratorService).to receive(:street).and_return(
          double('StreetResult', to_s: 'Dragon Lane')
        )
      end

      it 'uses NameGeneratorService for local generation' do
        result = described_class.generate(location: location, count: 3, direction: :street)

        expect(NameGeneratorService).to have_received(:street).at_least(:once)
        expect(result.length).to eq(3)
      end
    end

    context 'when use_llm is forced true' do
      before do
        location.reload
        # Stub underlying dependency and LLM client
        allow(AIProviderService).to receive(:any_available?).and_return(true)
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: true,
                                                              text: 'Oak Avenue, Maple Avenue, Pine Avenue'
                                                            })
      end

      it 'uses LLM generation' do
        result = described_class.generate(location: location, count: 3, direction: :avenue, use_llm: true)

        expect(LLM::Client).to have_received(:generate)
        expect(result).to eq(['Oak Avenue', 'Maple Avenue', 'Pine Avenue'])
      end
    end

    context 'when LLM fails' do
      before do
        location.reload
        allow(AIProviderService).to receive(:any_available?).and_return(true)
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: false,
                                                              error: 'API error'
                                                            })
      end

      it 'falls back to numbered names' do
        result = described_class.generate(location: location, count: 3, direction: :street, use_llm: true)

        expect(result).to eq(['1st Street', '2nd Street', '3rd Street'])
      end
    end
  end

  describe '.generate_numbered' do
    it 'generates correct ordinal street names' do
      result = described_class.generate_numbered(count: 5, direction: :street)

      expect(result).to eq(['1st Street', '2nd Street', '3rd Street', '4th Street', '5th Street'])
    end

    it 'generates correct ordinal avenue names' do
      result = described_class.generate_numbered(count: 4, direction: :avenue)

      expect(result).to eq(['1st Avenue', '2nd Avenue', '3rd Avenue', '4th Avenue'])
    end

    it 'handles 11th, 12th, 13th correctly' do
      result = described_class.generate_numbered(count: 15, direction: :street)

      expect(result[10]).to eq('11th Street')
      expect(result[11]).to eq('12th Street')
      expect(result[12]).to eq('13th Street')
    end

    it 'handles 21st, 22nd, 23rd correctly' do
      result = described_class.generate_numbered(count: 25, direction: :avenue)

      expect(result[20]).to eq('21st Avenue')
      expect(result[21]).to eq('22nd Avenue')
      expect(result[22]).to eq('23rd Avenue')
    end
  end

  describe '.generate_with_llm' do
    before do
      allow(LLM::Client).to receive(:generate).and_return({
                                                            success: true,
                                                            text: 'Broadway, Fifth Avenue, Madison Avenue'
                                                          })
    end

    it 'parses comma-separated response' do
      result = described_class.generate_with_llm(
        zone_name: 'New York City',
        count: 3,
        direction: :avenue
      )

      expect(result).to eq(['Broadway', 'Fifth Avenue', 'Madison Avenue'])
    end

    context 'with numbered list response' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: true,
                                                              text: "1. Park Street\n2. Oak Street\n3. Elm Street"
                                                            })
      end

      it 'parses numbered list format' do
        result = described_class.generate_with_llm(
          zone_name: 'Boston',
          count: 3,
          direction: :street
        )

        expect(result).to eq(['Park Street', 'Oak Street', 'Elm Street'])
      end
    end

    context 'when LLM returns fewer names than requested' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
                                                              success: true,
                                                              text: 'Main Street, Oak Street'
                                                            })
      end

      it 'fills in remaining with numbered names' do
        result = described_class.generate_with_llm(
          zone_name: 'Test Town',
          count: 4,
          direction: :street
        )

        expect(result).to eq(['Main Street', 'Oak Street', '3rd Street', '4th Street'])
      end
    end

    context 'with year context' do
      it 'includes year in prompt for AD years' do
        described_class.generate_with_llm(
          zone_name: 'London',
          count: 3,
          direction: :street,
          year: 1850
        )

        expect(LLM::Client).to have_received(:generate) do |args|
          expect(args[:prompt]).to include('1850 AD')
        end
      end

      it 'includes year in prompt for BC years' do
        described_class.generate_with_llm(
          zone_name: 'Rome',
          count: 3,
          direction: :avenue,
          year: -50
        )

        expect(LLM::Client).to have_received(:generate) do |args|
          expect(args[:prompt]).to include('50 BC')
        end
      end
    end
  end

  describe '.should_use_llm?' do
    let(:modern_universe) { create(:universe, theme: 'modern') }
    let(:modern_world) { create(:world, universe: modern_universe) }

    let(:fantasy_universe) { create(:universe, theme: 'fantasy') }
    let(:fantasy_world) { create(:world, universe: fantasy_universe) }

    before do
      allow(described_class).to receive(:llm_available?).and_return(true)
    end

    it 'returns true for modern theme' do
      expect(described_class.should_use_llm?(modern_world)).to be true
    end

    it 'returns false for fantasy theme' do
      expect(described_class.should_use_llm?(fantasy_world)).to be false
    end

    it 'returns false when LLM is not available' do
      allow(described_class).to receive(:llm_available?).and_return(false)

      expect(described_class.should_use_llm?(modern_world)).to be false
    end

    it 'returns false for nil world' do
      expect(described_class.should_use_llm?(nil)).to be false
    end
  end

  describe '.generate_local' do
    before do
      allow(NameGeneratorService).to receive(:street).and_return(
        double('StreetResult', to_s: 'Dragon Lane')
      )
    end

    it 'generates the requested number of names' do
      result = described_class.generate_local(count: 5, direction: :street)

      expect(result.length).to eq(5)
    end

    it 'passes setting to NameGeneratorService' do
      described_class.generate_local(count: 3, direction: :avenue, setting: :sci_fi)

      expect(NameGeneratorService).to have_received(:street).with(setting: :sci_fi).at_least(:once)
    end

    context 'when names are not unique' do
      before do
        call_count = 0
        allow(NameGeneratorService).to receive(:street) do
          call_count += 1
          # Return same name for first 3 calls, then different names
          double('StreetResult', to_s: call_count <= 3 ? 'Same Lane' : "Other Lane #{call_count}")
        end
      end

      it 'ensures unique names with fallbacks' do
        result = described_class.generate_local(count: 3, direction: :street)

        expect(result.uniq.length).to eq(3)
      end
    end
  end
end
