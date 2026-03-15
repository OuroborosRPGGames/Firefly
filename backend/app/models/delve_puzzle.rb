# frozen_string_literal: true

# DelvePuzzle represents a puzzle blocking progression in a room.
# Types: symbol_grid, pipe_network, toggle_matrix
return unless DB.table_exists?(:delve_puzzles)

class DelvePuzzle < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  # Note: puzzle_data and current_state are jsonb columns - Sequel handles
  # serialization automatically for jsonb, so no serialization plugin needed.

  many_to_one :delve_room

  PUZZLE_TYPES = %w[symbol_grid pipe_network toggle_matrix].freeze
  DIFFICULTIES = %w[easy medium hard expert].freeze

  def validate
    super
    validates_presence [:delve_room_id, :puzzle_type, :seed]
    validates_includes PUZZLE_TYPES, :puzzle_type if puzzle_type
    validates_includes DIFFICULTIES, :difficulty if difficulty
    validates_unique :delve_room_id
  end

  def before_save
    super
    self.difficulty ||= 'medium'
    self.hints_used ||= 0
    self.solved = false if solved.nil?
    self.puzzle_data ||= {}
    self.current_state ||= {}
  end

  # ====== State Checks ======

  def solved?
    !!solved
  end

  # Does this puzzle block a specific exit direction?
  # nil direction means it blocks all exits (legacy behavior)
  def blocks_direction?(dir)
    direction.nil? || direction == dir
  end

  # ====== Actions ======

  # Mark puzzle as solved
  def solve!
    update(solved: true, solved_at: Time.now)
  end

  # Increment hints counter
  def increment_hints!
    update(hints_used: (hints_used || 0) + 1)
  end

  # Update current puzzle state (for partial progress)
  def update_state!(new_state)
    update(current_state: new_state)
  end

  # ====== Puzzle Data Access ======

  # Get the solution from puzzle data
  def solution
    puzzle_data['solution']
  end

  # Get the initial grid/layout
  def initial_layout
    puzzle_data['initial'] || puzzle_data['layout']
  end

  # Get clues for the puzzle
  def clues
    puzzle_data['clues'] || []
  end

  # Get grid size
  def grid_size
    puzzle_data['size'] || 6
  end

  # ====== Display ======

  def description
    case puzzle_type
    when 'symbol_grid'
      "A grid of symbols covers the wall. Each symbol must appear exactly once in every row and column. Fill in the blanks to proceed."
    when 'pipe_network'
      'Pipes twist and turn. Connect the flow from source to drain.'
    when 'toggle_matrix'
      'A matrix of switches glows. Toggle them all to the same state.'
    else
      'A puzzle blocks the way.'
    end
  end

  # Get difficulty description
  def difficulty_description
    case difficulty
    when 'easy' then 'A simple puzzle with many clues.'
    when 'medium' then 'A moderate challenge awaits.'
    when 'hard' then 'This puzzle requires careful thought.'
    when 'expert' then 'A fiendishly difficult puzzle.'
    else 'A puzzle of unknown difficulty.'
    end
  end
end
