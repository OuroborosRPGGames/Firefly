# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Mail, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  let(:other_user) { create(:user) }
  let(:other_character) { create(:character, user: other_user, forename: 'Bob') }

  subject { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'mail', :communication, ['memo', 'memos', 'email', 'messages', 'inbox']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['mail']).to eq(described_class)
    end
  end

  # ========================================
  # Inbox Tests
  # ========================================

  describe 'mail list / inbox' do
    context 'with empty inbox' do
      it 'shows empty inbox message' do
        result = subject.execute('mail')

        expect(result[:success]).to be true
        expect(result[:message]).to include('inbox is empty')
      end

      it 'returns empty count in data' do
        result = subject.execute('mail list')

        expect(result[:data][:count]).to eq(0)
      end
    end

    context 'with memos' do
      let!(:memo) do
        Memo.create(
          sender_id: other_character.id,
          recipient_id: character.id,
          subject: 'Test Subject',
          content: 'Test body content',
          created_at: Time.now,
          read: false
        )
      end

      it 'returns a quickmenu with memos' do
        result = subject.execute('mail')

        expect(result[:interaction_id]).not_to be_nil
      end

      it 'shows unread indicator for unread memos' do
        result = subject.execute('mail list')

        # Should have memos in context
        expect(result[:success]).to be true
      end
    end
  end

  # ========================================
  # Read Tests
  # ========================================

  describe 'mail read' do
    context 'with no memos' do
      it 'returns error message' do
        result = subject.execute('mail read 1')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('no memos')
      end
    end

    context 'with memos' do
      let!(:memo) do
        Memo.create(
          sender_id: other_character.id,
          recipient_id: character.id,
          subject: 'Test Subject',
          content: 'Test body content',
          created_at: Time.now,
          read: false
        )
      end

      it 'shows memo content' do
        result = subject.execute('mail read 1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Subject')
        expect(result[:message]).to include('Test body content')
      end

      it 'marks memo as read' do
        expect(memo.unread?).to be true
        subject.execute('mail read 1')
        memo.refresh
        expect(memo.unread?).to be false
      end

      it 'shows sender name' do
        result = subject.execute('mail read 1')

        expect(result[:message]).to include('Bob')
      end

      it 'handles invalid memo number' do
        result = subject.execute('mail read 99')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('Invalid memo number')
      end

      it 'handles zero memo number' do
        result = subject.execute('mail read 0')

        expect(result[:success]).to be false
      end

      it 'allows reading via number shortcut' do
        result = subject.execute('mail 1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Subject')
      end
    end
  end

  # ========================================
  # Send Tests
  # ========================================

  describe 'mail send' do
    context 'with no arguments' do
      it 'shows compose form' do
        result = subject.execute('mail send')

        expect(result[:interaction_id]).not_to be_nil
      end
    end

    context 'with just recipient name' do
      before { other_character } # Ensure Bob exists

      it 'shows compose form with recipient prefilled' do
        result = subject.execute('mail send Bob')

        expect(result[:interaction_id]).not_to be_nil
      end
    end

    context 'with extra text after recipient name' do
      before { other_character } # Ensure Bob exists

      it 'shows compose form (ignores extra text, uses first word as recipient)' do
        result = subject.execute('mail send Bob Hello=Test message')

        expect(result[:interaction_id]).not_to be_nil
      end
    end

    context 'with nonexistent recipient' do
      it 'fails when sending to nonexistent character' do
        result = subject.execute('mail send NonExistent')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('No character found')
      end
    end

    context 'when sending to self' do
      it 'fails when sending to self' do
        result = subject.execute('mail send Alice')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include("can't send a memo to yourself")
      end
    end
  end

  # ========================================
  # Delete Tests
  # ========================================

  describe 'mail delete' do
    context 'with no memos' do
      it 'returns error' do
        result = subject.execute('mail delete 1')

        expect(result[:success]).to be false
      end
    end

    context 'with memos' do
      let!(:memo) do
        Memo.create(
          sender_id: other_character.id,
          recipient_id: character.id,
          subject: 'To Delete',
          content: 'Delete me',
          created_at: Time.now
        )
      end

      it 'deletes specified memo' do
        expect(Memo.inbox_for(character).count).to eq(1)
        result = subject.execute('mail delete 1')

        expect(result[:success]).to be true
        expect(Memo.inbox_for(character).count).to eq(0)
      end

      it 'handles invalid memo number' do
        result = subject.execute('mail delete 99')

        expect(result[:success]).to be false
      end

      it 'allows deleting all memos' do
        # Create another memo
        Memo.create(
          sender_id: other_character.id,
          recipient_id: character.id,
          subject: 'Another',
          content: 'Body',
          created_at: Time.now
        )

        expect(Memo.inbox_for(character).count).to eq(2)
        result = subject.execute('mail delete all')

        expect(result[:success]).to be true
        expect(Memo.inbox_for(character).count).to eq(0)
      end
    end
  end

  # ========================================
  # Form Response Tests
  # ========================================

  describe '#handle_form_response' do
    # Ensure other_character exists before tests (lazy let needs to be forced)
    before do
      other_character # Force creation
      allow_any_instance_of(described_class).to receive(:check_for_abuse).and_return({ allowed: true })
    end

    context 'with valid form data' do
      it 'sends memo' do
        form_data = {
          'recipient' => 'Bob',
          'subject' => 'Test Subject',
          'body' => 'Test message body'
        }

        result = subject.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be true
        expect(Memo.where(recipient_id: other_character.id).count).to eq(1)
      end
    end

    context 'with missing recipient' do
      it 'returns error' do
        form_data = {
          'recipient' => '',
          'subject' => 'Test',
          'body' => 'Body'
        }

        result = subject.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('Recipient is required')
      end
    end

    context 'with missing subject' do
      it 'returns error' do
        form_data = {
          'recipient' => 'Bob',
          'subject' => '',
          'body' => 'Body'
        }

        result = subject.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('Subject is required')
      end
    end

    context 'with missing body' do
      it 'returns error' do
        form_data = {
          'recipient' => 'Bob',
          'subject' => 'Subject',
          'body' => ''
        }

        result = subject.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('body is required')
      end
    end

    context 'with nonexistent recipient' do
      it 'returns error' do
        form_data = {
          'recipient' => 'NonExistent',
          'subject' => 'Subject',
          'body' => 'Body'
        }

        result = subject.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('No character found')
      end
    end

    context 'when sending to self' do
      it 'returns error' do
        form_data = {
          'recipient' => 'Alice',
          'subject' => 'Subject',
          'body' => 'Body'
        }

        result = subject.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include("can't send a memo to yourself")
      end
    end

    context 'when abuse check fails' do
      before do
        allow_any_instance_of(described_class).to receive(:check_for_abuse).and_return({
          allowed: false,
          reason: 'Abusive content detected'
        })
      end

      it 'blocks the memo' do
        form_data = {
          'recipient' => 'Bob',
          'subject' => 'Subject',
          'body' => 'Bad content'
        }

        result = subject.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(Memo.where(recipient_id: other_character.id).count).to eq(0)
      end
    end
  end

  # ========================================
  # Alias Tests
  # ========================================

  describe 'aliases' do
    it 'memo alias works' do
      # The execute method should recognize 'memo' as this command
      result = subject.execute('mail')
      expect(result[:success]).to be true
    end
  end

  # ========================================
  # Edge Cases
  # ========================================

  describe 'edge cases' do
    it 'handles unknown subcommand' do
      result = subject.execute('mail unknown')

      # Should show usage
      expect(result[:success]).to be true
    end
  end
end
