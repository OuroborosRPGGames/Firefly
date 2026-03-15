# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe EraService do
  # Helper to set the era via GameSetting
  def set_era(era)
    GameSetting.set('time_period', era.to_s, type: 'string')
  end

  describe '.current_era' do
    context 'when no time_period is set' do
      it 'defaults to :modern' do
        expect(described_class.current_era).to eq(:modern)
      end
    end

    context 'when time_period is set to a valid era' do
      EraService::ERAS.each do |era|
        it "returns :#{era} when set to #{era}" do
          set_era(era)
          expect(described_class.current_era).to eq(era)
        end
      end
    end

    context 'when time_period is set to an invalid value' do
      it 'defaults to :modern' do
        set_era('invalid_era')
        expect(described_class.current_era).to eq(:modern)
      end
    end
  end

  describe 'era predicate methods' do
    EraService::ERAS.each do |era|
      describe ".#{era}?" do
        it "returns true when era is #{era}" do
          set_era(era)
          expect(described_class.send("#{era}?")).to be true
        end

        it "returns false when era is not #{era}" do
          other_era = (EraService::ERAS - [era]).first
          set_era(other_era)
          expect(described_class.send("#{era}?")).to be false
        end
      end
    end
  end

  describe 'configuration accessors' do
    before { set_era(:modern) }

    describe '.config' do
      it 'returns the full era configuration hash' do
        expect(described_class.config).to be_a(Hash)
        expect(described_class.config.keys).to include(:currency, :banking, :messaging, :travel, :phones)
      end
    end

    describe '.currency_config' do
      it 'returns currency configuration' do
        expect(described_class.currency_config[:name]).to eq('Dollar')
        expect(described_class.currency_config[:symbol]).to eq('$')
      end
    end

    describe '.banking_config' do
      it 'returns banking configuration' do
        expect(described_class.banking_config[:atm_available]).to be true
      end
    end

    describe '.messaging_config' do
      it 'returns messaging configuration' do
        expect(described_class.messaging_config[:type]).to eq(:phone_dm)
      end
    end

    describe '.travel_config' do
      it 'returns travel configuration' do
        expect(described_class.travel_config[:taxi_available]).to be true
      end
    end

    describe '.phone_config' do
      it 'returns phone configuration' do
        expect(described_class.phone_config[:available]).to be true
      end
    end
  end

  describe 'currency features' do
    describe '.digital_currency?' do
      it 'returns false for medieval era' do
        set_era(:medieval)
        expect(described_class.digital_currency?).to be false
      end

      it 'returns false for gaslight era' do
        set_era(:gaslight)
        expect(described_class.digital_currency?).to be false
      end

      it 'returns true for modern era' do
        set_era(:modern)
        expect(described_class.digital_currency?).to be true
      end

      it 'returns true for near_future era' do
        set_era(:near_future)
        expect(described_class.digital_currency?).to be true
      end

      it 'returns true for scifi era' do
        set_era(:scifi)
        expect(described_class.digital_currency?).to be true
      end
    end

    describe '.cash_only?' do
      it 'returns true for medieval era' do
        set_era(:medieval)
        expect(described_class.cash_only?).to be true
      end

      it 'returns false for modern era' do
        set_era(:modern)
        expect(described_class.cash_only?).to be false
      end
    end

    describe '.digital_only?' do
      it 'returns false for modern era' do
        set_era(:modern)
        expect(described_class.digital_only?).to be false
      end

      it 'returns true for near_future era' do
        set_era(:near_future)
        expect(described_class.digital_only?).to be true
      end

      it 'returns true for scifi era' do
        set_era(:scifi)
        expect(described_class.digital_only?).to be true
      end
    end

    describe '.format_currency' do
      it 'formats medieval currency without decimals' do
        set_era(:medieval)
        expect(described_class.format_currency(100)).to eq('g100')
      end

      it 'formats modern currency with decimals' do
        set_era(:modern)
        expect(described_class.format_currency(100.5)).to eq('$100.50')
      end

      it 'formats scifi currency without decimals' do
        set_era(:scifi)
        expect(described_class.format_currency(100)).to eq('CR100')
      end
    end

    describe '.currency_name' do
      it 'returns Gold for medieval' do
        set_era(:medieval)
        expect(described_class.currency_name).to eq('Gold')
      end

      it 'returns Dollar for modern' do
        set_era(:modern)
        expect(described_class.currency_name).to eq('Dollar')
      end
    end
  end

  describe 'phone features' do
    describe '.phones_available?' do
      it 'returns false for medieval era' do
        set_era(:medieval)
        expect(described_class.phones_available?).to be false
      end

      it 'returns true for gaslight era (landlines)' do
        set_era(:gaslight)
        expect(described_class.phones_available?).to be true
      end

      it 'returns true for modern era' do
        set_era(:modern)
        expect(described_class.phones_available?).to be true
      end
    end

    describe '.phones_room_locked?' do
      it 'returns true for gaslight era (landlines)' do
        set_era(:gaslight)
        expect(described_class.phones_room_locked?).to be true
      end

      it 'returns false for modern era (mobile)' do
        set_era(:modern)
        expect(described_class.phones_room_locked?).to be false
      end
    end

    describe '.always_connected?' do
      it 'returns false for modern era' do
        set_era(:modern)
        expect(described_class.always_connected?).to be false
      end

      it 'returns true for near_future era (implants)' do
        set_era(:near_future)
        expect(described_class.always_connected?).to be true
      end

      it 'returns true for scifi era (communicators)' do
        set_era(:scifi)
        expect(described_class.always_connected?).to be true
      end
    end

    describe '.phone_type' do
      it 'returns nil for medieval era' do
        set_era(:medieval)
        expect(described_class.phone_type).to be_nil
      end

      it 'returns :landline for gaslight era' do
        set_era(:gaslight)
        expect(described_class.phone_type).to eq(:landline)
      end

      it 'returns :mobile for modern era' do
        set_era(:modern)
        expect(described_class.phone_type).to eq(:mobile)
      end

      it 'returns :implant for near_future era' do
        set_era(:near_future)
        expect(described_class.phone_type).to eq(:implant)
      end

      it 'returns :communicator for scifi era' do
        set_era(:scifi)
        expect(described_class.phone_type).to eq(:communicator)
      end
    end
  end

  describe 'messaging features' do
    describe '.requires_phone_for_dm?' do
      it 'returns false for medieval era' do
        set_era(:medieval)
        expect(described_class.requires_phone_for_dm?).to be false
      end

      it 'returns false for gaslight era (telegram)' do
        set_era(:gaslight)
        expect(described_class.requires_phone_for_dm?).to be false
      end

      it 'returns true for modern era' do
        set_era(:modern)
        expect(described_class.requires_phone_for_dm?).to be true
      end

      it 'returns true for scifi era (requires device)' do
        set_era(:scifi)
        expect(described_class.requires_phone_for_dm?).to be true
      end
    end

    describe '.delayed_messaging?' do
      it 'returns true for medieval era' do
        set_era(:medieval)
        expect(described_class.delayed_messaging?).to be true
      end

      it 'returns true for gaslight era' do
        set_era(:gaslight)
        expect(described_class.delayed_messaging?).to be true
      end

      it 'returns false for modern era' do
        set_era(:modern)
        expect(described_class.delayed_messaging?).to be false
      end
    end

    describe '.visible_phone_use?' do
      it 'returns true for modern era' do
        set_era(:modern)
        expect(described_class.visible_phone_use?).to be true
      end

      it 'returns false for near_future era' do
        set_era(:near_future)
        expect(described_class.visible_phone_use?).to be false
      end
    end

    describe '.messaging_type' do
      it 'returns :messenger for medieval era' do
        set_era(:medieval)
        expect(described_class.messaging_type).to eq(:messenger)
      end

      it 'returns :telegram for gaslight era' do
        set_era(:gaslight)
        expect(described_class.messaging_type).to eq(:telegram)
      end

      it 'returns :phone_dm for modern era' do
        set_era(:modern)
        expect(described_class.messaging_type).to eq(:phone_dm)
      end

      it 'returns :communicator for scifi era' do
        set_era(:scifi)
        expect(described_class.messaging_type).to eq(:communicator)
      end
    end

    describe '.messaging_device_name' do
      it 'returns messenger for medieval era' do
        set_era(:medieval)
        expect(described_class.messaging_device_name).to eq('messenger')
      end

      it 'returns telegram for gaslight era' do
        set_era(:gaslight)
        expect(described_class.messaging_device_name).to eq('telegram')
      end

      it 'returns phone for modern era' do
        set_era(:modern)
        expect(described_class.messaging_device_name).to eq('phone')
      end

      it 'returns communicator for scifi era' do
        set_era(:scifi)
        expect(described_class.messaging_device_name).to eq('communicator')
      end
    end
  end

  describe 'travel/taxi features' do
    describe '.taxi_available?' do
      it 'returns false for medieval era' do
        set_era(:medieval)
        expect(described_class.taxi_available?).to be false
      end

      it 'returns true for gaslight era' do
        set_era(:gaslight)
        expect(described_class.taxi_available?).to be true
      end

      it 'returns true for modern era' do
        set_era(:modern)
        expect(described_class.taxi_available?).to be true
      end
    end

    describe '.taxi_type' do
      it 'returns nil for medieval era' do
        set_era(:medieval)
        expect(described_class.taxi_type).to be_nil
      end

      it 'returns :carriage for gaslight era' do
        set_era(:gaslight)
        expect(described_class.taxi_type).to eq(:carriage)
      end

      it 'returns :rideshare for modern era' do
        set_era(:modern)
        expect(described_class.taxi_type).to eq(:rideshare)
      end

      it 'returns :autocab for near_future era' do
        set_era(:near_future)
        expect(described_class.taxi_type).to eq(:autocab)
      end

      it 'returns :hovertaxi for scifi era' do
        set_era(:scifi)
        expect(described_class.taxi_type).to eq(:hovertaxi)
      end
    end

    describe '.taxi_name' do
      it 'returns hansom cab for gaslight era' do
        set_era(:gaslight)
        expect(described_class.taxi_name).to eq('hansom cab')
      end

      it 'returns ride for modern era' do
        set_era(:modern)
        expect(described_class.taxi_name).to eq('ride')
      end

      it 'returns autocab for near_future era' do
        set_era(:near_future)
        expect(described_class.taxi_name).to eq('autocab')
      end

      it 'returns hover taxi for scifi era' do
        set_era(:scifi)
        expect(described_class.taxi_name).to eq('hover taxi')
      end
    end

    describe '.available_vehicle_types' do
      it 'includes horse for medieval era' do
        set_era(:medieval)
        expect(described_class.available_vehicle_types).to include(:horse)
      end

      it 'includes car for modern era' do
        set_era(:modern)
        expect(described_class.available_vehicle_types).to include(:car)
      end

      it 'includes hovercar for scifi era' do
        set_era(:scifi)
        expect(described_class.available_vehicle_types).to include(:hovercar)
      end
    end

    describe '.vehicle_available?' do
      it 'returns true for horse in medieval era' do
        set_era(:medieval)
        expect(described_class.vehicle_available?(:horse)).to be true
      end

      it 'returns false for car in medieval era' do
        set_era(:medieval)
        expect(described_class.vehicle_available?(:car)).to be false
      end

      it 'returns true for car in modern era' do
        set_era(:modern)
        expect(described_class.vehicle_available?(:car)).to be true
      end
    end
  end

  describe 'banking features' do
    describe '.atm_available?' do
      it 'returns false for medieval era' do
        set_era(:medieval)
        expect(described_class.atm_available?).to be false
      end

      it 'returns false for gaslight era' do
        set_era(:gaslight)
        expect(described_class.atm_available?).to be false
      end

      it 'returns true for modern era' do
        set_era(:modern)
        expect(described_class.atm_available?).to be true
      end
    end

    describe '.digital_transfers?' do
      it 'returns false for medieval era' do
        set_era(:medieval)
        expect(described_class.digital_transfers?).to be false
      end

      it 'returns true for modern era' do
        set_era(:modern)
        expect(described_class.digital_transfers?).to be true
      end
    end

    describe '.requires_bank_for_purchase?' do
      it 'returns false for medieval era regardless of amount' do
        set_era(:medieval)
        expect(described_class.requires_bank_for_purchase?(1000)).to be false
      end

      it 'returns true for gaslight era for large purchases' do
        set_era(:gaslight)
        expect(described_class.requires_bank_for_purchase?(100)).to be true
        expect(described_class.requires_bank_for_purchase?(50)).to be false
      end

      it 'returns false for modern era regardless of amount' do
        set_era(:modern)
        expect(described_class.requires_bank_for_purchase?(1000)).to be false
      end
    end
  end
end
