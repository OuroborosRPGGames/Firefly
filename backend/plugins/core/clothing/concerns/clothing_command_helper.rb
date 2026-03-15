# frozen_string_literal: true

module Commands
  module Clothing
    # Shared helper for clothing state-toggle commands (cover/expose, zipup/unzip).
    #
    # Extracted from the four commands' identical multi-item resolve-check-update
    # loops. Each command still owns its own messages, broadcasts, and result data
    # because those differ (cover has no broadcast; the action name and wording
    # vary per command).
    module ClothingCommandHelper
      private

      # Resolves a list of item names against a worn-items collection, checks
      # whether each item is already in the target state, updates the attribute
      # on items that need changing, and returns successes and failures.
      #
      # Parameters:
      #   item_names   - Array of query strings from the player input
      #   worn_items   - Array of worn item records (already loaded)
      #   attribute    - Symbol: the model attribute to update, e.g. :concealed or :zipped
      #   target_value - Boolean: the value the attribute should be set to
      #   already_msg  - String: failure reason when item is already in target state,
      #                  e.g. 'already concealed' or 'already zipped up'
      #
      # Returns a Hash with:
      #   :successes - Array of item records that were updated
      #   :failures  - Array of Hashes { name:, reason: }
      def toggle_worn_items(item_names:, worn_items:, attribute:, target_value:, already_msg:)
        successes = []
        failures  = []

        item_names.each do |item_name|
          item = TargetResolverService.resolve(
            query: item_name,
            candidates: worn_items,
            name_field: :name
          )

          unless item
            failures << { name: item_name, reason: "not wearing '#{item_name}'" }
            next
          end

          if item.public_send(attribute) == target_value
            failures << { name: item.name, reason: already_msg }
            next
          end

          item.update(attribute => target_value)
          successes << item
        end

        { successes: successes, failures: failures }
      end

      # Formats a failure-notes suffix to append to a success message.
      # Returns "" when there are no failures.
      def format_failure_notes(failures, prefix:)
        return '' if failures.empty?

        notes = failures.map { |f| "#{f[:name]}: #{f[:reason]}" }.join('; ')
        "\n(#{prefix}: #{notes})"
      end
    end
  end
end
