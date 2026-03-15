# frozen_string_literal: true

module Commands
  module Communication
    # Shared helper for commands that need to parse comma-separated target names,
    # find multiple characters/users by name, and collect not-found errors.
    #
    # Used by Msg and Ooc commands to avoid duplicating target resolution logic.
    #
    # Expects the including class to provide:
    #   - blank?(value)       - from core_extensions / base command
    #   - error_result(msg)   - from Commands::Base::Command
    #
    module MultiTargetHelper
      # Parse comma-separated target names from a target string.
      # The target string is typically the first word from the command input.
      #
      # @param target_str [String, nil] Comma-separated names (e.g. "Alice,Bob,Charlie")
      # @return [Array<String>] Array of trimmed, non-empty name strings
      def parse_target_names(target_str)
        return [] if blank?(target_str)

        target_str.split(',').map(&:strip).reject(&:empty?)
      end

      # Find targets by name array, using a provided finder block.
      # Collects found targets and names that were not found.
      #
      # @param names [Array<String>] Target names to look up
      # @yield [name] Block that takes a name string and returns the found object or nil
      # @return [Hash] { targets: [found_objects], not_found: [name_strings] }
      #
      # @example Finding characters
      #   find_targets_by_names(names) { |name| find_character_globally(name) }
      #
      # @example Finding users via characters
      #   find_targets_by_names(names) do |name|
      #     char = find_character_by_name_globally(name)
      #     char&.user
      #   end
      #
      def find_targets_by_names(names)
        targets = []
        not_found = []

        names.each do |name|
          result = yield(name)
          if result
            targets << result
          else
            not_found << name
          end
        end

        { targets: targets, not_found: not_found }
      end

      # Return a standard error result when no targets were found.
      #
      # @param not_found [Array<String>] Names that could not be resolved
      # @return [Hash] Error result hash from error_result
      def no_targets_error(not_found)
        if not_found.any?
          error_result("Could not find anyone named '#{not_found.join(', ')}'.")
        else
          error_result("No valid recipients found.")
        end
      end
    end
  end
end
