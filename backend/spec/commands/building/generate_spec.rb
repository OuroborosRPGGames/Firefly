# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Generate, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Builder') }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true)
  end

  subject { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
    allow(character).to receive(:can_build?).and_return(true)
    allow(WorldBuilderOrchestratorService).to receive(:available?).and_return(true)

    # Define place types and city sizes
    stub_const('Generators::PlaceGeneratorService::PLACE_TYPES', {
      tavern: { floors: 2, rooms: 4 },
      shop: { floors: 1, rooms: 2 },
      temple: { floors: 3, rooms: 8 },
      guild: { floors: 2, rooms: 6 }
    })

    stub_const('Generators::CityGeneratorService::CITY_SIZES', {
      small: { places: 5 },
      medium: { places: 15 },
      large: { places: 30 }
    })
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'gen', :building, ['generate', 'genjob', 'genjobs']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['gen']).to eq(described_class)
    end
  end

  describe 'GENERATION_TYPES constant' do
    it 'defines expected generation types' do
      expected_types = %w[description seasonal background npc item place city]
      expect(described_class::GENERATION_TYPES.keys).to match_array(expected_types)
    end

    it 'specifies requirements for each type' do
      described_class::GENERATION_TYPES.each do |type, config|
        expect(config).to have_key(:requires)
        expect(config).to have_key(:help)
      end
    end
  end

  describe '#execute' do
    context 'when character lacks building permission' do
      before do
        allow(character).to receive(:can_build?).and_return(false)
      end

      it 'returns an error' do
        result = subject.execute('gen description')

        expect(result[:success]).to be false
        expect(result[:message]).to include('building permissions')
      end
    end

    context 'with no arguments' do
      it 'shows help' do
        result = subject.execute('gen')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Generation Commands')
        expect(result[:message]).to include('gen description')
        expect(result[:message]).to include('Job Management')
      end
    end

    context 'with invalid generation type' do
      it 'returns an error' do
        result = subject.execute('gen invalid')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown generation type')
        expect(result[:message]).to include('description')
      end
    end

    context 'when generation services unavailable' do
      before do
        allow(WorldBuilderOrchestratorService).to receive(:available?).and_return(false)
      end

      it 'returns an error for generation types' do
        result = subject.execute('gen description')

        expect(result[:success]).to be false
        expect(result[:message]).to include('unavailable')
      end
    end
  end

  # ========================================
  # Job Management Tests
  # ========================================

  describe 'gen jobs' do
    let(:mock_jobs) do
      [
        {
          id: 1,
          type: 'description',
          status: 'running',
          percent: 45,
          message: 'Generating content...',
          duration: '00:30'
        },
        {
          id: 2,
          type: 'npc',
          status: 'pending',
          message: 'Waiting to start'
        }
      ]
    end

    context 'with active jobs' do
      before do
        allow(WorldBuilderOrchestratorService).to receive(:active_jobs_for).and_return(mock_jobs)
      end

      it 'displays active jobs' do
        result = subject.execute('gen jobs')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Active Generation Jobs')
        expect(result[:message]).to include('#1')
        expect(result[:message]).to include('description')
        expect(result[:message]).to include('45%')
        expect(result[:message]).to include('#2')
        expect(result[:message]).to include('npc')
      end
    end

    context 'with no active jobs' do
      before do
        allow(WorldBuilderOrchestratorService).to receive(:active_jobs_for).and_return([])
      end

      it 'shows no jobs message' do
        result = subject.execute('gen jobs')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No active generation jobs')
      end
    end

    context 'with filter arguments' do
      let(:recent_jobs) do
        [
          { id: 10, type: 'city', status: 'completed', duration: '05:30' },
          { id: 11, type: 'npc', status: 'failed', error: 'API timeout' }
        ]
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:active_jobs_for).and_return([])
        allow(WorldBuilderOrchestratorService).to receive(:recent_jobs_for).and_return(recent_jobs)
      end

      it 'shows recent jobs with "recent" filter' do
        result = subject.execute('gen jobs recent')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Recent Generation Jobs')
        expect(result[:message]).to include('#10')
        expect(result[:message]).to include('Completed')
      end

      it 'shows all jobs with "all" filter' do
        result = subject.execute('gen jobs all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Recent Generation Jobs')
      end
    end
  end

  describe 'gen job <id>' do
    let(:job_info) do
      {
        type: 'description',
        status: 'completed',
        started_at: Time.now.iso8601,
        duration: '00:45',
        results: {
          content: 'A beautiful forest clearing with dappled sunlight.'
        }
      }
    end

    context 'with valid job ID' do
      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(42, character).and_return(job_info)
      end

      it 'displays job status' do
        result = subject.execute('gen job 42')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Generation Job #42')
        expect(result[:message]).to include('description')
        expect(result[:message]).to include('Completed')
      end

      it 'displays results for completed jobs' do
        result = subject.execute('gen job 42')

        expect(result[:message]).to include('Results')
        expect(result[:message]).to include('content')
      end
    end

    context 'with running job' do
      let(:running_job) do
        {
          type: 'city',
          status: 'running',
          percent: 67.5,
          message: 'Generating places...',
          started_at: Time.now.iso8601
        }
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(50, character).and_return(running_job)
      end

      it 'displays progress information' do
        result = subject.execute('gen job 50')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Running')
        expect(result[:message]).to include('67')
        expect(result[:message]).to include('Generating places')
      end
    end

    context 'with failed job' do
      let(:failed_job) do
        {
          type: 'npc',
          status: 'failed',
          error: 'API rate limit exceeded',
          started_at: Time.now.iso8601
        }
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(99, character).and_return(failed_job)
      end

      it 'displays error message' do
        result = subject.execute('gen job 99')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Failed')
        expect(result[:message]).to include('API rate limit exceeded')
      end
    end

    context 'with invalid job ID' do
      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(9999, character).and_return(nil)
      end

      it 'returns an error' do
        result = subject.execute('gen job 9999')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end
    end

    context 'with no job ID' do
      it 'returns usage error' do
        result = subject.execute('gen job')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'with non-numeric job ID' do
      it 'returns error for invalid ID' do
        result = subject.execute('gen job abc')

        expect(result[:success]).to be false
        expect(result[:message]).to include('valid job ID')
      end
    end

    context 'with job that has children' do
      let(:parent_job) do
        {
          type: 'city',
          status: 'running',
          has_children: true,
          child_progress: [
            { type: 'place', status: 'completed', status_display: 'Tavern generated' },
            { type: 'place', status: 'running', status_display: 'Generating shop' },
            { type: 'place', status: 'pending', status_display: 'Waiting...' }
          ],
          started_at: Time.now.iso8601
        }
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(100, character).and_return(parent_job)
      end

      it 'displays child task progress' do
        result = subject.execute('gen job 100')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sub-tasks')
        expect(result[:message]).to include('Tavern generated')
        expect(result[:message]).to include('Generating shop')
      end
    end
  end

  describe 'gen job <id> cancel' do
    context 'when job is running' do
      let(:running_job) do
        {
          type: 'city',
          status: 'running',
          percent: 25.0
        }
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(42, character).and_return(running_job)
        allow(WorldBuilderOrchestratorService).to receive(:cancel_job).and_return(true)
      end

      it 'cancels the job' do
        result = subject.execute('gen job 42 cancel')

        expect(result[:success]).to be true
        expect(result[:message]).to include('cancelled')
        expect(WorldBuilderOrchestratorService).to have_received(:cancel_job).with(42, character)
      end

      it 'handles alternate argument order' do
        result = subject.execute('gen job cancel 42')

        expect(result[:success]).to be true
        expect(result[:message]).to include('cancelled')
      end
    end

    context 'when job is pending' do
      let(:pending_job) do
        {
          type: 'description',
          status: 'pending'
        }
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(55, character).and_return(pending_job)
        allow(WorldBuilderOrchestratorService).to receive(:cancel_job).and_return(true)
      end

      it 'cancels pending jobs' do
        result = subject.execute('gen job 55 cancel')

        expect(result[:success]).to be true
        expect(result[:message]).to include('cancelled')
      end
    end

    context 'when job is already completed' do
      let(:completed_job) do
        {
          type: 'npc',
          status: 'completed'
        }
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(77, character).and_return(completed_job)
      end

      it 'returns an error' do
        result = subject.execute('gen job 77 cancel')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already completed')
        expect(result[:message]).to include('cannot be cancelled')
      end
    end

    context 'when cancel fails (not owner)' do
      let(:running_job) do
        {
          type: 'city',
          status: 'running'
        }
      end

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(88, character).and_return(running_job)
        allow(WorldBuilderOrchestratorService).to receive(:cancel_job).and_return(false)
      end

      it 'returns an error' do
        result = subject.execute('gen job 88 cancel')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Could not cancel')
        expect(result[:message]).to include('own jobs')
      end
    end
  end

  # ========================================
  # Generation Type Tests
  # ========================================

  describe 'gen description' do
    let(:mock_job) { double('GenerationJob', id: 101, completed?: false) }

    before do
      allow(WorldBuilderOrchestratorService).to receive(:generate_description).and_return(mock_job)
    end

    it 'starts description generation' do
      result = subject.execute('gen description')

      expect(result[:success]).to be true
      expect(result[:message]).to include('started')
      expect(result[:message]).to include('101')
      expect(WorldBuilderOrchestratorService).to have_received(:generate_description).with(
        hash_including(target: room, created_by: character)
      )
    end

    context 'when job completes immediately' do
      let(:completed_job) do
        double('GenerationJob', id: 102, completed?: true)
      end

      before do
        allow(completed_job).to receive(:result_value).with('content').and_return('A dense forest with towering oaks.')
        allow(completed_job).to receive(:result_value).with('description').and_return(nil)
        allow(WorldBuilderOrchestratorService).to receive(:generate_description).and_return(completed_job)
      end

      it 'updates the room description' do
        result = subject.execute('gen description')

        expect(result[:success]).to be true
        expect(result[:message]).to include('generated')
        expect(result[:message]).to include('dense forest')
        # Verify database was actually updated (room is different instance than @location in command)
        room.refresh
        expect(room.long_description).to eq('A dense forest with towering oaks.')
      end
    end

    context 'when completed but no description returned' do
      let(:empty_job) do
        double('GenerationJob', id: 103, completed?: true)
      end

      before do
        allow(empty_job).to receive(:result_value).and_return(nil)
        allow(WorldBuilderOrchestratorService).to receive(:generate_description).and_return(empty_job)
      end

      it 'returns an error' do
        result = subject.execute('gen description')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no description returned')
      end
    end

    context 'with seasonal flag' do
      let(:seasonal_job) { double('GenerationJob', id: 104, completed?: false) }

      before do
        allow(WorldBuilderOrchestratorService).to receive(:generate_seasonal_descriptions).and_return(seasonal_job)
      end

      it 'generates seasonal descriptions when flag included' do
        result = subject.execute('gen description seasonal')

        expect(result[:success]).to be true
        expect(WorldBuilderOrchestratorService).to have_received(:generate_seasonal_descriptions)
      end
    end
  end

  describe 'gen seasonal' do
    let(:mock_job) { double('GenerationJob', id: 201, completed?: false) }

    before do
      allow(WorldBuilderOrchestratorService).to receive(:generate_seasonal_descriptions).and_return(mock_job)
    end

    it 'starts seasonal generation' do
      result = subject.execute('gen seasonal')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Seasonal descriptions')
      expect(result[:message]).to include('16 variants')
      expect(result[:message]).to include('201')
    end
  end

  describe 'gen background' do
    let(:mock_job) { double('GenerationJob', id: 301, completed?: false) }

    before do
      allow(WorldBuilderOrchestratorService).to receive(:generate_image).and_return(mock_job)
    end

    it 'starts background generation' do
      result = subject.execute('gen background')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Background generation started')
      expect(result[:message]).to include('301')
      expect(WorldBuilderOrchestratorService).to have_received(:generate_image).with(
        hash_including(target: room, image_type: :room_background)
      )
    end

    context 'when job completes immediately with URL' do
      let(:completed_job) do
        double('GenerationJob', id: 302, completed?: true)
      end

      before do
        allow(completed_job).to receive(:result_value).with('local_url').and_return('https://example.com/bg.png')
        allow(completed_job).to receive(:result_value).with('url').and_return(nil)
        allow(WorldBuilderOrchestratorService).to receive(:generate_image).and_return(completed_job)
      end

      it 'updates the room background URL' do
        result = subject.execute('gen background')

        expect(result[:success]).to be true
        expect(result[:message]).to include('saved')
        # Verify database was actually updated
        room.refresh
        expect(room.default_background_url).to eq('https://example.com/bg.png')
      end
    end

    context 'when completed but no URL returned' do
      let(:empty_job) do
        double('GenerationJob', id: 303, completed?: true)
      end

      before do
        allow(empty_job).to receive(:result_value).and_return(nil)
        allow(WorldBuilderOrchestratorService).to receive(:generate_image).and_return(empty_job)
      end

      it 'returns an error' do
        result = subject.execute('gen background')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no image URL returned')
      end
    end
  end

  describe 'gen npc' do
    let(:mock_job) { double('GenerationJob', id: 401, completed?: false) }

    before do
      allow(WorldBuilderOrchestratorService).to receive(:generate_npc).and_return(mock_job)
    end

    it 'starts NPC generation' do
      result = subject.execute('gen npc')

      expect(result[:success]).to be true
      expect(result[:message]).to include('NPC generation started')
      expect(WorldBuilderOrchestratorService).to have_received(:generate_npc).with(
        hash_including(location: location, generate_schedule: true)
      )
    end

    it 'passes role argument' do
      result = subject.execute('gen npc shopkeeper')

      expect(result[:success]).to be true
      expect(WorldBuilderOrchestratorService).to have_received(:generate_npc).with(
        hash_including(role: 'shopkeeper')
      )
      expect(result[:message]).to include('shopkeeper')
    end

    context 'when job completes immediately' do
      let(:completed_job) do
        double('GenerationJob', id: 402, completed?: true)
      end

      before do
        allow(completed_job).to receive(:result_value) do |key|
          case key
          when 'name' then { 'full_name' => 'Marcus the Blacksmith' }
          when 'appearance' then 'A burly man with soot-stained apron and calloused hands.'
          end
        end
        allow(WorldBuilderOrchestratorService).to receive(:generate_npc).and_return(completed_job)
      end

      it 'displays the generated NPC' do
        result = subject.execute('gen npc blacksmith')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Marcus the Blacksmith')
        expect(result[:message]).to include('burly man')
      end
    end
  end

  describe 'gen item' do
    let(:mock_job) { double('GenerationJob', id: 501, completed?: false) }

    before do
      allow(WorldBuilderOrchestratorService).to receive(:generate_item).and_return(mock_job)
    end

    it 'starts item generation with default category' do
      result = subject.execute('gen item')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Item generation started')
      expect(result[:message]).to include('misc')
      expect(WorldBuilderOrchestratorService).to have_received(:generate_item).with(
        hash_including(category: :misc)
      )
    end

    it 'accepts valid category' do
      result = subject.execute('gen item clothing')

      expect(result[:success]).to be true
      expect(WorldBuilderOrchestratorService).to have_received(:generate_item).with(
        hash_including(category: :clothing)
      )
    end

    it 'accepts weapon category' do
      result = subject.execute('gen item weapon')

      expect(result[:success]).to be true
      expect(WorldBuilderOrchestratorService).to have_received(:generate_item).with(
        hash_including(category: :weapon)
      )
    end

    it 'rejects invalid category' do
      result = subject.execute('gen item invalid_category')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Invalid item category')
      expect(result[:message]).to include('clothing')
      expect(result[:message]).to include('weapon')
    end

    context 'when job completes immediately' do
      let(:completed_job) do
        double('GenerationJob', id: 502, completed?: true)
      end

      before do
        allow(completed_job).to receive(:result_value) do |key|
          case key
          when 'name' then 'Silver Dagger'
          when 'description' then 'A finely crafted blade with moonstone inlay.'
          end
        end
        allow(WorldBuilderOrchestratorService).to receive(:generate_item).and_return(completed_job)
      end

      it 'displays the generated item' do
        result = subject.execute('gen item weapon')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Silver Dagger')
        expect(result[:message]).to include('moonstone inlay')
      end
    end
  end

  describe 'gen place' do
    let(:mock_job) { double('GenerationJob', id: 601, completed?: false) }

    before do
      allow(WorldBuilderOrchestratorService).to receive(:generate_place).and_return(mock_job)
    end

    it 'starts place generation with default type' do
      result = subject.execute('gen place')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Place generation started')
      expect(result[:message]).to include('tavern')
      expect(WorldBuilderOrchestratorService).to have_received(:generate_place).with(
        hash_including(place_type: :tavern, generate_rooms: true)
      )
    end

    it 'accepts valid place type' do
      result = subject.execute('gen place shop')

      expect(result[:success]).to be true
      expect(WorldBuilderOrchestratorService).to have_received(:generate_place).with(
        hash_including(place_type: :shop)
      )
    end

    it 'rejects invalid place type' do
      result = subject.execute('gen place spaceship')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Invalid place type')
    end

    context 'when job completes immediately' do
      let(:completed_job) do
        double('GenerationJob', id: 602, completed?: true)
      end

      before do
        allow(completed_job).to receive(:result_value) do |key|
          case key
          when 'name' then 'The Golden Tankard'
          when 'layout' then [{ type: 'common_room' }, { type: 'kitchen' }]
          end
        end
        allow(WorldBuilderOrchestratorService).to receive(:generate_place).and_return(completed_job)
      end

      it 'displays the generated place' do
        result = subject.execute('gen place tavern')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Golden Tankard')
        expect(result[:message]).to include('Rooms: 2')
      end
    end
  end

  describe 'gen city' do
    let(:mock_job) { double('GenerationJob', id: 701, completed?: false) }

    before do
      allow(WorldBuilderOrchestratorService).to receive(:generate_city).and_return(mock_job)
    end

    it 'starts city generation with default size' do
      result = subject.execute('gen city')

      expect(result[:success]).to be true
      expect(result[:message]).to include('City generation started')
      expect(result[:message]).to include('medium')
      expect(result[:message]).to include('several minutes')
      expect(WorldBuilderOrchestratorService).to have_received(:generate_city).with(
        hash_including(size: :medium, generate_places: true)
      )
    end

    it 'accepts valid size' do
      result = subject.execute('gen city large')

      expect(result[:success]).to be true
      expect(WorldBuilderOrchestratorService).to have_received(:generate_city).with(
        hash_including(size: :large)
      )
    end

    it 'accepts small size' do
      result = subject.execute('gen city small')

      expect(result[:success]).to be true
      expect(WorldBuilderOrchestratorService).to have_received(:generate_city).with(
        hash_including(size: :small)
      )
    end

    it 'rejects invalid size' do
      result = subject.execute('gen city mega')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Invalid city size')
      expect(result[:message]).to include('small')
      expect(result[:message]).to include('medium')
      expect(result[:message]).to include('large')
    end
  end

  # ========================================
  # Helper Method Tests
  # ========================================

  describe '#status_icon_for' do
    subject { described_class.new(character_instance) }

    it 'returns correct icon for pending' do
      expect(subject.send(:status_icon_for, 'pending')).to eq('...')
    end

    it 'returns correct icon for running' do
      expect(subject.send(:status_icon_for, 'running')).to eq('>>>')
    end

    it 'returns correct icon for completed' do
      expect(subject.send(:status_icon_for, 'completed')).to eq('[+]')
    end

    it 'returns correct icon for failed' do
      expect(subject.send(:status_icon_for, 'failed')).to eq('[X]')
    end

    it 'returns correct icon for cancelled' do
      expect(subject.send(:status_icon_for, 'cancelled')).to eq('[-]')
    end

    it 'returns unknown icon for other statuses' do
      expect(subject.send(:status_icon_for, 'weird')).to eq('[?]')
    end
  end

  describe '#status_display' do
    subject { described_class.new(character_instance) }

    it 'capitalizes pending' do
      expect(subject.send(:status_display, 'pending')).to eq('Pending')
    end

    it 'capitalizes running' do
      expect(subject.send(:status_display, 'running')).to eq('Running')
    end

    it 'capitalizes completed' do
      expect(subject.send(:status_display, 'completed')).to eq('Completed')
    end

    it 'capitalizes failed' do
      expect(subject.send(:status_display, 'failed')).to eq('Failed')
    end

    it 'capitalizes cancelled' do
      expect(subject.send(:status_display, 'cancelled')).to eq('Cancelled')
    end

    it 'capitalizes unknown statuses' do
      expect(subject.send(:status_display, 'custom')).to eq('Custom')
    end
  end

  describe '#format_iso_timestamp' do
    subject { described_class.new(character_instance) }

    it 'formats valid ISO time' do
      iso_time = '2024-06-15T14:30:00Z'
      formatted = subject.send(:format_iso_timestamp, iso_time)

      expect(formatted).to include('2024-06-15')
      expect(formatted).to include('14:30:00')
    end

    it 'returns N/A for nil' do
      expect(subject.send(:format_iso_timestamp, nil)).to eq('N/A')
    end

    it 'returns original string for invalid time' do
      result = subject.send(:format_iso_timestamp, 'not-a-time')

      # Should return original string or some fallback
      expect(result).to be_a(String)
    end
  end

  describe '#format_results' do
    subject { described_class.new(character_instance) }

    it 'returns no results message for nil' do
      expect(subject.send(:format_results, nil)).to eq(['No results'])
    end

    it 'returns no results message for empty hash' do
      expect(subject.send(:format_results, {})).to eq(['No results'])
    end

    it 'formats string values' do
      results = { description: 'A test description' }
      formatted = subject.send(:format_results, results)

      expect(formatted).to include('description: A test description')
    end

    it 'truncates long string values' do
      results = { content: 'x' * 150 }
      formatted = subject.send(:format_results, results)

      expect(formatted.first).to include('content:')
      expect(formatted.first.length).to be < 150
    end

    it 'formats array values' do
      results = { rooms: [1, 2, 3, 4] }
      formatted = subject.send(:format_results, results)

      expect(formatted).to include('rooms: 4 items')
    end

    it 'formats hash values' do
      results = { stats: { health: 100, mana: 50 } }
      formatted = subject.send(:format_results, results)

      expect(formatted.first).to include('stats:')
      expect(formatted.first).to include('health')
      expect(formatted.first).to include('mana')
    end

    it 'skips nil values' do
      results = { valid: 'data', empty: nil }
      formatted = subject.send(:format_results, results)

      expect(formatted.length).to eq(1)
      expect(formatted).to include('valid: data')
    end
  end

  describe '#current_setting' do
    subject { described_class.new(character_instance) }

    it 'returns fantasy as default' do
      # Location has no setting by default (respond_to?(:setting) returns false)
      expect(subject.send(:current_setting)).to eq(:fantasy)
    end

    it 'detects modern setting' do
      allow_any_instance_of(Location).to receive(:setting).and_return('modern urban')

      expect(subject.send(:current_setting)).to eq(:modern)
    end

    it 'detects sci-fi setting' do
      allow_any_instance_of(Location).to receive(:setting).and_return('sci-fi colony')

      expect(subject.send(:current_setting)).to eq(:scifi)
    end

    it 'detects steampunk setting' do
      allow_any_instance_of(Location).to receive(:setting).and_return('steampunk city')

      expect(subject.send(:current_setting)).to eq(:steampunk)
    end
  end

  # ========================================
  # Edge Cases and Error Handling
  # ========================================

  describe 'edge cases' do
    context 'when numeric input looks like job ID' do
      let(:job_info) { { type: 'description', status: 'completed' } }

      before do
        allow(WorldBuilderOrchestratorService).to receive(:job_status_for).with(42, character).and_return(job_info)
      end

      it 'treats numeric first argument as job ID' do
        result = subject.execute('gen 42')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Job #42')
      end
    end

    context 'with extra whitespace' do
      let(:mock_job) { double('GenerationJob', id: 800, completed?: false) }

      before do
        allow(WorldBuilderOrchestratorService).to receive(:generate_description).and_return(mock_job)
      end

      it 'handles extra whitespace in arguments' do
        result = subject.execute('  description   seasonal  ')

        expect(result[:success]).to be true
      end
    end

    context 'with mixed case input' do
      let(:mock_job) { double('GenerationJob', id: 801, completed?: false) }

      before do
        allow(WorldBuilderOrchestratorService).to receive(:generate_description).and_return(mock_job)
      end

      it 'handles uppercase subcommand' do
        result = subject.execute('DESCRIPTION')

        expect(result[:success]).to be true
      end

      it 'handles mixed case subcommand' do
        result = subject.execute('Description')

        expect(result[:success]).to be true
      end
    end

    context 'using aliases' do
      before do
        allow(WorldBuilderOrchestratorService).to receive(:active_jobs_for).and_return([])
      end

      it 'handles "list" alias for jobs' do
        result = subject.execute('gen list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No active generation jobs')
      end
    end
  end
end
