# frozen_string_literal: true

# GenerationPipelineService orchestrates LLM-based content generation
#
# Implements the multi-model pipeline:
# 1. Generate content with high-quality writing model (kimi-k2)
# 2. Validate with fast model (gemini-3.1-flash-lite-preview)
# 3. If validation fails, retry with workhorse model (gemini-3-flash-preview)
#
# @example Generate a description with validation
#   result = GenerationPipelineService.generate_with_validation(
#     prompt: "Write a tavern description...",
#     validation_criteria: "Must mention: atmosphere, lighting, seating",
#     max_retries: 2
#   )
#
# @example Select best name from options
#   result = GenerationPipelineService.select_best_name(
#     options: ["The Golden Dragon", "Dragon's Rest", "The Gilded Wyrm"],
#     context: { setting: 'fantasy', place_type: 'tavern', vibe: 'upscale' }
#   )
#
class GenerationPipelineService
  # Model configuration
  MODELS = {
    workhorse: { provider: 'google_gemini', model: 'gemini-3-flash-preview' },
    writing: { provider: 'openrouter', model: 'moonshotai/kimi-k2-0905' },
    validation: { provider: 'google_gemini', model: 'gemini-3.1-flash-lite-preview' },
    selection: { provider: 'google_gemini', model: 'gemini-3-flash-preview' }
  }.freeze

  # Default validation criteria by content type
  DEFAULT_VALIDATION = {
    room_description: 'Must be 2-4 sentences. Must describe atmosphere or mood. Must be in present tense.',
    item_description: 'Must be 2-3 sentences. MUST include specific color (not just "colorful"). MUST include material/fabric. Must describe appearance concretely. No vague words like "beautiful", "elegant", "mysterious" without specifics.',
    npc_description: 'Must describe physical appearance. Must be 2-4 sentences. Avoid personality unless shown physically.',
    place_name: 'Must be a plausible business/location name. 1-4 words.',
    city_name: 'Must be pronounceable. Must feel like a real place name.'
  }.freeze

  # Seed term instructions template - loaded from prompts.yml
  SEED_TERM_INSTRUCTIONS = GamePrompts.get('generation_pipeline.seed_instructions')

  class << self
    # Generate content with validation and retry
    # @param prompt [String] generation prompt
    # @param validation_criteria [String] what the output must satisfy
    # @param content_type [Symbol] optional type for default validation
    # @param max_retries [Integer] max retry attempts (default 2)
    # @param options [Hash] additional LLM options
    # @return [Hash] { success:, content:, validated:, attempts:, model_used:, errors: }
    def generate_with_validation(prompt:, validation_criteria: nil, content_type: nil,
                                 max_retries: 2, options: {})
      validation = validation_criteria || DEFAULT_VALIDATION[content_type]

      # Step 1: Generate with writing model (kimi-k2)
      generation_result = generate_content(prompt, options)

      unless generation_result[:success]
        return {
          success: false,
          content: nil,
          validated: false,
          attempts: 1,
          model_used: MODELS[:writing][:model],
          errors: [generation_result[:error]]
        }
      end

      content = generation_result[:text]
      attempts = 1
      errors = []

      # Step 2: Validate with fast model
      if validation
        validation_result = validate_content(content, validation)

        if validation_result[:valid]
          return {
            success: true,
            content: content,
            validated: true,
            attempts: attempts,
            model_used: MODELS[:writing][:model],
            errors: errors
          }
        end

        errors << validation_result[:reason]

        # Step 3: Retry with workhorse model if validation failed
        max_retries.times do |i|
          attempts += 1

          retry_prompt = build_retry_prompt(prompt, content, validation, validation_result[:issues])
          retry_result = generate_with_workhorse(retry_prompt, options)

          unless retry_result[:success]
            errors << retry_result[:error]
            next
          end

          content = retry_result[:text]

          # Re-validate
          validation_result = validate_content(content, validation)

          if validation_result[:valid]
            return {
              success: true,
              content: content,
              validated: true,
              attempts: attempts,
              model_used: MODELS[:workhorse][:model],
              errors: errors
            }
          end

          errors << validation_result[:reason]
        end
      end

      # Return best effort if we never validated successfully
      {
        success: true,
        content: content,
        validated: false,
        attempts: attempts,
        model_used: attempts > 1 ? MODELS[:workhorse][:model] : MODELS[:writing][:model],
        errors: errors
      }
    end

    # Generate content without validation (simple generation)
    # @param prompt [String]
    # @param options [Hash]
    # @return [Hash] { success:, content:, model_used: }
    def generate_simple(prompt:, options: {})
      result = generate_with_workhorse(prompt, options)

      {
        success: result[:success],
        content: result[:text],
        model_used: MODELS[:workhorse][:model],
        error: result[:error]
      }
    end

    # Generate high-quality description (uses writing model)
    # @param prompt [String]
    # @param options [Hash]
    # @return [Hash]
    def generate_description(prompt:, options: {})
      result = generate_content(prompt, options)

      {
        success: result[:success],
        content: result[:text],
        model_used: MODELS[:writing][:model],
        error: result[:error]
      }
    end

    # Select best option from a list using LLM
    # @param options [Array<String>] name/description options
    # @param context [Hash] selection context
    # @return [Hash] { success:, selected:, reasoning: }
    def select_best_name(options:, context: {})
      return { success: false, selected: nil, error: 'No options provided' } if options.empty?
      return { success: true, selected: options.first, reasoning: 'Only one option' } if options.length == 1

      prompt = build_selection_prompt(options, context)
      result = generate_with_model(:selection, prompt, json_mode: true)

      unless result[:success]
        # Fallback: return first option
        return { success: true, selected: options.first, reasoning: 'LLM selection failed, using first option' }
      end

      begin
        parsed = parse_json_response(result[:text])
        selected = parsed['selected'] || parsed['choice'] || parsed['name']

        # Verify selected is one of the options
        unless options.include?(selected)
          # Try to find closest match
          selected = options.find { |o| o.downcase.include?(selected.to_s.downcase) } || options.first
        end

        {
          success: true,
          selected: selected,
          reasoning: parsed['reasoning'] || parsed['reason']
        }
      rescue StandardError => e
        { success: true, selected: options.first, reasoning: "Parse error: #{e.message}" }
      end
    end

    # Validate content against criteria
    # @param content [String] content to validate
    # @param criteria [String] validation criteria
    # @return [Hash] { valid:, reason:, issues: }
    def validate_content(content, criteria)
      prompt = build_validation_prompt(content, criteria)
      result = generate_with_model(:validation, prompt, json_mode: true)

      unless result[:success]
        # If validation fails, assume content is OK (don't block on validation errors)
        return { valid: true, reason: 'Validation service unavailable' }
      end

      begin
        parsed = parse_json_response(result[:text])

        # If parsing returned empty hash (invalid JSON), assume content is valid
        if parsed.empty?
          return { valid: true, reason: 'Parse error: could not extract validation result' }
        end

        valid = parsed['valid'] == true || parsed['passes'] == true || parsed['meets_criteria'] == true

        {
          valid: valid,
          reason: parsed['reason'] || parsed['feedback'],
          issues: parsed['issues'] || []
        }
      rescue StandardError => e
        # Parsing error - assume valid
        { valid: true, reason: "Parse error: #{e.message}" }
      end
    end

    # Generate structured data using tool_use/function calling
    #
    # Defines a tool schema and forces the model to call it, extracting
    # structured arguments. Single-turn only — no multi-turn tool loops.
    #
    # @param prompt [String] generation prompt
    # @param tool_name [String] name for the tool
    # @param tool_description [String] description of what the tool extracts
    # @param parameters [Hash] JSON Schema for the tool's parameters
    # @param model_key [Symbol] which model to use (default :workhorse)
    # @param options [Hash] additional LLM options
    # @return [Hash] { success:, data: Hash, model_used:, error: }
    def generate_structured(prompt:, tool_name:, tool_description:, parameters:,
                            model_key: :workhorse, options: {})
      config = MODELS[model_key]
      return { success: false, data: nil, error: 'Unknown model key' } unless config

      tools = [{
        name: tool_name,
        description: tool_description,
        parameters: parameters
      }]

      result = LLM::Client.generate(
        prompt: prompt,
        provider: config[:provider],
        model: config[:model],
        options: options.merge(max_tokens: options[:max_tokens] || 2000),
        tools: tools
      )

      unless result[:success]
        return { success: false, data: nil, model_used: config[:model], error: result[:error] }
      end

      # Extract structured data from tool call
      if result[:tool_calls]&.any?
        data = result[:tool_calls].first[:arguments]
        return { success: true, data: data, model_used: config[:model], error: nil }
      end

      # Fallback: if model returned text instead of tool call, try JSON parsing
      if result[:text]
        parsed = parse_json_response(result[:text])
        if parsed && !parsed.empty?
          return { success: true, data: parsed, model_used: config[:model], error: nil }
        end
      end

      { success: false, data: nil, model_used: config[:model], error: 'No tool call or parseable JSON in response' }
    rescue StandardError => e
      { success: false, data: nil, model_used: config&.dig(:model), error: e.message }
    end

    # Check if pipeline is available
    # @return [Boolean]
    def available?
      LLM::Client.available?
    end

    # Format seed terms with instructions for LLM
    # @param task_type [Symbol] :item, :npc, :room, :place, :city, etc.
    # @param count [Integer] number of seeds to provide (default: 5)
    # @return [String] formatted seed instruction block
    def format_seed_instructions(task_type, count: 5)
      seeds = SeedTermService.for_generation(task_type, count: count)
      return '' if seeds.empty?

      format(SEED_TERM_INSTRUCTIONS, seeds: seeds.join(', '))
    end

    # Build a prompt with seed term integration
    # @param base_prompt [String] the main generation prompt
    # @param task_type [Symbol] type of content being generated
    # @param seed_count [Integer] number of seeds to include
    # @return [String] complete prompt with seed instructions
    def build_prompt_with_seeds(base_prompt:, task_type:, seed_count: 5)
      seed_block = format_seed_instructions(task_type, count: seed_count)
      return base_prompt if seed_block.empty?

      "#{base_prompt}\n\n#{seed_block}"
    end

    private

    # Generate content using writing model (kimi-k2)
    def generate_content(prompt, options = {})
      generate_with_model(:writing, prompt, options)
    end

    # Generate content using workhorse model (gemini-3-flash-preview)
    def generate_with_workhorse(prompt, options = {})
      generate_with_model(:workhorse, prompt, options)
    end

    # Generate with specific model configuration
    def generate_with_model(model_key, prompt, options = {})
      config = MODELS[model_key]
      return { success: false, text: nil, error: 'Unknown model key' } unless config

      LLM::Client.generate(
        prompt: prompt,
        provider: config[:provider],
        model: config[:model],
        options: options.merge(max_tokens: options[:max_tokens] || 1000),
        json_mode: options[:json_mode] || false
      )
    end

    # Build validation prompt
    def build_validation_prompt(content, criteria)
      GamePrompts.get(
        'generation_pipeline.validation',
        criteria: criteria,
        content: content
      )
    end

    # Build retry prompt with feedback
    def build_retry_prompt(original_prompt, failed_content, criteria, issues)
      GamePrompts.get(
        'generation_pipeline.retry',
        original_prompt: original_prompt,
        failed_content: failed_content,
        issues: Array(issues).map { |i| "- #{i}" }.join("\n"),
        criteria: criteria
      )
    end

    # Build selection prompt
    def build_selection_prompt(options, context)
      GamePrompts.get(
        'generation_pipeline.selection',
        options: options.each_with_index.map { |o, i| "#{i + 1}. #{o}" }.join("\n"),
        context: context.map { |k, v| "#{k}: #{v}" }.join("\n")
      )
    end

    # Parse JSON from LLM response
    def parse_json_response(text)
      # Try to extract JSON from response
      json_match = text.match(/\{[\s\S]*\}/)
      return {} unless json_match

      JSON.parse(json_match[0])
    rescue JSON::ParserError
      {}
    end
  end
end
