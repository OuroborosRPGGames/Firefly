# frozen_string_literal: true

module NameGeneration
  # Result struct for character name generation
  NameResult = Struct.new(:forename, :surname, :full_name, :metadata, keyword_init: true) do
    def to_s
      full_name || forename
    end

    def to_h
      {
        forename: forename,
        surname: surname,
        full_name: full_name
      }.merge(metadata || {})
    end
  end

  # Result struct for city/town name generation
  CityResult = Struct.new(:name, :pattern, :setting, :metadata, keyword_init: true) do
    def to_s
      name
    end

    def to_h
      {
        name: name,
        pattern: pattern,
        setting: setting
      }.merge(metadata || {})
    end
  end

  # Result struct for street name generation
  StreetResult = Struct.new(:name, :style, :setting, :metadata, keyword_init: true) do
    def to_s
      name
    end

    def to_h
      {
        name: name,
        style: style,
        setting: setting
      }.merge(metadata || {})
    end
  end

  # Result struct for shop name generation
  ShopResult = Struct.new(:name, :shop_type, :pattern_used, :setting, :metadata, keyword_init: true) do
    def to_s
      name
    end

    def to_h
      {
        name: name,
        shop_type: shop_type,
        pattern_used: pattern_used,
        setting: setting
      }.merge(metadata || {})
    end
  end
end
