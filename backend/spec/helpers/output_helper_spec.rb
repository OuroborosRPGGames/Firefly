# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OutputHelper do
  # Create a test class that includes the helper
  let(:test_class) do
    Class.new do
      include OutputHelper
      attr_accessor :env

      def initialize(env = {})
        @env = env
      end
    end
  end

  let(:helper) { test_class.new }
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#agent_mode?' do
    context 'when env is nil' do
      it 'returns false' do
        helper.env = nil
        expect(helper.agent_mode?).to be false
      end
    end

    context 'when env is not a Hash' do
      it 'returns false' do
        helper.env = 'not a hash'
        expect(helper.agent_mode?).to be false
      end
    end

    context 'when firefly.agent_mode is true' do
      it 'returns true' do
        helper.env = { 'firefly.agent_mode' => true }
        expect(helper.agent_mode?).to be true
      end
    end

    context 'when HTTP_X_OUTPUT_MODE is agent' do
      it 'returns true' do
        helper.env = { 'HTTP_X_OUTPUT_MODE' => 'agent' }
        expect(helper.agent_mode?).to be true
      end
    end

    context 'when PATH_INFO starts with /api/agent' do
      it 'returns true' do
        helper.env = { 'PATH_INFO' => '/api/agent/message' }
        expect(helper.agent_mode?).to be true
      end
    end

    context 'when no agent indicators present' do
      it 'returns false' do
        helper.env = { 'PATH_INFO' => '/webclient' }
        expect(helper.agent_mode?).to be false
      end
    end
  end

  describe '#render_output' do
    context 'in agent mode' do
      before { helper.env = { 'firefly.agent_mode' => true } }

      it 'renders agent output' do
        result = helper.render_output(type: :message, data: { content: 'Hello' })

        expect(result[:type]).to eq(:message)
        expect(result[:structured]).to eq({ content: 'Hello' })
        expect(result[:timestamp]).to be_a(String)
      end

      it 'includes target_panel when provided' do
        result = helper.render_output(type: :message, data: { content: 'Hello' }, target_panel: 'main')

        expect(result[:target_panel]).to eq('main')
      end
    end

    context 'in webclient mode' do
      before { helper.env = {} }

      it 'renders webclient output' do
        result = helper.render_output(type: :message, data: { content: 'Hello' })

        expect(result[:type]).to eq(:message)
        expect(result[:message_type]).to eq('message')
        expect(result[:timestamp]).to be_a(String)
      end

      it 'includes target_panel when provided' do
        result = helper.render_output(type: :message, data: { content: 'Hello' }, target_panel: 'sidebar')

        expect(result[:target_panel]).to eq('sidebar')
      end
    end
  end

  describe '#create_quickmenu' do
    let(:options) do
      [
        { key: '1', label: 'Option 1', description: 'First option' },
        { key: '2', label: 'Option 2', description: 'Second option' }
      ]
    end

    before do
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    it 'creates a quickmenu with interaction_id' do
      result = helper.create_quickmenu(char_instance, 'Choose wisely', options)

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
      expect(result[:interaction_id]).to be_a(String)
      expect(result[:data][:prompt]).to eq('Choose wisely')
      expect(result[:data][:options].length).to eq(2)
    end

    it 'stores the interaction' do
      helper.create_quickmenu(char_instance, 'Choose wisely', options)

      expect(OutputHelper).to have_received(:store_agent_interaction).with(
        char_instance,
        anything,
        hash_including(type: 'quickmenu', prompt: 'Choose wisely')
      )
    end

    it 'auto-generates keys when not provided' do
      options_without_keys = [
        { label: 'Option A' },
        { label: 'Option B' }
      ]
      result = helper.create_quickmenu(char_instance, 'Pick one', options_without_keys)

      expect(result[:data][:options][0][:key]).to eq('1')
      expect(result[:data][:options][1][:key]).to eq('2')
    end

    it 'uses name as label when label not provided' do
      options_with_name = [
        { key: '1', name: 'Named Option' }
      ]
      result = helper.create_quickmenu(char_instance, 'Pick', options_with_name)

      expect(result[:data][:options][0][:label]).to eq('Named Option')
    end

    it 'includes context data' do
      result = helper.create_quickmenu(char_instance, 'Pick', options, context: { action: 'test' })

      expect(OutputHelper).to have_received(:store_agent_interaction).with(
        char_instance,
        anything,
        hash_including(context: { action: 'test' })
      )
    end

    context 'in agent mode' do
      before { helper.env = { 'firefly.agent_mode' => true } }

      it 'does not include HTML message' do
        result = helper.create_quickmenu(char_instance, 'Pick', options)

        expect(result[:message]).to be_nil
      end
    end

    context 'in webclient mode' do
      before { helper.env = {} }

      it 'includes HTML message as fallback' do
        result = helper.create_quickmenu(char_instance, 'Pick', options)

        expect(result[:message]).to include('quickmenu')
        expect(result[:message]).to include('Pick')
      end
    end
  end

  describe '#create_form' do
    let(:fields) do
      [
        { name: 'username', label: 'Username', type: 'text', required: true },
        { name: 'age', label: 'Age', type: 'number', min: 0, max: 150 }
      ]
    end

    before do
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    it 'creates a form with interaction_id' do
      result = helper.create_form(char_instance, 'Registration', fields)

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:form)
      expect(result[:interaction_id]).to be_a(String)
      expect(result[:data][:title]).to eq('Registration')
      expect(result[:data][:fields].length).to eq(2)
    end

    it 'stores the interaction' do
      helper.create_form(char_instance, 'Registration', fields)

      expect(OutputHelper).to have_received(:store_agent_interaction).with(
        char_instance,
        anything,
        hash_including(type: 'form', title: 'Registration')
      )
    end

    it 'normalizes field definitions' do
      fields_minimal = [
        { name: 'input1' }
      ]
      result = helper.create_form(char_instance, 'Form', fields_minimal)

      field = result[:data][:fields].first
      expect(field[:label]).to eq('Input1') # Capitalized name
      expect(field[:type]).to eq('text')    # Default type
      expect(field[:required]).to eq(false) # Default required
    end

    it 'includes optional field properties' do
      fields_full = [
        {
          name: 'role',
          label: 'Role',
          type: 'select',
          options: [{ value: 'admin', label: 'Admin' }],
          default: 'admin',
          placeholder: 'Select role'
        }
      ]
      result = helper.create_form(char_instance, 'Form', fields_full)

      field = result[:data][:fields].first
      expect(field[:options]).to eq([{ value: 'admin', label: 'Admin' }])
      expect(field[:default]).to eq('admin')
      expect(field[:placeholder]).to eq('Select role')
    end

    context 'in agent mode' do
      before { helper.env = { 'firefly.agent_mode' => true } }

      it 'does not include HTML message' do
        result = helper.create_form(char_instance, 'Form', fields)

        expect(result[:message]).to be_nil
      end
    end

    context 'in webclient mode' do
      before { helper.env = {} }

      it 'includes HTML message as fallback' do
        result = helper.create_form(char_instance, 'Form', fields)

        expect(result[:message]).to include('form-popup')
        expect(result[:message]).to include('Form')
      end
    end
  end

  describe 'format_output' do
    describe 'room formatting' do
      let(:room_data) do
        {
          room: { name: 'Town Square', description: 'A bustling public space.' },
          characters: [{ name: 'Bob' }, { name: 'Alice' }],
          exits: [
            { direction: 'north', to_room_name: 'Market', distance: 1, direction_arrow: '↑' }
          ]
        }
      end

      context 'HTML output' do
        it 'formats room with HTML' do
          result = helper.send(:format_output, :room, room_data, html: true)

          expect(result).to include('<h3>Town Square</h3>')
          expect(result).to include('A bustling public space.')
          expect(result).to include('Also here: Bob, Alice')
          expect(result).to include('Market')
          expect(result).to include('<sup>1↑</sup>')
        end

        it 'escapes HTML in room name' do
          room_data[:room][:name] = '<script>alert("xss")</script>'
          result = helper.send(:format_output, :room, room_data, html: true)

          expect(result).not_to include('<script>')
          expect(result).to include('&lt;script&gt;')
        end

        it 'handles locked exits' do
          room_data[:exits][0][:locked] = true
          result = helper.send(:format_output, :room, room_data, html: true)

          expect(result).to include('obs-exit-locked')
        end

        it 'uses styled name when available' do
          room_data[:exits][0][:to_room_styled_name] = '<span class="fancy">Market</span>'
          result = helper.send(:format_output, :room, room_data, html: true)

          expect(result).to include('<span class="fancy">Market</span>')
        end
      end

      context 'text output' do
        it 'formats room without HTML' do
          result = helper.send(:format_output, :room, room_data, html: false)

          expect(result).to include('**Town Square**')
          expect(result).to include('A bustling public space.')
          expect(result).to include('Characters: Bob, Alice')
          expect(result).to include('Exits: Market')
        end

        it 'includes distance tag when present' do
          room_data[:exits][0][:distance_tag] = '1↑'
          result = helper.send(:format_output, :room, room_data, html: false)

          expect(result).to include('Market (1↑)')
        end
      end

      context 'with thumbnails' do
        let(:room_data_with_thumbnails) do
          room_data.merge(thumbnails: [
            { url: 'https://example.com/img1.jpg', alt: 'Town Square view' }
          ])
        end

        it 'includes thumbnails in HTML' do
          result = helper.send(:format_output, :room, room_data_with_thumbnails, html: true)

          expect(result).to include('obs-thumbnails')
          expect(result).to include('https://example.com/img1.jpg')
        end

        it 'includes thumbnail URLs in text' do
          result = helper.send(:format_output, :room, room_data_with_thumbnails, html: false)

          expect(result).to include('Images: https://example.com/img1.jpg')
        end
      end

      context 'with characters in places' do
        let(:room_data_with_places) do
          {
            room: { name: 'Tavern', description: 'A cozy tavern.' },
            characters_ungrouped: [{ name: 'Bob' }],
            places: [
              { name: 'Bar', characters: [{ name: 'Bartender' }] }
            ],
            exits: []
          }
        end

        it 'collects characters from places and ungrouped' do
          result = helper.send(:format_output, :room, room_data_with_places, html: true)

          expect(result).to include('Bob')
          expect(result).to include('Bartender')
        end
      end
    end

    describe 'message formatting' do
      context 'say messages' do
        it 'formats say message with quotes' do
          data = { type: 'say', sender: 'Alice', content: 'Hello world' }
          result = helper.send(:format_output, :message, data, html: false)

          expect(result).to eq('Alice says, "Hello world"')
        end

        it 'escapes HTML in say messages' do
          data = { type: 'say', sender: 'Alice', content: '<script>bad</script>' }
          result = helper.send(:format_output, :message, data, html: true)

          expect(result).to include('&lt;script&gt;')
        end
      end

      context 'emote messages' do
        it 'formats emote content directly' do
          data = { type: 'emote', content: 'Alice waves hello' }
          result = helper.send(:format_output, :message, data, html: false)

          expect(result).to eq('Alice waves hello')
        end
      end

      context 'other messages' do
        it 'formats content directly' do
          data = { type: 'system', content: 'Server restarting...' }
          result = helper.send(:format_output, :message, data, html: false)

          expect(result).to eq('Server restarting...')
        end
      end
    end

    describe 'error formatting' do
      it 'wraps error in span for HTML' do
        data = { message: 'Something went wrong' }
        result = helper.send(:format_output, :error, data, html: true)

        expect(result).to eq("<span class='error'>Something went wrong</span>")
      end

      it 'returns plain message for text' do
        data = { message: 'Something went wrong' }
        result = helper.send(:format_output, :error, data, html: false)

        expect(result).to eq('Something went wrong')
      end

      it 'escapes HTML in error messages' do
        data = { message: '<script>xss</script>' }
        result = helper.send(:format_output, :error, data, html: true)

        expect(result).to include('&lt;script&gt;')
      end
    end

    describe 'action formatting' do
      it 'returns nil to preserve original message' do
        data = { action: 'attack', target: 'enemy' }
        result = helper.send(:format_output, :action, data, html: true)

        expect(result).to be_nil
      end

      it 'returns nil for combat type' do
        data = { action: 'combat' }
        result = helper.send(:format_output, :combat, data, html: true)

        expect(result).to be_nil
      end

      it 'returns nil for movement type' do
        data = { direction: 'north' }
        result = helper.send(:format_output, :movement, data, html: true)

        expect(result).to be_nil
      end
    end

    describe 'quickmenu formatting' do
      let(:quickmenu_data) do
        {
          prompt: 'What do you want to do?',
          options: [
            { key: '1', label: 'Attack', description: 'Strike the enemy' },
            { key: '2', label: 'Defend' }
          ]
        }
      end

      context 'HTML output' do
        it 'formats quickmenu as HTML' do
          result = helper.send(:format_output, :quickmenu, quickmenu_data, html: true)

          expect(result).to include('quickmenu')
          expect(result).to include('What do you want to do?')
          expect(result).to include('<ol')
          expect(result).to include('Attack')
          expect(result).to include('Strike the enemy')
        end
      end

      context 'text output' do
        it 'formats quickmenu as text' do
          result = helper.send(:format_output, :quickmenu, quickmenu_data, html: false)

          expect(result).to include('**What do you want to do?**')
          expect(result).to include('[1] Attack - Strike the enemy')
          expect(result).to include('[2] Defend')
          expect(result).to include('respond_to_interaction')
        end
      end
    end

    describe 'form formatting' do
      let(:form_data) do
        {
          title: 'Character Creation',
          fields: [
            { name: 'name', label: 'Name', type: 'text', required: true },
            { name: 'class', label: 'Class', type: 'select', options: [{ value: 'warrior', label: 'Warrior' }] }
          ]
        }
      end

      context 'HTML output' do
        it 'formats form as HTML' do
          result = helper.send(:format_output, :form, form_data, html: true)

          expect(result).to include('form-popup')
          expect(result).to include('Character Creation')
          expect(result).to include("name='name'")
          expect(result).to include("name='class'")
          expect(result).to include('required')
        end
      end

      context 'text output' do
        it 'formats form as text' do
          result = helper.send(:format_output, :form, form_data, html: false)

          expect(result).to include('**Character Creation**')
          expect(result).to include('name (text) (required): Name')
          expect(result).to include('class (select): Class')
          expect(result).to include('[options: Warrior]')
          expect(result).to include('respond_to_interaction')
        end
      end
    end

    describe 'unknown type' do
      it 'returns nil for unknown types' do
        result = helper.send(:format_output, :unknown_type, {}, html: true)

        expect(result).to be_nil
      end
    end
  end

  describe 'form field rendering' do
    describe '#render_form_field' do
      it 'renders text input' do
        field = { name: 'username', type: 'text', placeholder: 'Enter username' }
        result = helper.send(:render_form_field, field)

        expect(result).to include("type='text'")
        expect(result).to include("name='username'")
        expect(result).to include("placeholder='Enter username'")
      end

      it 'renders textarea' do
        field = { name: 'bio', type: 'textarea', placeholder: 'Tell us about yourself' }
        result = helper.send(:render_form_field, field)

        expect(result).to include('<textarea')
        expect(result).to include("name='bio'")
      end

      it 'renders select with options' do
        field = {
          name: 'role',
          type: 'select',
          options: [
            { value: 'admin', label: 'Administrator' },
            { value: 'user', label: 'Regular User' }
          ],
          default: 'user'
        }
        result = helper.send(:render_form_field, field)

        expect(result).to include('<select')
        expect(result).to include("value='admin'")
        expect(result).to include('Administrator')
        expect(result).to include(' selected')
      end

      it 'renders number input with min/max' do
        field = { name: 'age', type: 'number', min: 0, max: 120 }
        result = helper.send(:render_form_field, field)

        expect(result).to include("type='number'")
        expect(result).to include("min='0'")
        expect(result).to include("max='120'")
      end

      it 'renders checkbox' do
        field = { name: 'agree', type: 'checkbox', default: true }
        result = helper.send(:render_form_field, field)

        expect(result).to include("type='checkbox'")
        expect(result).to include(' checked')
      end

      it 'adds required attribute' do
        field = { name: 'email', type: 'text', required: true }
        result = helper.send(:render_form_field, field)

        expect(result).to include(' required')
      end
    end
  end

  describe 'class methods for Redis storage' do
    let(:redis_double) { instance_double('Redis') }
    let(:redis_pool) { double('ConnectionPool') }

    before do
      stub_const('REDIS_POOL', redis_pool)
      allow(redis_pool).to receive(:with).and_yield(redis_double)
    end

    describe '.store_agent_interaction' do
      it 'stores interaction in Redis with TTL' do
        allow(redis_double).to receive(:setex)
        allow(redis_double).to receive(:sadd)
        allow(redis_double).to receive(:expire)

        data = { type: 'quickmenu', prompt: 'Test' }
        described_class.store_agent_interaction(char_instance, 'int-123', data)

        expect(redis_double).to have_received(:setex).with(
          "agent_interaction:#{char_instance.id}:int-123",
          600,
          JSON.generate(data)
        )
      end

      it 'adds to pending list' do
        allow(redis_double).to receive(:setex)
        allow(redis_double).to receive(:sadd)
        allow(redis_double).to receive(:expire)

        described_class.store_agent_interaction(char_instance, 'int-123', {})

        expect(redis_double).to have_received(:sadd).with(
          "agent_pending:#{char_instance.id}",
          'int-123'
        )
      end

      it 'handles errors gracefully' do
        allow(redis_double).to receive(:setex).and_raise(StandardError.new('Redis down'))

        expect {
          described_class.store_agent_interaction(char_instance, 'int-123', {})
        }.not_to raise_error
      end
    end

    describe '.get_agent_interaction' do
      it 'retrieves interaction from Redis' do
        data = { type: 'quickmenu', prompt: 'Test' }
        allow(redis_double).to receive(:get).and_return(JSON.generate(data))

        result = described_class.get_agent_interaction(char_instance.id, 'int-123')

        expect(result[:type]).to eq('quickmenu')
        expect(result[:prompt]).to eq('Test')
      end

      it 'returns nil when not found' do
        allow(redis_double).to receive(:get).and_return(nil)

        result = described_class.get_agent_interaction(char_instance.id, 'int-123')

        expect(result).to be_nil
      end

      it 'handles errors gracefully' do
        allow(redis_double).to receive(:get).and_raise(StandardError.new('Redis down'))

        result = described_class.get_agent_interaction(char_instance.id, 'int-123')

        expect(result).to be_nil
      end
    end

    describe '.get_pending_interactions' do
      it 'retrieves all pending interactions' do
        allow(redis_double).to receive(:smembers).and_return(['int-1', 'int-2'])
        allow(redis_double).to receive(:get).with("agent_interaction:#{char_instance.id}:int-1")
                                            .and_return(JSON.generate({ type: 'quickmenu' }))
        allow(redis_double).to receive(:get).with("agent_interaction:#{char_instance.id}:int-2")
                                            .and_return(JSON.generate({ type: 'form' }))

        result = described_class.get_pending_interactions(char_instance.id)

        expect(result.length).to eq(2)
        expect(result[0][:type]).to eq('quickmenu')
        expect(result[1][:type]).to eq('form')
      end

      it 'filters out nil results' do
        allow(redis_double).to receive(:smembers).and_return(['int-1', 'int-2'])
        allow(redis_double).to receive(:get).with("agent_interaction:#{char_instance.id}:int-1")
                                            .and_return(JSON.generate({ type: 'quickmenu' }))
        allow(redis_double).to receive(:get).with("agent_interaction:#{char_instance.id}:int-2")
                                            .and_return(nil)

        result = described_class.get_pending_interactions(char_instance.id)

        expect(result.length).to eq(1)
      end

      it 'handles errors gracefully' do
        allow(redis_double).to receive(:smembers).and_raise(StandardError.new('Redis down'))

        result = described_class.get_pending_interactions(char_instance.id)

        expect(result).to eq([])
      end
    end

    describe '.complete_interaction' do
      it 'removes from pending and deletes data' do
        allow(redis_double).to receive(:srem)
        allow(redis_double).to receive(:del)

        described_class.complete_interaction(char_instance.id, 'int-123')

        expect(redis_double).to have_received(:srem).with(
          "agent_pending:#{char_instance.id}",
          'int-123'
        )
        expect(redis_double).to have_received(:del).with(
          "agent_interaction:#{char_instance.id}:int-123"
        )
      end

      it 'handles errors gracefully' do
        allow(redis_double).to receive(:srem).and_raise(StandardError.new('Redis down'))

        expect {
          described_class.complete_interaction(char_instance.id, 'int-123')
        }.not_to raise_error
      end
    end
  end

  describe 'Redis unavailable' do
    before do
      hide_const('REDIS_POOL')
    end

    it 'store_agent_interaction returns early when REDIS_POOL not defined' do
      expect {
        described_class.store_agent_interaction(char_instance, 'int-123', {})
      }.not_to raise_error
    end

    it 'get_agent_interaction returns nil when REDIS_POOL not defined' do
      result = described_class.get_agent_interaction(char_instance.id, 'int-123')
      expect(result).to be_nil
    end

    it 'get_pending_interactions returns empty array when REDIS_POOL not defined' do
      result = described_class.get_pending_interactions(char_instance.id)
      expect(result).to eq([])
    end

    it 'complete_interaction returns early when REDIS_POOL not defined' do
      expect {
        described_class.complete_interaction(char_instance.id, 'int-123')
      }.not_to raise_error
    end
  end

  describe 'edge cases for format_output' do
    describe 'room formatting with missing data' do
      it 'handles nil room data' do
        result = helper.send(:format_output, :room, { room: nil, exits: [] }, html: true)
        expect(result).to include('<h3>')
      end

      it 'handles nil description' do
        data = { room: { name: 'Test Room', description: nil }, exits: [] }
        result = helper.send(:format_output, :room, data, html: true)
        expect(result).to include('Test Room')
      end

      it 'handles empty characters array' do
        data = { room: { name: 'Empty Room', description: 'Empty' }, characters: [], exits: [] }
        result = helper.send(:format_output, :room, data, html: true)
        expect(result).not_to include('Also here:')
      end

      it 'handles empty exits array' do
        data = { room: { name: 'Closed Room', description: 'No exits' }, exits: [] }
        result = helper.send(:format_output, :room, data, html: true)
        expect(result).not_to include('Exits:')
      end

      it 'handles nil exits' do
        data = { room: { name: 'Closed Room', description: 'No exits' }, exits: nil }
        result = helper.send(:format_output, :room, data, html: true)
        expect(result).not_to include('Exits:')
      end

      it 'handles exit with nil distance' do
        data = {
          room: { name: 'Test', description: 'Test' },
          exits: [{ direction: 'north', to_room_name: 'North Room', distance: nil, direction_arrow: '' }]
        }
        result = helper.send(:format_output, :room, data, html: true)
        expect(result).to include('North Room')
      end

      it 'handles exit with empty direction_arrow' do
        data = {
          room: { name: 'Test', description: 'Test' },
          exits: [{ direction: 'north', to_room_name: 'North Room', distance: 5, direction_arrow: '' }]
        }
        result = helper.send(:format_output, :room, data, html: true)
        expect(result).to include('North Room')
      end

      it 'formats room in text mode with nil thumbnails' do
        data = { room: { name: 'Test', description: 'Test' }, exits: [], thumbnails: nil }
        result = helper.send(:format_output, :room, data, html: false)
        expect(result).not_to include('Images:')
      end
    end

    describe 'message formatting with edge cases' do
      it 'handles nil content' do
        data = { type: 'say', sender: 'Alice', content: nil }
        result = helper.send(:format_output, :message, data, html: false)
        expect(result).to eq('Alice says, ""')
      end

      it 'handles empty sender' do
        data = { type: 'say', sender: '', content: 'Hello' }
        result = helper.send(:format_output, :message, data, html: false)
        expect(result).to eq(' says, "Hello"')
      end

      it 'handles nil type (defaults to else branch)' do
        data = { type: nil, content: 'Some text' }
        result = helper.send(:format_output, :message, data, html: false)
        expect(result).to eq('Some text')
      end
    end

    describe 'quickmenu formatting with edge cases' do
      it 'handles empty options array' do
        data = { prompt: 'No choices', options: [] }
        result = helper.send(:format_output, :quickmenu, data, html: false)
        expect(result).to include('No choices')
        expect(result).to include('respond_to_interaction')
      end

      it 'handles nil options' do
        data = { prompt: 'No choices', options: nil }
        result = helper.send(:format_output, :quickmenu, data, html: false)
        expect(result).to include('No choices')
      end

      it 'handles option without description' do
        data = {
          prompt: 'Pick one',
          options: [{ key: '1', label: 'Option A', description: nil }]
        }
        result = helper.send(:format_output, :quickmenu, data, html: false)
        expect(result).to include('[1] Option A')
        expect(result).not_to include(' - ')
      end

      it 'handles HTML mode with nil description' do
        data = {
          prompt: 'Pick one',
          options: [{ key: '1', label: 'Option A', description: nil }]
        }
        result = helper.send(:format_output, :quickmenu, data, html: true)
        expect(result).to include('Option A')
        expect(result).not_to include("<span class='desc'>")
      end
    end

    describe 'form formatting with edge cases' do
      it 'handles empty fields array' do
        data = { title: 'Empty Form', fields: [] }
        result = helper.send(:format_output, :form, data, html: false)
        expect(result).to include('Empty Form')
        expect(result).to include('Fields:')
        expect(result).to include('respond_to_interaction')
      end

      it 'handles nil fields' do
        data = { title: 'Empty Form', fields: nil }
        result = helper.send(:format_output, :form, data, html: false)
        expect(result).to include('Empty Form')
      end

      it 'handles field without default' do
        data = {
          title: 'Form',
          fields: [{ name: 'test', type: 'text', label: 'Test', required: false }]
        }
        result = helper.send(:format_output, :form, data, html: false)
        expect(result).not_to include('[default:')
      end

      it 'handles field with non-hash options' do
        data = {
          title: 'Form',
          fields: [{
            name: 'test',
            type: 'select',
            label: 'Test',
            options: ['Option A', 'Option B']
          }]
        }
        result = helper.send(:format_output, :form, data, html: false)
        expect(result).to include('[options: Option A, Option B]')
      end
    end

    describe 'form field rendering edge cases' do
      it 'renders select with empty options' do
        field = { name: 'empty_select', type: 'select', options: [] }
        result = helper.send(:render_form_field, field)
        expect(result).to include('<select')
        expect(result).to include('</select>')
      end

      it 'renders select with nil options' do
        field = { name: 'nil_select', type: 'select', options: nil }
        result = helper.send(:render_form_field, field)
        expect(result).to include('<select')
        expect(result).to include('</select>')
      end

      it 'renders textarea with nil default' do
        field = { name: 'bio', type: 'textarea', default: nil, placeholder: nil }
        result = helper.send(:render_form_field, field)
        expect(result).to include('<textarea')
        expect(result).to include('</textarea>')
      end

      it 'renders checkbox with false default' do
        field = { name: 'agree', type: 'checkbox', default: false }
        result = helper.send(:render_form_field, field)
        expect(result).to include("type='checkbox'")
        expect(result).not_to include(' checked')
      end

      it 'renders unknown field type as text' do
        field = { name: 'unknown', type: 'custom_type' }
        result = helper.send(:render_form_field, field)
        expect(result).to include("type='custom_type'")
      end
    end
  end

  describe 'format_room_thumbnails_html edge cases' do
    it 'returns empty string for empty thumbnails' do
      result = helper.send(:format_room_thumbnails_html, [])
      expect(result).to eq('')
    end

    it 'returns empty string for nil thumbnails' do
      result = helper.send(:format_room_thumbnails_html, nil)
      expect(result).to eq('')
    end

    it 'handles thumbnail with nil alt' do
      thumbnails = [{ url: 'https://example.com/img.jpg', alt: nil }]
      result = helper.send(:format_room_thumbnails_html, thumbnails)
      expect(result).to include("alt='Room image'")
    end
  end

  describe 'create_quickmenu edge cases' do
    before do
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    it 'handles empty options array' do
      result = helper.create_quickmenu(char_instance, 'No choices', [])
      expect(result[:success]).to be true
      expect(result[:data][:options]).to eq([])
    end

    it 'handles options without description' do
      options = [{ key: '1', label: 'Option A' }]
      result = helper.create_quickmenu(char_instance, 'Pick', options)
      expect(result[:data][:options][0][:description]).to be_nil
    end
  end

  describe 'create_form edge cases' do
    before do
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    it 'handles empty fields array' do
      result = helper.create_form(char_instance, 'Empty Form', [])
      expect(result[:success]).to be true
      expect(result[:data][:fields]).to eq([])
    end

    it 'handles field with nil values' do
      fields = [{ name: 'test', label: nil, type: nil, required: nil }]
      result = helper.create_form(char_instance, 'Form', fields)

      field = result[:data][:fields].first
      expect(field[:name]).to eq('test')
      expect(field[:label]).to eq('Test')  # Fallback to capitalized name
      expect(field[:type]).to eq('text')    # Default type
      expect(field[:required]).to eq(false) # Default required
    end

    it 'handles field with pattern attribute' do
      fields = [{ name: 'email', pattern: '^[a-z@.]+$' }]
      result = helper.create_form(char_instance, 'Form', fields)

      field = result[:data][:fields].first
      expect(field[:pattern]).to eq('^[a-z@.]+$')
    end
  end

  describe 'render_output edge cases' do
    it 'handles data with both message and structured' do
      result = helper.render_output(type: :message, data: { content: 'Test' })
      expect(result[:type]).to eq(:message)
      expect(result[:timestamp]).to be_a(String)
    end

    it 'handles extras being passed through' do
      result = helper.render_output(
        type: :message,
        data: { content: 'Test' },
        custom_field: 'custom_value'
      )
      expect(result[:custom_field]).to eq('custom_value')
    end
  end

  describe 'escape_html' do
    it 'handles nil input' do
      result = helper.send(:escape_html, nil)
      expect(result).to eq('')
    end

    it 'handles numeric input' do
      result = helper.send(:escape_html, 123)
      expect(result).to eq('123')
    end

    it 'handles special characters' do
      result = helper.send(:escape_html, '<>&"')
      expect(result).to eq('&lt;&gt;&amp;&quot;')
    end
  end
end
