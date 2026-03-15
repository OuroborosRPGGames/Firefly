# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Customization::Describe, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns open_gui type with descriptions gui' do
      result = command.execute('describe')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:open_gui)
      expect(result[:data][:gui]).to eq('descriptions')
      expect(result[:data][:character_id]).to eq(character.id)
    end

    it 'includes a message about opening the editor' do
      result = command.execute('describe')

      expect(result[:message]).to include('Opening description editor')
    end

    it 'works with the desc alias' do
      result = command.execute('desc')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:open_gui)
    end
  end
end
