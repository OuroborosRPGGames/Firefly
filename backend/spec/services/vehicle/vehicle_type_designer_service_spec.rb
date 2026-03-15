# frozen_string_literal: true

require 'spec_helper'

RSpec.describe VehicleTypeDesignerService do
  describe '.create' do
    let(:params) do
      {
        'name' => 'Sports Car',
        'category' => 'ground',
        'description' => 'A fast two-seater',
        'max_passengers' => '2',
        'cargo_capacity' => '50',
        'base_speed' => '1.5',
        'requires_fuel' => 'true'
      }
    end

    let(:vehicle_type) { double('VehicleType', id: 1, errors: double(full_messages: [])) }

    before do
      allow(VehicleType).to receive(:new).and_return(vehicle_type)
      allow(vehicle_type).to receive(:valid?).and_return(true)
      allow(vehicle_type).to receive(:save)
    end

    context 'with valid params' do
      it 'creates a vehicle type with extracted params' do
        expect(VehicleType).to receive(:new).with(
          hash_including(
            name: 'Sports Car',
            category: 'ground',
            description: 'A fast two-seater',
            max_passengers: 2
          )
        )

        described_class.create(params)
      end

      it 'returns success with vehicle_type' do
        result = described_class.create(params)

        expect(result[:success]).to be true
        expect(result[:vehicle_type]).to eq(vehicle_type)
      end

      it 'converts numeric params' do
        expect(VehicleType).to receive(:new).with(
          hash_including(
            max_passengers: 2,
            cargo_capacity: 50,
            base_speed: 1.5
          )
        )

        described_class.create(params)
      end

      it 'converts boolean params' do
        expect(VehicleType).to receive(:new).with(
          hash_including(requires_fuel: true)
        )

        described_class.create(params)
      end

      it 'strips whitespace from name and description' do
        params['name'] = '  Trimmed Name  '
        params['description'] = '  Trimmed Desc  '

        expect(VehicleType).to receive(:new).with(
          hash_including(
            name: 'Trimmed Name',
            description: 'Trimmed Desc'
          )
        )

        described_class.create(params)
      end
    end

    context 'with nested vehicle_type params' do
      let(:nested_params) do
        {
          'vehicle_type' => {
            'name' => 'Nested Vehicle',
            'category' => 'air'
          }
        }
      end

      it 'extracts from nested hash' do
        expect(VehicleType).to receive(:new).with(
          hash_including(name: 'Nested Vehicle', category: 'air')
        )

        described_class.create(nested_params)
      end
    end

    context 'when invalid' do
      before do
        allow(vehicle_type).to receive(:valid?).and_return(false)
        allow(vehicle_type).to receive(:errors).and_return(double(full_messages: ['Name is required']))
      end

      it 'returns error' do
        result = described_class.create(params)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Name is required')
      end
    end

    context 'when validation raises exception' do
      before do
        allow(VehicleType).to receive(:new).and_raise(Sequel::ValidationFailed, 'Validation failed')
      end

      it 'returns error' do
        result = described_class.create(params)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Validation failed')
      end
    end

    context 'when unexpected error occurs' do
      before do
        allow(VehicleType).to receive(:new).and_raise(StandardError, 'Database error')
      end

      it 'returns error with message' do
        result = described_class.create(params)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to create vehicle type: Database error')
      end
    end

    context 'with default values' do
      let(:minimal_params) { { 'name' => 'Basic Car' } }

      it 'uses default category' do
        expect(VehicleType).to receive(:new).with(
          hash_including(category: 'ground')
        )

        described_class.create(minimal_params)
      end

      it 'uses default max_passengers' do
        expect(VehicleType).to receive(:new).with(
          hash_including(max_passengers: 4)
        )

        described_class.create(minimal_params)
      end

      it 'uses default cargo_capacity' do
        expect(VehicleType).to receive(:new).with(
          hash_including(cargo_capacity: 100)
        )

        described_class.create(minimal_params)
      end

      it 'uses default base_speed' do
        expect(VehicleType).to receive(:new).with(
          hash_including(base_speed: 1.0)
        )

        described_class.create(minimal_params)
      end
    end

    context 'with JSON properties' do
      let(:params_with_json) do
        {
          'name' => 'Custom Car',
          'properties' => '{"color": "red", "wheels": 4}'
        }
      end

      it 'parses JSON properties' do
        expect(VehicleType).to receive(:new).with(
          hash_including(
            properties: { 'color' => 'red', 'wheels' => 4 }
          )
        )

        described_class.create(params_with_json)
      end
    end

    context 'with invalid JSON properties' do
      let(:params_with_invalid_json) do
        {
          'name' => 'Car',
          'properties' => 'not valid json'
        }
      end

      it 'ignores invalid JSON' do
        # Should not raise, just ignore the invalid JSON
        result = described_class.create(params_with_invalid_json)

        expect(result[:success]).to be true
      end
    end

    context 'with hash properties' do
      let(:params_with_hash) do
        {
          'name' => 'Car',
          'properties' => { 'engine' => 'v8' }
        }
      end

      it 'uses hash directly' do
        expect(VehicleType).to receive(:new).with(
          hash_including(
            properties: { 'engine' => 'v8' }
          )
        )

        described_class.create(params_with_hash)
      end
    end

    context 'with individual property fields' do
      let(:params_with_property_fields) do
        {
          'name' => 'Convertible',
          'convertible' => 'true',
          'short_desc_template' => 'A sleek {color} convertible',
          'in_desc_template' => 'Inside the car',
          'out_desc_template' => 'Outside the car'
        }
      end

      it 'extracts property fields into properties hash' do
        expect(VehicleType).to receive(:new).with(
          hash_including(
            properties: {
              'convertible' => true,
              'short_desc_template' => 'A sleek {color} convertible',
              'in_desc_template' => 'Inside the car',
              'out_desc_template' => 'Outside the car'
            }
          )
        )

        described_class.create(params_with_property_fields)
      end
    end

    context 'with universe_id' do
      it 'converts universe_id to integer' do
        params['universe_id'] = '5'

        expect(VehicleType).to receive(:new).with(
          hash_including(universe_id: 5)
        )

        described_class.create(params)
      end

      it 'handles empty universe_id' do
        params['universe_id'] = ''

        expect(VehicleType).to receive(:new).with(
          hash_not_including(:universe_id)
        )

        described_class.create(params)
      end
    end
  end

  describe '.update' do
    let(:vehicle_type) { double('VehicleType', id: 1) }
    let(:params) do
      {
        'name' => 'Updated Name',
        'description' => 'Updated description'
      }
    end

    before do
      allow(vehicle_type).to receive(:update)
    end

    context 'with valid update' do
      it 'updates vehicle_type' do
        expect(vehicle_type).to receive(:update).with(
          hash_including(name: 'Updated Name', description: 'Updated description')
        )

        described_class.update(vehicle_type, params)
      end

      it 'returns success' do
        result = described_class.update(vehicle_type, params)

        expect(result[:success]).to be true
        expect(result[:vehicle_type]).to eq(vehicle_type)
      end
    end

    context 'when validation fails' do
      before do
        allow(vehicle_type).to receive(:update).and_raise(Sequel::ValidationFailed, 'Name too short')
      end

      it 'returns error' do
        result = described_class.update(vehicle_type, params)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Name too short')
      end
    end

    context 'when unexpected error occurs' do
      before do
        allow(vehicle_type).to receive(:update).and_raise(StandardError, 'Connection lost')
      end

      it 'returns error' do
        result = described_class.update(vehicle_type, params)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to update vehicle type: Connection lost')
      end
    end
  end

  describe '.delete' do
    let(:vehicle_type) { double('VehicleType', id: 1) }
    let(:vehicles_dataset) { double('Dataset') }

    before do
      allow(vehicle_type).to receive(:vehicles).and_return(vehicles_dataset)
      allow(vehicle_type).to receive(:destroy)
    end

    context 'when no vehicles use this type' do
      before do
        allow(vehicles_dataset).to receive(:any?).and_return(false)
      end

      it 'destroys vehicle_type' do
        expect(vehicle_type).to receive(:destroy)

        described_class.delete(vehicle_type)
      end

      it 'returns success' do
        result = described_class.delete(vehicle_type)

        expect(result[:success]).to be true
      end
    end

    context 'when vehicles use this type' do
      before do
        allow(vehicles_dataset).to receive(:any?).and_return(true)
      end

      it 'does not destroy vehicle_type' do
        expect(vehicle_type).not_to receive(:destroy)

        described_class.delete(vehicle_type)
      end

      it 'returns error' do
        result = described_class.delete(vehicle_type)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Cannot delete vehicle type with existing vehicles')
      end
    end

    context 'when destroy fails' do
      before do
        allow(vehicles_dataset).to receive(:any?).and_return(false)
        allow(vehicle_type).to receive(:destroy).and_raise(StandardError, 'Foreign key constraint')
      end

      it 'returns error' do
        result = described_class.delete(vehicle_type)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to delete vehicle type: Foreign key constraint')
      end
    end
  end

  describe '.spawn_vehicle' do
    let(:vehicle_type) do
      double('VehicleType',
        id: 1,
        name: 'Sedan',
        max_passengers: 4,
        properties: {
          'convertible' => false,
          'short_desc_template' => 'A gray sedan',
          'in_desc_template' => 'Inside the sedan',
          'out_desc_template' => 'A parked sedan'
        }
      )
    end

    let(:vehicle) { double('Vehicle', id: 10) }

    before do
      allow(Vehicle).to receive(:create).and_return(vehicle)
    end

    it 'creates a vehicle from the type' do
      expect(Vehicle).to receive(:create).with(
        hash_including(
          vehicle_type_id: 1,
          vtype: 'Sedan',
          max_passengers: 4,
          condition: 100,
          parked: true
        )
      )

      described_class.spawn_vehicle(vehicle_type)
    end

    it 'uses options for owner and room' do
      expect(Vehicle).to receive(:create).with(
        hash_including(
          char_id: 42,
          room_id: 123
        )
      )

      described_class.spawn_vehicle(vehicle_type, owner_id: 42, room_id: 123)
    end

    it 'uses property templates for descriptions' do
      expect(Vehicle).to receive(:create).with(
        hash_including(
          short_desc: 'A gray sedan',
          in_desc: 'Inside the sedan',
          out_desc: 'A parked sedan'
        )
      )

      described_class.spawn_vehicle(vehicle_type)
    end

    it 'allows custom descriptions' do
      expect(Vehicle).to receive(:create).with(
        hash_including(
          short_desc: 'Custom short',
          in_desc: 'Custom in',
          out_desc: 'Custom out'
        )
      )

      described_class.spawn_vehicle(vehicle_type,
        short_desc: 'Custom short',
        in_desc: 'Custom in',
        out_desc: 'Custom out'
      )
    end

    it 'extracts convertible from properties' do
      expect(Vehicle).to receive(:create).with(
        hash_including(convertible: false)
      )

      described_class.spawn_vehicle(vehicle_type)
    end

    context 'with nil properties' do
      let(:vehicle_type_no_props) do
        double('VehicleType',
          id: 2,
          name: 'Basic',
          max_passengers: nil,
          properties: nil
        )
      end

      it 'uses defaults for nil values' do
        expect(Vehicle).to receive(:create).with(
          hash_including(
            max_passengers: 4,
            convertible: false,
            short_desc: nil,
            in_desc: nil,
            out_desc: nil
          )
        )

        described_class.spawn_vehicle(vehicle_type_no_props)
      end
    end
  end
end
