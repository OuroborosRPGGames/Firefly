#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: bundle exec ruby scripts/generate_element_assets.rb
# Generates element asset images via Gemini and removes backgrounds via Replicate.

require_relative '../app'

ELEMENT_TYPES = %w[water_barrel oil_barrel munitions_crate toxic_mushrooms lotus_pollen vase].freeze
VARIANTS_PER_TYPE = 4

puts "=== Battle Map Element Asset Generator ==="
puts "Generating #{VARIANTS_PER_TYPE} variants for #{ELEMENT_TYPES.size} element types"
puts

ELEMENT_TYPES.each do |element_type|
  prompt_text = GamePrompts.get_safe("battle_elements.asset_generation.#{element_type}")
  unless prompt_text
    puts "  SKIP: No prompt found for #{element_type}"
    next
  end

  puts "Generating #{element_type}..."

  VARIANTS_PER_TYPE.times do |variant_num|
    variant = variant_num + 1

    existing = BattleMapElementAsset.where(element_type: element_type, variant: variant).first
    if existing
      puts "  Variant #{variant}: already exists (#{existing.image_url}), skipping"
      next
    end

    puts "  Variant #{variant}: generating image..."

    result = LLM::ImageGenerationService.generate(
      prompt: "#{prompt_text} Variation #{variant} of #{VARIANTS_PER_TYPE}.",
      options: { aspect_ratio: '1:1' }
    )

    unless result[:success]
      puts "    FAILED: #{result[:error] || 'unknown error'}"
      next
    end

    local_path = result[:local_url] ? "public/#{result[:local_url]}" : result[:local_path]
    unless local_path && File.exist?(local_path)
      puts "    FAILED: generated file not found (local_url=#{result[:local_url].inspect})"
      next
    end

    puts "    Generated: #{local_path}"
    puts "    Removing background..."

    bg_result = ReplicateBackgroundRemovalService.remove_background(local_path)

    final_path = if bg_result[:success]
                   puts "    Background removed: #{bg_result[:output_path]}"
                   bg_result[:output_path]
                 else
                   puts "    Background removal failed: #{bg_result[:error]}, using original"
                   local_path
                 end

    key = "generated/elements/#{element_type}_v#{variant}.png"
    image_data = File.binread(final_path)
    url = CloudStorageService.upload(image_data, key, content_type: 'image/png')

    BattleMapElementAsset.create(
      element_type: element_type,
      variant: variant,
      image_url: url
    )

    puts "    Stored: #{url}"
  end

  puts
end

puts "=== Done ==="
puts "Total assets in database: #{BattleMapElementAsset.count}"
