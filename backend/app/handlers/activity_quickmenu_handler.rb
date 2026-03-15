# frozen_string_literal: true

require_relative 'concerns/base_quickmenu_handler'

# Manages activity quickmenu flow for participants.
# Uses a hub-style menu where players can configure their round in any order.
class ActivityQuickmenuHandler
  include BaseQuickmenuHandler

  # Stage configuration with prompts
  STAGES = {
    'main_menu' => { prompt: 'Activity Actions:' },
    'task' => { prompt: 'Choose your objective:' },
    'action' => { prompt: 'Choose your action:' },
    'target' => { prompt: 'Choose who to help:' },
    'willpower' => { prompt: 'Spend willpower dice?' }
  }.freeze

  # Willpower dice options
  WILLPOWER_OPTIONS = {
    '0' => { label: 'None', description: 'No extra dice' },
    '1' => { label: '+1d8 (1 WP)', description: 'Spend 1 willpower for an extra die' },
    '2' => { label: '+2d8 (2 WP)', description: 'Spend 2 willpower for two extra dice' }
  }.freeze

  attr_reader :instance

  private

  def after_initialize
    @instance = participant.instance
  end

  def current_stage
    return 'done' if participant.has_chosen? && action_complete?
    return 'target' if pending_help_target?
    return 'willpower' if pending_willpower?
    return 'action' if pending_task_action?

    'main_menu'
  end

  def menu_context
    {
      activity: true,
      instance_id: instance.id,
      participant_id: participant.id
    }
  end

  def can_complete?
    participant.has_chosen?
  end

  def complete_input!
    participant.update(chosen_when: Time.now)
  end

  def return_to_main_menu
    attrs = {
      action_chosen: nil,
      effort_chosen: nil,
      risk_chosen: nil,
      action_target: nil,
      willpower_to_spend: 0
    }
    attrs[:task_chosen] = nil
    participant.update(attrs)
  end

  def input_complete?
    participant.has_chosen? && action_complete?
  end

  def check_round_resolution
    instance.reload

    ActivityService.check_all_ready(instance)
    ActivityService.process_pending_round_transition(instance)
  end

  # === Stage Processing ===

  def process_stage_choice(stage, response)
    case stage
    when 'main_menu'
      handle_main_menu_choice(response)
    when 'task'
      handle_task_choice(response)
    when 'action'
      handle_action_choice(response)
    when 'target'
      handle_target_choice(response)
    when 'willpower'
      handle_willpower_choice(response)
    end
  end

  def build_options_for_stage(stage)
    case stage
    when 'main_menu'
      build_main_menu_options
    when 'task'
      build_task_options
    when 'action'
      build_action_options
    when 'target'
      build_target_options
    when 'willpower'
      build_willpower_options
    else
      []
    end
  end

  # === Main Menu (Hub) ===

  def build_main_menu_options
    options = []
    round = instance.current_round
    return options unless round

    # Non-quickmenu round types should not produce menus
    return options if round.persuade? || round.free_roll? || round.rest? || round.branch? || round.combat?

    if round.has_tasks?
      # Task-based round: actions grouped under task section headers
      build_task_section_options(round, options)
    else
      # Non-task round: flat action list with inline stats/risk
      round.available_actions.each do |action|
        options << {
          key: "action_#{action.id}",
          label: action.choice_text,
          description: action_description(action)
        }
      end

      if help_allowed_for_round?(round)
        # Help as last action option
        options << {
          key: 'help',
          label: 'Assist someone',
          description: 'Grant advantage to another player\'s roll'
        }
      end
    end

    if recover_allowed_for_round?(round)
      # Skip / Recover as the very last option
      options << {
        key: 'recover',
        label: 'Skip / Recover',
        description: 'Skip your roll, gain willpower'
      }
    end

    # Done option (if action selected)
    options << done_option(done_validation_message) if participant.has_chosen?

    options
  end

  # Build task-sectioned options for task-based rounds
  def build_task_section_options(round, options)
    round.tasks.each do |task|
      section_name = task.description || "Task #{task.task_number}"

      # Add each action under this task's section
      task.actions.each do |action|
        options << {
          key: "action_#{action.id}",
          label: action.choice_text,
          description: task_action_description(action, task),
          section: section_name
        }
      end

      if help_allowed_for_round?(round)
        # "Assist someone on this task" as last option per task section
        options << {
          key: "help_task_#{task.id}",
          label: 'Assist someone on this task',
          description: 'Grant advantage to another player on this task',
          section: section_name
        }
      end
    end
  end

  def handle_main_menu_choice(response)
    case response
    when /^action_(\d+)$/
      action_id = ::Regexp.last_match(1).to_i
      action = ActivityAction[action_id]
      return unless action

      attrs = { action_chosen: action_id }
      # Auto-set task if action belongs to a task
      attrs[:task_chosen] = action[:task_id] if action[:task_id]
      # Auto-set risk for actions with risk dice (risk is inherent, not a separate choice)
      attrs[:risk_chosen] = 'yes' if has_risk_dice?(action)
      participant.update(attrs)
      broadcast_participant_choice
      # Go straight to willpower selection
      set_stage('willpower')
    when /^help_task_(\d+)$/
      round = instance.current_round
      return unless help_allowed_for_round?(round)

      task_id = ::Regexp.last_match(1).to_i
      participant.update(effort_chosen: 'help', task_chosen: task_id)
      set_stage('target')
    when 'help'
      participant.update(effort_chosen: 'help')
      set_stage('target')
    when 'recover'
      round = instance.current_round
      return unless recover_allowed_for_round?(round)

      participant.update(
        effort_chosen: 'recover',
        action_chosen: 0
      )
      broadcast_participant_choice
    end
  end

  # === Task Selection ===

  def build_task_options
    options = []
    round = instance.current_round
    return options unless round

    tc = participant[:task_chosen]
    task = tc ? ActivityTask[tc] : nil
    return options unless task

    # Show actions filtered to chosen task
    task.actions.each do |action|
      options << {
        key: action.id.to_s,
        label: action.choice_text,
        description: task_action_description(action, task)
      }
    end

    options << back_option('Return to task selection')
    options
  end

  def handle_task_choice(response)
    if response == 'back'
      participant.update(task_chosen: nil, action_chosen: nil)
      return_to_main_menu
      return
    end

    action_id = response.to_i
    action = ActivityAction[action_id]
    return unless action

    attrs = { action_chosen: action_id }
    attrs[:risk_chosen] = 'yes' if has_risk_dice?(action)
    participant.update(attrs)
    broadcast_participant_choice
    set_stage('willpower')
  end

  # === Action Selection ===

  def build_action_options
    options = []

    round = instance.current_round
    if round
      # If task-based, filter actions to chosen task
      tc = participant[:task_chosen]
      if tc && round.has_tasks?
        task = ActivityTask[tc]
        if task
          task.actions.each do |action|
            options << {
              key: action.id.to_s,
              label: action.choice_text,
              description: task_action_description(action, task)
            }
          end
          options << back_option('Return to task selection')
          return options
        end
      end

      round.available_actions.each do |action|
        options << {
          key: action.id.to_s,
          label: action.choice_text,
          description: action_description(action)
        }
      end
    end

    options << back_option
    options
  end

  def handle_action_choice(response)
    if response == 'back'
      # If task-based, go back to main menu (task selection)
      round = instance.current_round
      if round&.has_tasks?
        participant.update(task_chosen: nil, action_chosen: nil)
        return_to_main_menu
      end
      return
    end

    action_id = response.to_i
    action = ActivityAction[action_id]
    return unless action

    participant.update(action_chosen: action_id)
    broadcast_participant_choice
    set_stage('willpower')
  end

  # === Target Selection (for Help) ===

  def build_target_options
    options = []
    round = instance.current_round
    my_task = participant[:task_chosen]

    instance.active_participants.each do |p|
      next if p.id == participant.id

      # When tasks exist, only show targets on the same task
      if round&.has_tasks? && my_task
        p_task = p[:task_chosen]
        next if p_task != my_task
      end

      char = p.character
      options << {
        key: p.id.to_s,
        label: char&.full_name || 'Participant',
        description: help_target_description(p)
      }
    end

    options << back_option
    options
  end

  def handle_target_choice(response)
    if response == 'back'
      participant.update(effort_chosen: nil)
      return_to_main_menu
      return
    end

    target_id = response.to_i
    target = instance.participants_dataset.where(id: target_id).first
    return unless target

    participant.update(
      action_target: target_id,
      action_chosen: 0
    )
  end

  # === Willpower Selection ===

  def build_willpower_options
    options = []

    available_wp = participant.available_willpower

    WILLPOWER_OPTIONS.each do |key, config|
      wp_cost = key.to_i
      enabled = available_wp >= wp_cost

      options << {
        key: key,
        label: config[:label],
        description: config[:description],
        disabled: !enabled
      }
    end

    options << back_option('Return to action selection')
    options
  end

  def handle_willpower_choice(response)
    if response == 'back'
      participant.update(action_chosen: nil)
      return_to_main_menu
      return
    end

    participant.update(willpower_to_spend: response.to_i)
  end

  # === Helper Methods ===

  def set_stage(_stage)
    # Stage tracked implicitly through participant state
  end

  def pending_help_target?
    participant.effort_chosen == 'help' && participant.action_target.nil?
  end

  def pending_willpower?
    # Regular actions need willpower selection
    # Use raw column value since the model getter masks nil as 0
    participant.action_chosen &&
      participant.action_chosen > 0 &&
      participant.effort_chosen.nil? &&
      participant[:willpower_to_spend].nil?
  end

  def action_complete?
    return false unless participant.action_chosen

    if participant.effort_chosen == 'help'
      !participant.action_target.nil?
    elsif participant.effort_chosen == 'recover'
      true
    else
      # Regular action - willpower selection made (even 0 is valid)
      # Use raw column value since the model getter masks nil as 0
      !participant[:willpower_to_spend].nil?
    end
  end

  def done_validation_message
    return 'Ready to submit' if can_complete?

    'Choose an action first'
  end

  def action_description(action)
    parts = []

    skills = action.skill_ids
    if skills.any?
      stat_names = skills.map do |stat_id|
        stat = Stat.find(id: stat_id)
        stat&.abbreviation || '?'
      end.compact
      parts << "Uses: #{stat_names.join(', ')}"
    end

    if has_risk_dice?(action)
      sides = action.risk_sides_value
      parts << (sides ? "Risk d#{sides}" : 'Risk available')
    end

    parts.empty? ? 'Standard action' : parts.join(' | ')
  end

  def task_action_description(action, task)
    label = action[:stat_set_label] || 'a'
    stat_ids = task.stat_set_for(label)
    parts = []

    if stat_ids.any?
      stat_names = stat_ids.map do |stat_id|
        stat = Stat.find(id: stat_id)
        stat&.abbreviation || '?'
      end.compact
      parts << "Set #{label.upcase}: #{stat_names.join(', ')}"
    end

    if has_risk_dice?(action)
      sides = action.risk_sides_value
      parts << (sides ? "Risk d#{sides}" : 'Risk available')
    end

    parts.empty? ? 'Standard action' : parts.join(' | ')
  end

  def task_stat_description(task)
    parts = []
    if task.stat_set_a&.any?
      names_a = task.stat_set_a.map { |id| Stat.find(id: id)&.abbreviation || '?' }.compact
      parts << "A: #{names_a.join(', ')}"
    end
    if task.stat_set_b?
      names_b = task.stat_set_b.map { |id| Stat.find(id: id)&.abbreviation || '?' }.compact
      parts << "B: #{names_b.join(', ')}"
    end
    parts.empty? ? '' : parts.join(' | ')
  end

  def count_task_assignments
    counts = Hash.new(0)
    instance.active_participants.each do |p|
      tc = p[:task_chosen]
      counts[tc] += 1 if tc
    end
    counts
  end

  def pending_task_action?
    # Task chosen but no action yet (and not help/recover)
    round = instance.current_round
    return false unless round&.has_tasks?

    tc = participant[:task_chosen]
    tc && !participant.action_chosen && participant.effort_chosen.nil?
  end

  def has_risk_dice?(action)
    sides = action.risk_sides_value
    sides && sides > 0
  end

  def broadcast_participant_choice
    ActivityService.broadcast_participant_choice(participant, instance)
  rescue StandardError => e
    warn "[ActivityQuickmenuHandler] Failed to broadcast choice: #{e.message}"
  end

  def help_target_description(target_participant)
    action = target_participant.chosen_action
    if action
      "Choosing: #{action.choice_text}"
    else
      'Still deciding...'
    end
  end

  def recover_allowed_for_round?(round)
    return false unless round
    return false if round.free_roll?
    return false if round.reflex?
    return false if round.group_check?

    true
  end

  def help_allowed_for_round?(round)
    return false unless round
    return false if round.mandatory_roll?
    return false if round.reflex?
    return false if round.group_check?

    true
  end
end
