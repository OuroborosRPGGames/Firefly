# frozen_string_literal: true

# Shared behavior for quickmenu handlers.
# Provides common structure for stage-based menu navigation with back/done handling.
#
# Usage:
#   class MyQuickmenuHandler
#     include BaseQuickmenuHandler
#
#     STAGES = {
#       'main_menu' => { prompt: 'Choose:' },
#       'action' => { prompt: 'Select action:' }
#     }.freeze
#
#     private
#
#     def process_stage_choice(stage, response)
#       # Handle stage-specific choices
#     end
#
#     def build_options_for_stage(stage)
#       # Return array of option hashes
#     end
#
#     def menu_context
#       # Return hash with context-specific data
#     end
#   end
#
module BaseQuickmenuHandler
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    # Show the current menu for a participant
    def show_menu(participant, char_instance)
      new(participant, char_instance).show_current_menu
    end

    # Handle a response to a menu
    def handle_response(participant, char_instance, response)
      new(participant, char_instance).handle_response(response)
    end
  end

  attr_reader :participant, :char_instance

  def initialize(participant, char_instance)
    @participant = participant
    @char_instance = char_instance
    after_initialize if respond_to?(:after_initialize, true)
  end

  # Show the quickmenu for the current input stage
  def show_current_menu
    stage = current_stage
    stage_config = stages[stage]

    return nil if stage_config.nil? || stage == 'done'

    options = build_options_for_stage(stage)

    {
      type: :quickmenu,
      prompt: stage_config[:prompt],
      options: options,
      context: menu_context.merge(stage: stage)
    }
  end

  # Handle a menu response
  def handle_response(response)
    stage = current_stage

    # Handle back navigation
    if response == 'back'
      return_to_main_menu
      return show_current_menu
    end

    # Handle done
    if response == 'done' && stage == 'main_menu'
      if can_complete?
        complete_input!
        check_round_resolution
        # Return :round_resolved if the round was resolved (broadcasts sent via WS),
        # so the HTTP response can suppress redundant "choices recorded" message
        return @round_resolved ? :round_resolved : nil
      else
        return show_current_menu
      end
    end

    # Process the choice based on current stage
    process_stage_choice(stage, response)

    # After processing, check completion
    after_process_choice
  end

  private

  # Subclasses must implement these methods:

  # Process a choice for the given stage
  # @param stage [String] current stage name
  # @param response [String] user's response
  def process_stage_choice(stage, response)
    raise NotImplementedError, "#{self.class} must implement #process_stage_choice"
  end

  # Build options array for the given stage
  # @param stage [String] stage name
  # @return [Array<Hash>] array of option hashes with :key, :label, :description
  def build_options_for_stage(stage)
    raise NotImplementedError, "#{self.class} must implement #build_options_for_stage"
  end

  # Return context hash for the menu (e.g., fight_id, instance_id)
  # @return [Hash] context data
  def menu_context
    raise NotImplementedError, "#{self.class} must implement #menu_context"
  end

  # Check if input can be completed
  # @return [Boolean]
  def can_complete?
    raise NotImplementedError, "#{self.class} must implement #can_complete?"
  end

  # Complete the input
  def complete_input!
    raise NotImplementedError, "#{self.class} must implement #complete_input!"
  end

  # Check if round should be resolved and trigger resolution if so
  def check_round_resolution
    raise NotImplementedError, "#{self.class} must implement #check_round_resolution"
  end

  # Reset to main menu state
  def return_to_main_menu
    raise NotImplementedError, "#{self.class} must implement #return_to_main_menu"
  end

  # Get current stage name
  # @return [String] stage name
  def current_stage
    # Default implementation reads from participant.input_stage
    # Override if stage is determined differently
    participant.input_stage
  end

  # Get the STAGES constant from the implementing class
  def stages
    self.class::STAGES
  end

  # Called after processing a choice - handles reload and resolution check
  def after_process_choice
    # Skip if the round was already resolved during process_stage_choice
    # (e.g., autobattle calls check_round_resolution directly)
    return @round_resolved ? :round_resolved : nil if @round_resolved

    participant.reload

    if input_complete?
      check_round_resolution
      @round_resolved ? :round_resolved : nil
    else
      show_current_menu
    end
  end

  # Check if input is complete
  # Default checks participant.input_complete - override if needed
  def input_complete?
    participant.respond_to?(:input_complete) && participant.input_complete
  end

  # Common helper: build a back option
  def back_option(description = 'Return to main menu')
    { key: 'back', label: '<- Back', description: description }
  end

  # Common helper: build a done option
  def done_option(description = nil)
    desc = description || (can_complete? ? 'Submit choices' : 'Choose an action first')
    { key: 'done', label: 'Done', description: desc }
  end
end
