# frozen_string_literal: true

require_relative 'combat_sync_helpers'

# Custom RSpec matchers for combat input synchronization testing.
# These matchers help verify that quickmenu and battlemap produce identical state.

RSpec::Matchers.define :have_same_combat_state_as do |expected_participant|
  match do |actual_participant|
    @differences = CombatSyncHelpers.compare_combat_state(actual_participant, expected_participant)
    @differences.empty?
  end

  failure_message do |actual_participant|
    lines = ["Combat state differs between participants:"]
    @differences.each do |field, values|
      lines << "  #{field}:"
      lines << "    actual:   #{values[:participant_a].inspect}"
      lines << "    expected: #{values[:participant_b].inspect}"
    end
    lines.join("\n")
  end

  failure_message_when_negated do
    'Expected participants to have different combat state, but they are identical'
  end

  description do
    'have the same combat state as another participant'
  end
end

RSpec::Matchers.define :include_action_option do |action_key|
  match do |quickmenu_result|
    return false unless quickmenu_result.is_a?(Hash) && quickmenu_result[:options]

    @options = quickmenu_result[:options]
    @options.any? { |opt| opt[:key] == action_key }
  end

  failure_message do
    available = @options&.map { |o| o[:key] } || []
    "Expected quickmenu to include action '#{action_key}', but available actions were: #{available.inspect}"
  end

  failure_message_when_negated do
    "Expected quickmenu not to include action '#{action_key}', but it was present"
  end

  description do
    "include the '#{action_key}' action option"
  end
end

RSpec::Matchers.define :have_enabled_action do |action_key|
  match do |quickmenu_result|
    return false unless quickmenu_result.is_a?(Hash) && quickmenu_result[:options]

    @options = quickmenu_result[:options]
    option = @options.find { |opt| opt[:key] == action_key }
    return false unless option

    @option = option
    !option[:disabled]
  end

  failure_message do
    if @option
      "Expected action '#{action_key}' to be enabled, but it was disabled"
    else
      available = @options&.map { |o| o[:key] } || []
      "Expected quickmenu to include enabled action '#{action_key}', but it was not present. Available: #{available.inspect}"
    end
  end

  description do
    "have '#{action_key}' as an enabled action"
  end
end

RSpec::Matchers.define :have_disabled_action do |action_key|
  match do |quickmenu_result|
    return false unless quickmenu_result.is_a?(Hash) && quickmenu_result[:options]

    @options = quickmenu_result[:options]
    option = @options.find { |opt| opt[:key] == action_key }
    return false unless option

    @option = option
    option[:disabled] == true
  end

  failure_message do
    if @option
      "Expected action '#{action_key}' to be disabled, but it was enabled"
    else
      available = @options&.map { |o| o[:key] } || []
      "Expected quickmenu to include disabled action '#{action_key}', but it was not present. Available: #{available.inspect}"
    end
  end

  description do
    "have '#{action_key}' as a disabled action"
  end
end

RSpec::Matchers.define :accept_action do |action_type|
  match do |service_result|
    return false unless service_result.is_a?(Hash)

    @result = service_result
    service_result[:success] == true
  end

  failure_message do
    error = @result&.dig(:error) || @result&.dig(:message) || 'unknown error'
    "Expected CombatActionService to accept '#{action_type}', but it failed with: #{error}"
  end

  failure_message_when_negated do
    "Expected CombatActionService to reject '#{action_type}', but it succeeded"
  end

  description do
    "accept the '#{action_type}' action"
  end
end

RSpec::Matchers.define :reject_action_with do |expected_error|
  match do |service_result|
    return false unless service_result.is_a?(Hash)

    @result = service_result
    service_result[:success] == false && service_result[:error]&.include?(expected_error)
  end

  failure_message do
    if @result[:success]
      "Expected CombatActionService to reject action, but it succeeded"
    else
      "Expected error to include '#{expected_error}', but got: #{@result[:error].inspect}"
    end
  end

  description do
    "reject the action with error containing '#{expected_error}'"
  end
end
