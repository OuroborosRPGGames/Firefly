# frozen_string_literal: true

# Generates wound descriptions based on damage type and severity.
# Uses D&D-style damage types (slashing, piercing, bludgeoning, etc.)
# with severity tiers based on HP lost.
#
# @example
#   service = CombatWoundDescriptionService.new
#   service.describe_wound(hp_lost: 3, damage_type: 'slashing')
#   # => "a deep gash"
#
class CombatWoundDescriptionService
  # Wound severity tiers based on HP lost
  SEVERITY_THRESHOLDS = {
    light: 1,      # 1 HP
    moderate: 2,   # 2 HP
    serious: 3,    # 3 HP
    critical: 4    # 4+ HP
  }.freeze

  # Wound strings organized by damage type and severity
  WOUND_STRINGS = {
    # Physical damage types
    slashing: {
      light: ['a shallow cut', 'a nick', 'a scratch', 'a light slash'],
      moderate: ['a bleeding cut', 'a nasty gash', 'a painful slash', 'a deep nick'],
      serious: ['a deep gash', 'a bleeding wound', 'a vicious slash', 'a grievous cut'],
      critical: ['a devastating slash', 'a horrific wound', 'a mortal gash', 'a near-fatal cut']
    },
    piercing: {
      light: ['a shallow puncture', 'a prick', 'a minor stab', 'a light jab'],
      moderate: ['a puncture wound', 'a bleeding stab', 'a solid thrust', 'a painful jab'],
      serious: ['a deep puncture', 'a grievous stab', 'an impaling strike', 'a vicious thrust'],
      critical: ['a devastating thrust', 'a mortal wound', 'a through-and-through', 'a near-fatal stab']
    },
    bludgeoning: {
      light: ['a battering', 'a light bruise', 'a glancing blow', 'a stinging impact'],
      moderate: ['bruising', 'a painful bruise', 'a solid hit', 'a jarring blow'],
      serious: ['severe bruises', 'cracked bones', 'a brutal impact', 'a savage strike'],
      critical: ['broken bones', 'a shattering blow', 'a bone-crushing impact', 'a devastating strike']
    },

    # Elemental damage types
    fire: {
      light: ['minor burns', 'singed skin', 'a flash of heat', 'light scorching'],
      moderate: ['burns', 'scorched flesh', 'blistering heat', 'painful burns'],
      serious: ['severe burns', 'charred flesh', 'searing agony', 'deep burns'],
      critical: ['horrific burns', 'blackened flesh', 'engulfing flames', 'catastrophic burns']
    },
    cold: {
      light: ['mild frostbite', 'chilled skin', 'numbing cold', 'light frost damage'],
      moderate: ['frostbite', 'frozen flesh', 'biting cold', 'painful freezing'],
      serious: ['severe frostbite', 'blackened tissue', 'freezing agony', 'deep cold damage'],
      critical: ['catastrophic frostbite', 'frozen limbs', 'deadly cold', 'tissue death from cold']
    },
    lightning: {
      light: ['a shock', 'tingling nerves', 'static discharge', 'a light jolt'],
      moderate: ['a painful jolt', 'convulsing muscles', 'electric burns', 'a strong shock'],
      serious: ['severe electrocution', 'smoking wounds', 'violent convulsions', 'nerve damage'],
      critical: ['catastrophic electrocution', 'charred nerves', 'cardiac strain', 'devastating shock']
    },
    acid: {
      light: ['mild irritation', 'reddened skin', 'a stinging sensation', 'light chemical burns'],
      moderate: ['acid burns', 'dissolving skin', 'corrosive damage', 'painful chemical burns'],
      serious: ['severe acid burns', 'melting flesh', 'deep corrosion', 'tissue dissolution'],
      critical: ['catastrophic acid damage', 'bone-deep burns', 'horrific dissolution', 'massive tissue loss']
    },
    poison: {
      light: ['mild nausea', 'a queasy feeling', 'slight weakness', 'minor toxicity'],
      moderate: ['painful cramping', 'spreading numbness', 'toxic damage', 'systemic weakness'],
      serious: ['severe poisoning', 'convulsions', 'organ strain', 'dangerous toxicity'],
      critical: ['catastrophic poisoning', 'system failure', 'deadly venom', 'near-fatal toxicity']
    },

    # Other damage types
    psychic: {
      light: ['mental discomfort', 'a splitting headache', 'disorientation', 'mild confusion'],
      moderate: ['searing pain', 'mental anguish', 'psychic trauma', 'intense disorientation'],
      serious: ['overwhelming agony', 'mental breakdown', 'severe psychic damage', 'cognitive damage'],
      critical: ['catastrophic psychic trauma', 'shattered mind', 'near-fatal mental assault', 'ego death']
    },
    radiant: {
      light: ['a warm glow', 'light sensitivity', 'minor holy burn', 'spiritual discomfort'],
      moderate: ['holy burns', 'searing light', 'radiant damage', 'painful purification'],
      serious: ['severe holy burns', 'blinding pain', 'intense radiant damage', 'soul scorching'],
      critical: ['catastrophic radiant damage', 'soul-searing agony', 'devastating holy fire', 'divine wrath']
    },
    necrotic: {
      light: ['life drain', 'weakness', 'minor decay', 'a chill of death'],
      moderate: ['flesh withering', 'energy drain', 'necrotic damage', 'painful decay'],
      serious: ['severe necrosis', 'rotting flesh', 'life force drain', 'deep corruption'],
      critical: ['catastrophic necrosis', 'flesh falling away', 'near-death experience', 'soul damage']
    },

    # Default/generic
    generic: {
      light: ['a minor wound', 'light damage', 'a glancing hit', 'a scratch'],
      moderate: ['a wound', 'solid damage', 'a good hit', 'a painful injury'],
      serious: ['a serious wound', 'heavy damage', 'a grievous injury', 'a bad wound'],
      critical: ['a devastating wound', 'critical damage', 'a mortal injury', 'a near-fatal wound']
    }
  }.freeze

  # Generate a wound description based on damage taken
  #
  # @param hp_lost [Integer] Amount of HP lost
  # @param damage_type [String, Symbol] Type of damage (slashing, fire, etc.)
  # @return [String] Wound description
  def describe_wound(hp_lost:, damage_type: nil)
    severity = severity_for(hp_lost)
    type = normalize_damage_type(damage_type)

    strings = WOUND_STRINGS.dig(type, severity) || WOUND_STRINGS[:generic][severity]
    strings.sample
  end

  # Get severity level for HP lost
  #
  # @param hp_lost [Integer] Amount of HP lost
  # @return [Symbol] Severity level (:light, :moderate, :serious, :critical)
  def severity_for(hp_lost)
    case hp_lost
    when 0..1 then :light
    when 2 then :moderate
    when 3 then :serious
    else :critical
    end
  end

  # Normalize damage type to a known symbol
  #
  # @param damage_type [String, Symbol, nil] Raw damage type
  # @return [Symbol] Normalized damage type
  def normalize_damage_type(damage_type)
    return :generic if damage_type.nil? || damage_type.to_s.empty?

    type = damage_type.to_s.downcase.to_sym

    WOUND_STRINGS.key?(type) ? type : :generic
  end

  # Get all available damage types
  #
  # @return [Array<Symbol>] List of damage type symbols
  def self.damage_types
    WOUND_STRINGS.keys - [:generic]
  end

  # Get physical damage types
  #
  # @return [Array<Symbol>] Physical damage types
  def self.physical_damage_types
    %i[slashing piercing bludgeoning]
  end

  # Get elemental damage types
  #
  # @return [Array<Symbol>] Elemental damage types
  def self.elemental_damage_types
    %i[fire cold lightning acid poison]
  end

  # Get other damage types
  #
  # @return [Array<Symbol>] Other damage types
  def self.other_damage_types
    %i[psychic radiant necrotic]
  end
end
