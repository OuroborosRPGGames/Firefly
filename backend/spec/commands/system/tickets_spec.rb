# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Tickets do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['tickets']).to eq(described_class)
    end

    it 'has alias mytickets' do
      cmd_class, _ = Commands::Base::Registry.find_command('mytickets')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias bug' do
      cmd_class, _ = Commands::Base::Registry.find_command('bug')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias typo' do
      cmd_class, _ = Commands::Base::Registry.find_command('typo')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias report' do
      cmd_class, _ = Commands::Base::Registry.find_command('report')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias request' do
      cmd_class, _ = Commands::Base::Registry.find_command('request')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias suggest' do
      cmd_class, _ = Commands::Base::Registry.find_command('suggest')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('tickets')
    end

    it 'has category system' do
      expect(described_class.category).to eq(:system)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('ticket')
    end

    it 'has usage' do
      expect(described_class.usage).to include('tickets')
    end

    it 'has examples' do
      expect(described_class.examples).to include('tickets')
    end
  end

  describe '#execute' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:room) { create(:room) }
    let!(:char_instance) { create(:character_instance, character: character, current_room: room) }
    let(:command) { described_class.new(char_instance) }

    before do
      allow(StaffAlertService).to receive(:broadcast_to_staff)
    end

    describe 'with no arguments' do
      it 'shows tickets menu quickmenu' do
        result = command.execute('')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:data][:prompt]).to eq('Ticket System')
      end

      it 'includes menu options for list, all, and new' do
        result = command.execute('')
        option_keys = result[:data][:options].map { |o| o[:key] }
        expect(option_keys).to include('list', 'all', 'new')
      end
    end

    describe 'with list/open action' do
      context 'with no open tickets' do
        it 'returns message about no open tickets' do
          result = command.execute('tickets list')
          expect(result[:success]).to be true
          expect(result[:message]).to include('no open tickets')
        end
      end

      context 'with open tickets' do
        before do
          create(:ticket, user: user, status: 'open', subject: 'Test bug 1')
          create(:ticket, user: user, status: 'open', subject: 'Test bug 2')
        end

        it 'shows quickmenu with ticket list' do
          result = command.execute('tickets list')
          expect(result[:success]).to be true
          expect(result[:type]).to eq(:quickmenu)
          expect(result[:data][:prompt]).to eq('Open Tickets')
        end

        it 'includes ticket IDs in options' do
          result = command.execute('tickets list')
          option_labels = result[:data][:options].map { |o| o[:label] }
          expect(option_labels.any? { |l| l.include?('[OPEN]') }).to be true
        end
      end
    end

    describe 'with all/history action' do
      context 'with no tickets at all' do
        it 'returns message about no tickets' do
          result = command.execute('tickets all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('no tickets')
        end
      end

      context 'with tickets including resolved' do
        before do
          create(:ticket, user: user, status: 'open', subject: 'Open ticket')
          create(:ticket, user: user, status: 'resolved', subject: 'Resolved ticket')
        end

        it 'shows quickmenu with all tickets' do
          result = command.execute('tickets all')
          expect(result[:success]).to be true
          expect(result[:type]).to eq(:quickmenu)
          expect(result[:data][:prompt]).to eq('All Tickets')
        end

        it 'includes both open and resolved tickets' do
          result = command.execute('tickets all')
          option_labels = result[:data][:options].map { |o| o[:label] }
          expect(option_labels.any? { |l| l.include?('[OPEN]') }).to be true
          expect(option_labels.any? { |l| l.include?('[RESOLVED]') }).to be true
        end
      end
    end

    describe 'with new/submit/create action' do
      it 'shows ticket submission form' do
        result = command.execute('tickets new')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
        expect(result[:data][:title]).to eq('Submit Ticket')
      end

      it 'form includes category, subject, and content fields' do
        result = command.execute('tickets new')
        field_names = result[:data][:fields].map { |f| f[:name] }
        expect(field_names).to include('category', 'subject', 'content')
      end

      it 'accepts category as argument' do
        result = command.execute('tickets new bug')
        expect(result[:type]).to eq(:form)
        category_field = result[:data][:fields].find { |f| f[:name] == 'category' }
        expect(category_field[:default]).to eq('bug')
      end
    end

    describe 'with view/show/read action' do
      context 'without ticket ID' do
        it 'returns error' do
          result = command.execute('tickets view')
          expect(result[:success]).to be false
          expect(result[:message]).to include('specify a ticket ID')
        end
      end

      context 'with invalid ticket ID' do
        it 'returns error' do
          result = command.execute('tickets view 99999')
          expect(result[:success]).to be false
          expect(result[:message]).to include('not found')
        end
      end

      context 'with ticket belonging to another user' do
        let(:other_user) { create(:user) }

        before do
          create(:ticket, user: other_user, subject: 'Other user ticket')
        end

        it 'returns error' do
          ticket = Ticket.last
          result = command.execute("tickets view #{ticket.id}")
          expect(result[:success]).to be false
          expect(result[:message]).to include('not found')
        end
      end

      context 'with valid ticket' do
        let!(:ticket) { create(:ticket, user: user, category: 'bug', subject: 'Test bug', content: 'Bug description') }

        it 'shows ticket details' do
          result = command.execute("tickets view #{ticket.id}")
          expect(result[:success]).to be true
          expect(result[:message]).to include('Test bug')
          expect(result[:message]).to include('Bug description')
        end

        it 'includes category and status' do
          result = command.execute("tickets view #{ticket.id}")
          expect(result[:message]).to include('Category:')
          expect(result[:message]).to include('Status:')
        end
      end

      context 'with resolved ticket' do
        let!(:staff_user) { create(:user, username: 'staffmember') }
        let!(:ticket) do
          create(:ticket,
            user: user,
            category: 'bug',
            subject: 'Resolved bug',
            content: 'Bug description',
            status: 'resolved',
            resolved_by_user_id: staff_user.id,
            resolved_at: Time.now,
            resolution_notes: 'Fixed in latest update')
        end

        it 'shows resolution information' do
          result = command.execute("tickets view #{ticket.id}")
          expect(result[:message]).to include('Staff Response')
          expect(result[:message].downcase).to include('staffmember')
          expect(result[:message]).to include('Fixed in latest update')
        end
      end
    end

    describe 'with direct ticket ID' do
      let!(:ticket) { create(:ticket, user: user, subject: 'Quick view ticket') }

      it 'treats numeric argument as ticket ID' do
        result = command.execute("tickets #{ticket.id}")
        expect(result[:success]).to be true
        expect(result[:message]).to include('Quick view ticket')
      end
    end

    describe 'with unknown action' do
      it 'returns error with usage hint' do
        result = command.execute('tickets invalid')
        expect(result[:success]).to be false
        # Message may have HTML entities
        expect(result[:message]).to include('Unknown action')
        expect(result[:message]).to include('invalid')
      end
    end

    describe 'direct category actions' do
      %w[bug typo request suggestion behaviour].each do |category|
        it "#{category} action shows form with category preselected" do
          result = command.execute("tickets #{category}")
          expect(result[:type]).to eq(:form)
          category_field = result[:data][:fields].find { |f| f[:name] == 'category' }
          expect(category_field[:default]).to eq(category)
        end
      end
    end
  end

  describe '#handle_form_response' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:room) { create(:room) }
    let!(:char_instance) { create(:character_instance, character: character, current_room: room) }
    let(:command) { described_class.new(char_instance) }

    before do
      allow(StaffAlertService).to receive(:broadcast_to_staff)
    end

    context 'with valid form data' do
      let(:form_data) do
        {
          'category' => 'bug',
          'subject' => 'Test bug report',
          'content' => 'This is a detailed bug description.'
        }
      end

      it 'creates a ticket' do
        expect {
          command.send(:handle_form_response, form_data, { command: 'tickets' })
        }.to change(Ticket, :count).by(1)
      end

      it 'returns success message with ticket ID' do
        result = command.send(:handle_form_response, form_data, { command: 'tickets' })
        expect(result[:success]).to be true
        expect(result[:message]).to include('Ticket #')
        expect(result[:message]).to include('submitted')
      end

      it 'broadcasts to staff' do
        expect(StaffAlertService).to receive(:broadcast_to_staff).with(/TICKET.*BUG.*Test bug report/i)
        command.send(:handle_form_response, form_data, { command: 'tickets' })
      end

      it 'sets correct ticket attributes' do
        command.send(:handle_form_response, form_data, { command: 'tickets' })
        ticket = Ticket.last
        expect(ticket.user_id).to eq(user.id)
        expect(ticket.category).to eq('bug')
        expect(ticket.subject).to eq('Test bug report')
        expect(ticket.content).to eq('This is a detailed bug description.')
        expect(ticket.room_id).to eq(room.id)
      end
    end

    context 'with invalid category' do
      let(:form_data) do
        {
          'category' => 'invalid_category',
          'subject' => 'Test',
          'content' => 'Test content'
        }
      end

      it 'returns error' do
        result = command.send(:handle_form_response, form_data, { command: 'tickets' })
        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid category')
      end
    end

    context 'with missing subject' do
      let(:form_data) do
        {
          'category' => 'bug',
          'subject' => '',
          'content' => 'Test content'
        }
      end

      it 'returns error' do
        result = command.send(:handle_form_response, form_data, { command: 'tickets' })
        expect(result[:success]).to be false
        expect(result[:message]).to include('Subject is required')
      end
    end

    context 'with missing content' do
      let(:form_data) do
        {
          'category' => 'bug',
          'subject' => 'Test subject',
          'content' => ''
        }
      end

      it 'returns error' do
        result = command.send(:handle_form_response, form_data, { command: 'tickets' })
        expect(result[:success]).to be false
        expect(result[:message]).to include('Description is required')
      end
    end

    context 'with subject too long' do
      let(:form_data) do
        {
          'category' => 'bug',
          'subject' => 'x' * 300,
          'content' => 'Test content'
        }
      end

      it 'returns error' do
        result = command.send(:handle_form_response, form_data, { command: 'tickets' })
        expect(result[:success]).to be false
        expect(result[:message]).to include('Subject too long')
      end
    end

    context 'with content too long' do
      let(:form_data) do
        {
          'category' => 'bug',
          'subject' => 'Test subject',
          'content' => 'x' * 20_001
        }
      end

      it 'returns error' do
        result = command.send(:handle_form_response, form_data, { command: 'tickets' })
        expect(result[:success]).to be false
        expect(result[:message]).to include('Description too long')
      end
    end
  end
end
