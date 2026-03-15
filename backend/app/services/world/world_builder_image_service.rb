# frozen_string_literal: true

# WorldBuilderImageService generates images for world building content
#
# Centralizes image generation styles and configurations for different
# content types (items, NPCs, rooms, furniture, etc.)
#
# @example Generate item product shot
#   WorldBuilderImageService.generate(
#     type: :item_on_black,
#     description: "An ornate silver dagger with ruby inlays"
#   )
#
# @example Generate NPC portrait
#   WorldBuilderImageService.generate(
#     type: :npc_portrait,
#     description: "A weathered elven merchant with silver hair"
#   )
#
# @example Generate room background
#   WorldBuilderImageService.generate(
#     type: :room_background,
#     description: "A cozy tavern common room with a roaring fireplace"
#   )
#
class WorldBuilderImageService
  class << self
    # Generate an image
    # @param type [Symbol] image type from GamePrompts.image_template
    # @param description [String] what to generate
    # @param options [Hash] additional options
    # @option options [Symbol] :setting game setting for style modifier
    # @option options [String] :additional_prompt extra prompt text
    # @option options [Boolean] :save_locally whether to download and save
    # @return [Hash] { success:, url:, local_url:, local_path:, error: }
    def generate(type:, description:, options: {})
      config = GamePrompts.image_template(type.to_sym)
      return { success: false, error: "Unknown image type: #{type}" } unless config

      # Build the full prompt
      prompt = build_prompt(config, description, options)

      # Determine aspect ratio
      aspect_ratio = config[:ratio] || '1:1'

      # Generate via ImageGenerationService
      result = ::LLM::ImageGenerationService.generate(
        prompt: prompt,
        options: options.merge(aspect_ratio: aspect_ratio, style: config[:style])
      )

      unless result[:success]
        return { success: false, error: result[:error] }
      end

      response = {
        success: true,
        url: result[:url] || result[:local_url],
        prompt_used: prompt
      }

      # Save locally if requested or if we have a target
      if options[:save_locally] || options[:target]
        save_result = save_image(result[:url], type, options)
        if save_result[:success]
          response[:local_url] = save_result[:local_url]
          response[:local_path] = save_result[:local_path]
        else
          response[:save_error] = save_result[:error]
        end
      end

      response
    end

    # Generate multiple images in batch
    # @param items [Array<Hash>] array of { type:, description:, options: }
    # @return [Array<Hash>] results for each item
    def generate_batch(items)
      items.map do |item|
        generate(
          type: item[:type],
          description: item[:description],
          options: item[:options] || {}
        )
      end
    end

    # Check if image generation is available
    # @return [Boolean]
    def available?
      ::LLM::ImageGenerationService.available?
    end

    # Get available image types
    # @return [Array<Symbol>]
    def available_types
      GamePrompts.image_template_types
    end

    # Get info about an image type
    # @param type [Symbol]
    # @return [Hash, nil]
    def type_info(type)
      config = GamePrompts.image_template(type.to_sym)
      return nil unless config

      {
        type: type,
        ratio: config[:ratio],
        style: config[:style],
        description: type_description(type)
      }
    end

    private

    # Build the full prompt from config and description
    def build_prompt(config, description, options)
      if config[:image_framing] && options[:setting]
        build_photographic_prompt(config, description, options)
      else
        build_legacy_prompt(config, description, options)
      end
    end

    # Build photographic "Film still from..." prompt using photo_profile system
    def build_photographic_prompt(config, description, options)
      setting = options[:setting].to_sym
      framing = config[:image_framing]
      profile = GamePrompts.photo_profile(setting) || GamePrompts.photo_profile(:fantasy)

      lens = framing[:lens_override] || profile[:default_lens]
      film_stock_part = if profile[:film_stock] && !profile[:film_stock].empty?
                          "shot on #{profile[:film_stock]}, "
                        else
                          ''
                        end

      lines = []
      lines << "Film still from a #{profile[:genre_phrase]} production, #{profile[:camera]}, #{lens}, #{film_stock_part}#{description}."

      lighting = [profile[:lighting], framing[:lighting_extra]].compact.join(', ')
      lines << "#{lighting}, #{framing[:framing]}."
      lines << "#{profile[:imperfections]}. #{framing[:directives]}".strip

      lines << options[:additional_prompt] if options[:additional_prompt]
      lines.join("\n")
    end

    # Legacy prompt using prefix/suffix concatenation
    def build_legacy_prompt(config, description, options)
      parts = []
      parts << config[:prefix]
      if options[:setting]
        modifier = GamePrompts.setting_modifier(options[:setting].to_sym)
        parts << modifier if modifier
      end
      parts << description
      parts << options[:additional_prompt] if options[:additional_prompt]
      parts << config[:suffix]
      parts.compact.join(' ')
    end

    # Save image to local storage
    def save_image(url, type, options)
      return { success: false, error: 'No URL to save' } unless url

      # Determine filename
      target = options[:target]
      if target
        class_name = NamingHelper.underscore_class_name(target)
        filename = "#{class_name}_#{target.id}_#{type}"
      else
        filename = "generated_#{type}_#{Time.now.to_i}"
      end

      # Add extension based on URL or default to png
      extension = url.match(/\.(jpg|jpeg|png|webp)/i)&.captures&.first || 'png'
      filename = "#{filename}.#{extension}"

      # Determine storage path
      storage_dir = File.join(Dir.pwd, 'public', 'images', 'generated', type.to_s)
      FileUtils.mkdir_p(storage_dir)
      local_path = File.join(storage_dir, filename)

      begin
        # Download the image
        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          File.binwrite(local_path, response.body)

          {
            success: true,
            local_path: local_path,
            local_url: "/images/generated/#{type}/#{filename}"
          }
        else
          { success: false, error: "HTTP #{response.code}: #{response.message}" }
        end
      rescue StandardError => e
        { success: false, error: "Download failed: #{e.message}" }
      end
    end

    # Get human-readable description for image type
    def type_description(type)
      case type
      when :item_on_black then 'Product shot on black background'
      when :item_on_gray then 'Product shot on gray background'
      when :item_on_model then 'Clothing on invisible mannequin'
      when :npc_portrait then 'Character portrait headshot'
      when :npc_full_body then 'Full body character portrait'
      when :room_background then 'Interior scene background (HD)'
      when :room_background_4k then 'Interior scene background (4K)'
      when :furniture then 'Furniture product shot'
      when :building_exterior then 'Building exterior shot'
      when :city_overview then 'City aerial overview'
      when :street_scene then 'Street level scene'
      else NamingHelper.humanize(type.to_s)
      end
    end
  end
end
