# frozen_string_literal: true

module NameGeneration
  # ShopNameGenerator generates shop and business names with support for
  # multiple settings and shop types.
  #
  # Usage:
  #   generator = ShopNameGenerator.new
  #   result = generator.generate(shop_type: :tavern, setting: :earth_historic)
  #   result.name # => "The Golden Goblet"
  #
  class ShopNameGenerator < BaseGenerator
    # Valid shop types
    SHOP_TYPES = %i[
      tavern restaurant blacksmith general_store clothing
      magic tech jewelry bookstore
    ].freeze

    # Valid settings
    VALID_SETTINGS = %i[
      earth_historic
      earth_modern
      earth_future
      fictional_historic
      fictional_contemporary
      fictional_future_human
      fictional_future_alien
    ].freeze

    # Template patterns
    TEMPLATE_PATTERNS = [
      :adjective_noun,
      :owner_shop,
      :noun_and_noun,
      :adjective_material_shop,
      :noun_shop,
      :adjective_shop,
      :number_noun
    ].freeze

    # Generate a shop name
    # @param shop_type [Symbol] the type of shop
    # @param setting [Symbol] the genre/setting
    # @param template [Symbol] specific template to use (or :random)
    # @return [ShopResult]
    def generate(shop_type: :tavern, setting: :earth_modern, template: :random)
      setting = normalize_setting(setting)
      shop_type = normalize_shop_type(shop_type)
      data = load_shop_data

      # Select template
      selected_template = select_template(template, data[:templates])

      # Generate name based on template
      name = generate_by_template(selected_template, shop_type, setting, data)

      ShopResult.new(
        name: name,
        metadata: {
          shop_type: shop_type,
          setting: setting,
          template: selected_template
        }
      )
    end

    private

    def normalize_setting(setting)
      return setting if VALID_SETTINGS.include?(setting)

      :earth_modern
    end

    def normalize_shop_type(shop_type)
      return shop_type if SHOP_TYPES.include?(shop_type)

      :general_store
    end

    def load_shop_data
      @shop_data ||= load_data('shops', 'shop_patterns')
    rescue ArgumentError
      default_shop_data
    end

    def default_shop_data
      {
        templates: [{ pattern: 'The {adjective} {noun}', weight: 5 }],
        adjectives: { generic: [{ name: 'Golden', weight: 5 }] },
        nouns: { objects: [{ name: 'Goblet', weight: 5 }] },
        shop_types: { tavern: { names: [{ name: 'Tavern', weight: 5 }] } }
      }
    end

    def select_template(requested_template, templates)
      return requested_template if TEMPLATE_PATTERNS.include?(requested_template)

      # Weighted random selection from available templates
      TEMPLATE_PATTERNS.sample
    end

    def generate_by_template(template, shop_type, setting, data)
      case template
      when :adjective_noun
        generate_adjective_noun(setting, data)
      when :owner_shop
        generate_owner_shop(shop_type, setting, data)
      when :noun_and_noun
        generate_noun_and_noun(data)
      when :adjective_material_shop
        generate_adjective_material_shop(shop_type, setting, data)
      when :noun_shop
        generate_noun_shop(shop_type, data)
      when :adjective_shop
        generate_adjective_shop(shop_type, setting, data)
      when :number_noun
        generate_number_noun(data)
      else
        generate_adjective_noun(setting, data)
      end
    end

    def generate_adjective_noun(setting, data)
      # "The {adjective} {noun}" pattern
      adjective = select_adjective(setting, data)
      noun = select_noun(data)

      "The #{adjective} #{noun}"
    end

    def generate_owner_shop(shop_type, setting, data)
      # "{owner}'s {shop_type}" pattern
      owner = select_owner_name(setting, data)
      shop_type_name = select_shop_type_name(shop_type, setting, data)

      "#{owner}'s #{shop_type_name}"
    end

    def generate_noun_and_noun(data)
      # "The {noun} and {noun}" pattern
      noun1 = select_noun(data)
      noun2 = select_noun(data)

      # Avoid same noun twice
      attempts = 0
      while noun1 == noun2 && attempts < 5
        noun2 = select_noun(data)
        attempts += 1
      end

      "The #{noun1} and #{noun2}"
    end

    def generate_adjective_material_shop(shop_type, setting, data)
      # "{adjective} {material} {shop_type}" pattern
      adjective = select_quality_adjective(data)
      material = select_material(data)
      shop_type_name = select_shop_type_name(shop_type, setting, data)

      "#{adjective} #{material} #{shop_type_name}"
    end

    def generate_noun_shop(shop_type, data)
      # "{noun} {shop_type}" pattern
      noun = select_noun(data)
      shop_type_name = select_shop_type_name(shop_type, :earth_modern, data)

      "#{noun} #{shop_type_name}"
    end

    def generate_adjective_shop(shop_type, setting, data)
      # "The {adjective} {shop_type}" pattern
      adjective = select_adjective(setting, data)
      shop_type_name = select_shop_type_name(shop_type, setting, data)

      "The #{adjective} #{shop_type_name}"
    end

    def generate_number_noun(data)
      # "{number} {noun}" pattern
      numbers = data[:numbers] || []
      noun = select_noun(data, category: :objects)

      if numbers.any?
        number = weighted_select(numbers, category: :shop_number) || 'Seven'
        "#{number} #{noun}s"
      else
        "Seven #{noun}s"
      end
    end

    def select_adjective(setting, data)
      adjectives = data[:adjectives] || {}

      # Try setting-specific first, then generic
      setting_adjectives = adjectives[setting] || []
      generic_adjectives = adjectives[:generic] || []

      all_adjectives = setting_adjectives + generic_adjectives

      if all_adjectives.any?
        weighted_select(all_adjectives, category: :shop_adjective) || 'Golden'
      else
        'Golden'
      end
    end

    def select_quality_adjective(data)
      adjectives = data[:adjectives] || {}
      generic = adjectives[:generic] || []

      quality_words = generic.select do |adj|
        %w[Fine Quality Grand Premium].include?(adj[:name])
      end

      if quality_words.any?
        weighted_select(quality_words, category: :shop_quality) || 'Fine'
      else
        'Fine'
      end
    end

    def select_noun(data, category: nil)
      nouns = data[:nouns] || {}

      if category && nouns[category]
        noun_list = nouns[category]
      else
        # Combine all noun categories
        noun_list = nouns.values.flatten
      end

      if noun_list.any?
        weighted_select(noun_list, category: :shop_noun) || 'Star'
      else
        'Star'
      end
    end

    def select_material(data)
      materials = data[:materials] || []

      if materials.any?
        weighted_select(materials, category: :shop_material) || 'Gold'
      else
        'Gold'
      end
    end

    def select_owner_name(setting, data)
      owner_names = data[:owner_names] || {}

      # Try setting-specific first, then generic
      setting_owners = owner_names[setting] || []
      generic_owners = owner_names[:generic] || []

      all_owners = setting_owners + generic_owners

      if all_owners.any?
        weighted_select(all_owners, category: :shop_owner) || 'Marcus'
      else
        'Marcus'
      end
    end

    def select_shop_type_name(shop_type, setting, data)
      shop_types = data[:shop_types] || {}
      type_data = shop_types[shop_type] || {}

      # Check for setting-specific variants first
      setting_variants = type_data[:setting_variants] || {}
      if setting_variants[setting]
        variant_list = setting_variants[setting]
        return weighted_select(variant_list, category: :shop_type_name) if variant_list.any?
      end

      # Fall back to general names
      names = type_data[:names] || []

      if names.any?
        weighted_select(names, category: :shop_type_name) || 'Shop'
      else
        shop_type.to_s.tr('_', ' ').capitalize
      end
    end
  end
end
