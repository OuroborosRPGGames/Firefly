# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldJourneyPassenger do
  let(:world) { create(:world) }
  let(:world_journey) { create(:world_journey, world: world) }
  let(:character_instance) { create(:character_instance) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      passenger = described_class.create(
        world_journey: world_journey,
        character_instance: character_instance
      )
      expect(passenger).to be_valid
    end

    it 'requires world_journey_id' do
      passenger = described_class.new(character_instance: character_instance)
      expect(passenger).not_to be_valid
    end

    it 'requires character_instance_id' do
      passenger = described_class.new(world_journey: world_journey)
      expect(passenger).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to world_journey' do
      passenger = create(:world_journey_passenger, world_journey: world_journey, character_instance: character_instance)
      expect(passenger.world_journey).to eq(world_journey)
    end

    it 'belongs to character_instance' do
      passenger = create(:world_journey_passenger, world_journey: world_journey, character_instance: character_instance)
      expect(passenger.character_instance).to eq(character_instance)
    end
  end

  describe '.board!' do
    it 'creates a new passenger record' do
      passenger = described_class.board!(world_journey, character_instance)
      expect(passenger.id).not_to be_nil
      expect(passenger.world_journey_id).to eq(world_journey.id)
      expect(passenger.character_instance_id).to eq(character_instance.id)
    end

    it 'sets boarded_at to current time' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      passenger = described_class.board!(world_journey, character_instance)
      expect(passenger.boarded_at).to be_within(1).of(freeze_time)
    end

    it 'can set is_driver flag' do
      passenger = described_class.board!(world_journey, character_instance, is_driver: true)
      expect(passenger.is_driver).to be true
    end

    it 'returns existing passenger if already on journey' do
      first_passenger = described_class.board!(world_journey, character_instance)
      second_passenger = described_class.board!(world_journey, character_instance)
      expect(second_passenger.id).to eq(first_passenger.id)
    end

    it 'updates character_instance with journey reference' do
      described_class.board!(world_journey, character_instance)
      expect(character_instance.reload.current_world_journey_id).to eq(world_journey.id)
    end
  end

  describe '#disembark!' do
    let!(:passenger) { described_class.board!(world_journey, character_instance) }

    it 'destroys the passenger record' do
      passenger_id = passenger.id
      passenger.disembark!
      expect(described_class[passenger_id]).to be_nil
    end

    it 'clears character_instance journey reference' do
      passenger.disembark!
      expect(character_instance.reload.current_world_journey_id).to be_nil
    end
  end

  describe '#character_name' do
    it 'returns the character full name' do
      passenger = create(:world_journey_passenger, world_journey: world_journey, character_instance: character_instance)
      expect(passenger.character_name).to eq(character_instance.full_name)
    end

    it 'returns Unknown if character_instance is nil' do
      passenger = described_class.new
      expect(passenger.character_name).to eq('Unknown')
    end
  end

  describe 'traits' do
    it 'creates driver passenger' do
      passenger = create(:world_journey_passenger, :driver, world_journey: world_journey, character_instance: character_instance)
      expect(passenger.is_driver).to be true
    end
  end
end
