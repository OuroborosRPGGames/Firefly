# frozen_string_literal: true

# Shared context for Auto-GM service specs
# Uses doubles exclusively to avoid database interactions

RSpec.shared_context 'auto_gm_setup' do
  let(:universe) { double('Universe', id: 1, default_currency: double('Currency', name: 'Gold', symbol: 'g')) }
  let(:world) { double('World', id: 1, universe: universe) }
  let(:zone) { double('Zone', id: 1, world: world) }
  let(:room_location) { double('Location', id: 10, name: 'Test Location', rooms: [], zone: zone) }

  let(:passable_exits) { [] }

  let(:room_char_instances_dataset) do
    double('Dataset').tap do |d|
      allow(d).to receive(:where).and_return(d)
      allow(d).to receive(:all).and_return([])
    end
  end

  let(:room) do
    double('Room',
           id: 1,
           name: 'Adventure Room',
           description: 'A mysterious place full of adventure.',
           room_type: 'standard',
           location_id: 10,
           location: room_location,
           passable_exits: passable_exits,
           character_instances_dataset: room_char_instances_dataset,
           visible_places: [])
  end

  let(:character) do
    double('Character',
           id: 1,
           name: 'Test Hero',
           forename: 'Test',
           surname: 'Hero',
           npc?: false)
  end

  let(:char_instance) do
    double('CharacterInstance',
           id: 1,
           character_id: 1,
           character: character,
           current_room: room,
           current_room_id: room.id,
           online: true,
           is_npc: false,
           movement_state: nil,
           wallets_dataset: double('Dataset', first: nil),
           teleport_to_room!: true)
  end

  let(:sketch) do
    {
      'title' => 'The Lost Temple',
      'noun' => { 'type' => 'artefact', 'adjective' => 'powerful', 'name' => 'Crystal of Light' },
      'mission' => {
        'type' => 'discover',
        'objective' => 'Find the Crystal of Light',
        'success_conditions' => ['Find the crystal', 'Return safely'],
        'failure_conditions' => ['All characters defeated', 'Crystal destroyed']
      },
      'setting' => { 'flavor' => 'fantasy', 'mood' => 'mysterious' },
      'rewards_perils' => {
        'rewards' => ['100 gold coins', 'Magic item'],
        'perils' => ['Traps', 'Monsters']
      },
      'secrets_twists' => {
        'secrets' => ['The guardian is friendly', 'There is a shortcut'],
        'twist_type' => 'hidden_ally',
        'twist_trigger' => 'Final confrontation',
        'twist_description' => 'The enemy is actually an ally'
      },
      'inciting_incident' => {
        'type' => 'discovery',
        'description' => 'A map falls from an old book',
        'immediate_threat' => false
      },
      'structure' => {
        'type' => 'three_act',
        'stages' => [
          { 'name' => 'Discovery', 'description' => 'Find the clue', 'is_climax' => false },
          { 'name' => 'Journey', 'description' => 'Travel to location', 'is_climax' => false },
          { 'name' => 'Confrontation', 'description' => 'Face the guardian', 'is_climax' => true },
          { 'name' => 'Resolution', 'description' => 'Return with crystal', 'is_climax' => false }
        ]
      },
      'locations_used' => [],
      'npcs_to_spawn' => []
    }
  end

  let(:auto_gm_actions_dataset) do
    double('ActionsDataset',
           count: 0,
           empty?: true,
           max: nil,
           all: [],
           first: nil,
           order: double('Dataset', first: nil, all: [], limit: double('Dataset', all: [])),
           exclude: double('Dataset', count: 0, order: double('Dataset', first: nil, all: [])),
           where: double('Dataset', order: double('Dataset', first: nil, all: []), all: [], count: 0, exclude: double('Dataset', order: double('Dataset', limit: double('Dataset', all: [])))))
  end

  let(:auto_gm_summaries_dataset) do
    double('SummariesDataset',
           count: 0,
           all: [],
           first: nil,
           order: double('Dataset', first: nil),
           where: double('Dataset', order: double('Dataset', first: nil), all: []))
  end

  let(:session) do
    double('AutoGmSession',
           id: 1,
           status: 'running',
           starting_room: room,
           starting_room_id: room.id,
           current_room: room,
           current_room_id: room.id,
           participant_ids: [char_instance.id],
           participant_instances: [char_instance],
           chaos_level: 5,
           current_stage: 0,
           countdown: nil,
           sketch: sketch,
           world_state: {},
           memory_context: {},
           brainstorm_outputs: {},
           started_at: Time.now - 300,
           last_action_at: nil,
           created_at: Time.now - 600,
           resolved_at: nil,
           resolution_type: nil,
           location_ids_used: [],
           in_combat?: false,
           resolved?: false,
           reload: nil,
           update: true,
           adjust_chaos!: true,
           advance_stage!: true,
           resolve!: true,
           auto_gm_actions_dataset: auto_gm_actions_dataset,
           auto_gm_actions: [],
           auto_gm_summaries_dataset: auto_gm_summaries_dataset,
           available_stats: [],
           stat_names_for_prompt: 'No stats available',
           resolve_stat_by_name: nil,
           stat_values_for: [],
           stat_block_id: nil,
           current_stage_info: nil,
           loop_heartbeat_at: nil,
           loop_owner: nil)
  end

  let(:action) do
    double('AutoGmAction',
           id: 1,
           session_id: 1,
           action_type: 'emit',
           status: 'pending',
           emit_text: 'The adventure begins.',
           action_data: {},
           ai_reasoning: nil,
           sequence_number: 1,
           created_at: Time.now,
           update: true,
           complete!: true,
           fail!: true,
           failed?: false,
           mark_completed!: true)
  end

  before do
    # Stub BroadcastService to avoid actual broadcasts
    allow(BroadcastService).to receive(:to_room)
    allow(BroadcastService).to receive(:to_character)

    # Stub IC activity logging side effects
    allow(IcActivityService).to receive(:record)
    allow(IcActivityService).to receive(:record_for)

    # Stub LLM calls
    allow(LLM::Client).to receive(:generate).and_return({
      success: true,
      text: 'The adventure continues...',
      usage: { 'output_tokens' => 100 }
    })

    # Stub GamePrompts
    allow(GamePrompts).to receive(:get).and_return('prompt text')

    # Stub DisplayHelper
    allow(DisplayHelper).to receive(:character_display_name).and_return('Test Hero')

    # Stub AutoGmAction creation
    allow(AutoGmAction).to receive(:create).and_return(action)
    allow(AutoGmAction).to receive(:create_emit).and_return(action)
    allow(AutoGmAction).to receive(:create_with_next_sequence).and_return(action)

    # Stub AutoGmSummary
    allow(AutoGmSummary).to receive(:best_for_context).and_return(nil)
    allow(AutoGmSummary).to receive(:needs_abstraction?).and_return(false)

    # Stub Room lookup
    allow(Room).to receive(:[]).and_return(room)

    # Stub CharacterInstance lookup
    allow(CharacterInstance).to receive(:[]).and_return(char_instance)

    # Stub MovementService to avoid real movement
    allow(MovementService).to receive(:start_movement).and_return({ success: true })

    # Stub SeedTermService
    allow(SeedTermService).to receive(:for_generation).and_return(['mystery', 'artifact', 'ancient'])

    # Stub AIProviderService
    allow(AIProviderService).to receive(:provider_available?).and_return(true)

    # Stub Redis for LootTracker
    allow(AutoGm::LootTracker).to receive(:remaining_allowance).and_return(1000)
    allow(AutoGm::LootTracker).to receive(:record_loot).and_return(true)
  end
end

# Alias for backward compatibility
RSpec.shared_context 'auto_gm_session_dataset' do
  include_context 'auto_gm_setup'
end
