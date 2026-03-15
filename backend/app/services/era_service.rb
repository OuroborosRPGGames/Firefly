# frozen_string_literal: true

# EraService provides centralized configuration for era-based game mechanics.
# The game's `time_period` setting determines which era is active, affecting
# currency, messaging, travel, and phone systems.
#
# Eras:
#   - medieval: Gold/Silver currency, messenger system, no phones, no taxis
#   - gaslight: Pounds/Pence, telegram system, landlines, carriage taxis
#   - modern: Dollars/Cents, phone DMs (visible), mobile phones, rideshare
#   - near_future: Ecoin (digital only), phone DMs (hidden), implants, autocabs
#   - scifi: Credits (digital only), communicators, hovertaxis
class EraService
  ERAS = %i[medieval gaslight modern near_future scifi].freeze

  ERA_CONFIGS = {
    medieval: {
      currency: {
        name: 'Gold',
        subunit: 'Silver',
        symbol: 'g',
        subunit_symbol: 's',
        subunit_ratio: 100, # 100 silver = 1 gold
        decimal_places: 0,
        digital_allowed: false,
        digital_only: false
      },
      banking: {
        atm_available: false,
        digital_transfers: false,
        physical_only: true,
        bank_required_for_large: false
      },
      messaging: {
        type: :messenger,
        range: :local_area,
        delayed: true,
        courier_visible: true,
        private_mode_blocks: true,
        requires_phone: false,
        requires_device: false,
        visible_use: false,
        pending_offline: false
      },
      travel: {
        taxi_available: false,
        taxi_type: nil,
        vehicle_types: %i[horse carriage cart wagon]
      },
      phones: {
        available: false,
        type: nil,
        room_locked: false,
        portable: false,
        always_available: false
      }
    },

    gaslight: {
      currency: {
        name: 'Pound',
        subunit: 'Pence',
        symbol: '£',
        subunit_symbol: 'd',
        subunit_ratio: 240, # 240 pence = 1 pound (pre-decimal)
        decimal_places: 2,
        digital_allowed: false,
        digital_only: false
      },
      banking: {
        atm_available: false,
        digital_transfers: false,
        physical_only: true,
        bank_required_for_large: true,
        large_purchase_threshold: 100 # Pounds
      },
      messaging: {
        type: :telegram,
        range: :world,
        delayed: true,
        courier_visible: true,
        private_mode_blocks: true,
        requires_phone: false,
        requires_device: false,
        visible_use: false,
        pending_offline: false
      },
      travel: {
        taxi_available: true,
        taxi_type: :carriage,
        taxi_name: 'hansom cab',
        vehicle_types: %i[horse carriage cart wagon bicycle]
      },
      phones: {
        available: true,
        type: :landline,
        room_locked: true,
        portable: false,
        always_available: false
      }
    },

    modern: {
      currency: {
        name: 'Dollar',
        subunit: 'Cent',
        symbol: '$',
        subunit_symbol: 'c',
        subunit_ratio: 100,
        decimal_places: 2,
        digital_allowed: true,
        digital_only: false
      },
      banking: {
        atm_available: true,
        digital_transfers: true,
        physical_only: false,
        bank_required_for_large: false
      },
      messaging: {
        type: :phone_dm,
        range: :global,
        delayed: false,
        courier_visible: false,
        private_mode_blocks: false,
        requires_phone: true,
        requires_device: false,
        visible_use: true,
        pending_offline: true
      },
      travel: {
        taxi_available: true,
        taxi_type: :rideshare,
        taxi_name: 'ride',
        vehicle_types: %i[car motorcycle bicycle scooter bus train subway]
      },
      phones: {
        available: true,
        type: :mobile,
        room_locked: false,
        portable: true,
        always_available: false
      }
    },

    near_future: {
      currency: {
        name: 'Ecoin',
        subunit: nil,
        symbol: 'E',
        subunit_symbol: nil,
        subunit_ratio: nil,
        decimal_places: 2,
        digital_allowed: true,
        digital_only: true
      },
      banking: {
        atm_available: true,
        digital_transfers: true,
        physical_only: false,
        bank_required_for_large: false
      },
      messaging: {
        type: :phone_dm,
        range: :global,
        delayed: false,
        courier_visible: false,
        private_mode_blocks: false,
        requires_phone: true,
        requires_device: false,
        visible_use: false, # Neural interface - no visible phone use
        pending_offline: true
      },
      travel: {
        taxi_available: true,
        taxi_type: :autocab,
        taxi_name: 'autocab',
        vehicle_types: %i[car motorcycle hoverbike maglev drone_taxi]
      },
      phones: {
        available: true,
        type: :implant,
        room_locked: false,
        portable: true,
        always_available: true # Neural implant - always connected
      }
    },

    scifi: {
      currency: {
        name: 'Credit',
        subunit: nil,
        symbol: 'CR',
        subunit_symbol: nil,
        subunit_ratio: nil,
        decimal_places: 0,
        digital_allowed: true,
        digital_only: true
      },
      banking: {
        atm_available: true,
        digital_transfers: true,
        physical_only: false,
        bank_required_for_large: false
      },
      messaging: {
        type: :communicator,
        range: :global,
        delayed: false,
        courier_visible: false,
        private_mode_blocks: false,
        requires_phone: false,
        requires_device: true,
        visible_use: false,
        pending_offline: true
      },
      travel: {
        taxi_available: true,
        taxi_type: :hovertaxi,
        taxi_name: 'hover taxi',
        vehicle_types: %i[hovercar hoverbike shuttle spacecraft teleporter]
      },
      phones: {
        available: true,
        type: :communicator,
        room_locked: false,
        portable: true,
        always_available: true
      }
    }
  }.freeze

  class << self
    # Get the current era from game settings
    # @return [Symbol] the current era (:medieval, :gaslight, :modern, :near_future, :scifi)
    def current_era
      era = GameSetting.get('time_period')
      era_sym = era&.to_sym
      ERAS.include?(era_sym) ? era_sym : :modern
    end

    # Get the full configuration for the current era
    # @return [Hash] the era configuration
    def config
      ERA_CONFIGS[current_era] || ERA_CONFIGS[:modern]
    end

    # Configuration section accessors
    def currency_config
      config[:currency]
    end

    def banking_config
      config[:banking]
    end

    def messaging_config
      config[:messaging]
    end

    def travel_config
      config[:travel]
    end

    def phone_config
      config[:phones]
    end

    # Era predicate methods
    def medieval?
      current_era == :medieval
    end

    def gaslight?
      current_era == :gaslight
    end

    def modern?
      current_era == :modern
    end

    def near_future?
      current_era == :near_future
    end

    def scifi?
      current_era == :scifi
    end

    # Feature availability checks

    # @return [Boolean] whether phones/communicators are available in this era
    def phones_available?
      phone_config[:available]
    end

    # @return [Boolean] whether digital currency/transfers are allowed
    def digital_currency?
      currency_config[:digital_allowed]
    end

    # @return [Boolean] whether cash is required (no digital)
    def cash_only?
      !digital_currency?
    end

    # @return [Boolean] whether only digital currency exists (no cash)
    def digital_only?
      currency_config[:digital_only]
    end

    # @return [Boolean] whether taxi service is available
    def taxi_available?
      travel_config[:taxi_available]
    end

    # @return [Boolean] whether ATMs exist
    def atm_available?
      banking_config[:atm_available]
    end

    # @return [Boolean] whether digital bank transfers are possible
    def digital_transfers?
      banking_config[:digital_transfers]
    end

    # @return [Boolean] whether a phone is required to send DMs
    def requires_phone_for_dm?
      messaging_config[:requires_phone] || messaging_config[:requires_device]
    end

    # @return [Boolean] whether messaging has delayed delivery (courier/telegram)
    def delayed_messaging?
      messaging_config[:delayed]
    end

    # @return [Boolean] whether phone use is visible to others in the room
    def visible_phone_use?
      messaging_config[:visible_use]
    end

    # @return [Boolean] whether messages wait if recipient is offline
    def pending_offline_messages?
      messaging_config[:pending_offline]
    end

    # @return [Boolean] whether users always have communication access (implants, etc.)
    def always_connected?
      phone_config[:always_available]
    end

    # @return [Boolean] whether phones are locked to specific rooms (landlines)
    def phones_room_locked?
      phone_config[:room_locked]
    end

    # Currency helpers

    # @return [String] the currency name for display
    def currency_name
      currency_config[:name]
    end

    # @return [String] the currency symbol
    def currency_symbol
      currency_config[:symbol]
    end

    # @return [String, nil] the subunit name (e.g., 'Cent', 'Silver')
    def subunit_name
      currency_config[:subunit]
    end

    # Format an amount using era-appropriate currency
    # @param amount [Numeric] the amount to format
    # @return [String] formatted currency string
    def format_currency(amount)
      config = currency_config
      symbol = config[:symbol]
      decimals = config[:decimal_places]

      if decimals > 0
        "#{symbol}#{'%.2f' % amount}"
      else
        "#{symbol}#{amount.to_i}"
      end
    end

    # Taxi/travel helpers

    # @return [Symbol, nil] the type of taxi (:carriage, :rideshare, :autocab, :hovertaxi)
    def taxi_type
      travel_config[:taxi_type]
    end

    # @return [String] human-readable taxi name
    def taxi_name
      travel_config[:taxi_name] || 'taxi'
    end

    # @return [Array<Symbol>] available vehicle types for this era
    def available_vehicle_types
      travel_config[:vehicle_types]
    end

    # @param vehicle_type [Symbol, String] the vehicle type to check
    # @return [Boolean] whether this vehicle type exists in the current era
    def vehicle_available?(vehicle_type)
      available_vehicle_types.include?(vehicle_type.to_sym)
    end

    # Messaging helpers

    # @return [Symbol] the messaging system type (:messenger, :telegram, :phone_dm, :communicator)
    def messaging_type
      messaging_config[:type]
    end

    # @return [Symbol] the messaging range (:local_area, :world, :global)
    def messaging_range
      messaging_config[:range]
    end

    # Phone helpers

    # @return [Symbol, nil] the phone type (:landline, :mobile, :implant, :communicator)
    def phone_type
      phone_config[:type]
    end

    # Get era-appropriate terminology for the messaging device
    # @return [String] the device name (e.g., 'phone', 'communicator', 'messenger')
    def messaging_device_name
      case messaging_type
      when :messenger then 'messenger'
      when :telegram then 'telegram'
      when :phone_dm then 'phone'
      when :communicator then 'communicator'
      else 'device'
      end
    end

    # Banking helpers

    # @param amount [Numeric] the purchase amount
    # @return [Boolean] whether this is considered a "large" purchase requiring bank
    def requires_bank_for_purchase?(amount)
      return false unless banking_config[:bank_required_for_large]

      threshold = banking_config[:large_purchase_threshold] || 100
      amount >= threshold
    end
  end
end
