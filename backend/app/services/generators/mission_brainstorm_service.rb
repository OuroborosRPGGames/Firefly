# frozen_string_literal: true

module Generators
  # MissionBrainstormService generates creative mission ideas using multiple LLMs in parallel
  #
  # Uses Kimi-k2 and GPT 5.4 simultaneously to generate diverse creative interpretations,
  # which are then synthesized by Opus in the next phase.
  #
  # @example Generate brainstorm ideas
  #   result = Generators::MissionBrainstormService.brainstorm(
  #     description: "A heist to steal the Duke's ledger",
  #     setting: :fantasy,
  #     seed_terms: %w[mysterious noble intrigue]
  #   )
  #
  class MissionBrainstormService
    # Model configuration for brainstorming
    BRAINSTORM_MODELS = {
      creative_a: { provider: 'openrouter', model: 'moonshotai/kimi-k2-0905' },
      creative_b: { provider: 'openai', model: 'gpt-5.4' }
    }.freeze

    class << self
      # Generate brainstorm ideas from multiple models in parallel
      # @param description [String] Mission description/concept
      # @param setting [Symbol] World setting (:fantasy, :scifi, :modern)
      # @param seed_terms [Array<String>] Inspiration terms from SeedTermService
      # @param options [Hash] Additional options
      # @return [Hash] { success:, outputs: { creative_a:, creative_b: }, errors: }
      def brainstorm(description:, setting:, seed_terms: [], options: {})
        seed_terms = (seed_terms.nil? || seed_terms.empty?) ? SeedTermService.for_generation(:lore, count: 8) : seed_terms
        prompt = build_brainstorm_prompt(description, setting, seed_terms)

        outputs = {}
        errors = []

        # Build batch requests for parallel processing via Sidekiq
        requests = BRAINSTORM_MODELS.map do |key, config|
          req_options = {
            max_tokens: options[:max_tokens] || 16000,
            temperature: options[:temperature] || 0.9,
            timeout: options[:timeout] || 180
          }
          # Enable reasoning for OpenAI models
          req_options[:reasoning_effort] = 'medium' if config[:provider] == 'openai'

          {
            prompt: prompt,
            provider: config[:provider],
            model: config[:model],
            options: req_options,
            context: { model_key: key.to_s }
          }
        end

        batch = LLM::Client.batch_submit(requests)
        wait_timeout = (options[:timeout] || 180) + 30
        batch.wait!(timeout: wait_timeout)

        batch.results.each do |request|
          key = request.parsed_context['model_key']&.to_sym
          next unless key

          if request.status == 'completed' && request.response_text
            outputs[key] = request.response_text
          else
            error_msg = request.error_message || 'unknown error'
            errors << "#{key}: #{error_msg}"
          end
        end

        {
          success: outputs.any?,
          outputs: outputs,
          seed_terms: seed_terms,
          errors: errors
        }
      end

      # Generate brainstorm with a single model (for testing/fallback)
      # @param description [String]
      # @param setting [Symbol]
      # @param model_key [Symbol] :creative_a or :creative_b
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, output:, error: }
      def brainstorm_single(description:, setting:, model_key:, seed_terms: [])
        config = BRAINSTORM_MODELS[model_key]
        return { success: false, error: "Unknown model key: #{model_key}" } unless config

        seed_terms = (seed_terms.nil? || seed_terms.empty?) ? SeedTermService.for_generation(:lore, count: 8) : seed_terms
        prompt = build_brainstorm_prompt(description, setting, seed_terms)

        result = LLM::Client.generate(
          prompt: prompt,
          provider: config[:provider],
          model: config[:model],
          options: {
            max_tokens: 2500,
            temperature: 0.9,
            timeout: 180
          }
        )

        {
          success: result[:success],
          output: result[:text],
          model: config[:model],
          error: result[:error]
        }
      end

      # Check if brainstorm models are available
      # @return [Hash] { creative_a: Boolean, creative_b: Boolean }
      def models_available?
        {
          creative_a: AIProviderService.provider_available?('openrouter'),
          creative_b: AIProviderService.provider_available?('openai')
        }
      end

      private

      # Build the brainstorm prompt with parameters
      def build_brainstorm_prompt(description, setting, seed_terms)
        GamePrompts.get('missions.brainstorm',
                        description: description,
                        setting: setting.to_s.split('_').map(&:capitalize).join(' '),
                        seed_terms: seed_terms.join(', '))
      end

    end
  end
end
