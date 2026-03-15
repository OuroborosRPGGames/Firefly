# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ticket do
  let(:user) { create(:user) }
  let(:room) { create(:room) }
  let(:staff) { create(:user) }

  describe 'validations' do
    it 'requires a valid category' do
      ticket = Ticket.new(user: user, subject: 'Test', content: 'Content', status: 'open', category: 'invalid')
      expect(ticket.valid?).to be false
      expect(ticket.errors[:category]).not_to be_empty
    end

    it 'requires a valid status' do
      ticket = Ticket.new(user: user, subject: 'Test', content: 'Content', category: 'bug', status: 'invalid')
      expect(ticket.valid?).to be false
      expect(ticket.errors[:status]).not_to be_empty
    end

    it 'requires subject' do
      ticket = Ticket.new(user: user, content: 'Content', category: 'bug', status: 'open')
      expect(ticket.valid?).to be false
      expect(ticket.errors[:subject]).not_to be_empty
    end

    it 'requires content' do
      ticket = Ticket.new(user: user, subject: 'Test', category: 'bug', status: 'open')
      expect(ticket.valid?).to be false
      expect(ticket.errors[:content]).not_to be_empty
    end

    it 'validates subject length' do
      ticket = Ticket.new(user: user, subject: 'a' * 201, content: 'Content', category: 'bug', status: 'open')
      expect(ticket.valid?).to be false
      expect(ticket.errors[:subject]).not_to be_empty
    end

    it 'accepts all valid categories' do
      Ticket::CATEGORIES.each do |cat|
        ticket = Ticket.new(user: user, subject: 'Test', content: 'Content', category: cat, status: 'open')
        expect(ticket.valid?).to be(true), "Expected #{cat} to be valid"
      end
    end

    it 'accepts all valid statuses' do
      Ticket::STATUSES.each do |stat|
        ticket = Ticket.new(user: user, subject: 'Test', content: 'Content', category: 'bug', status: stat)
        expect(ticket.valid?).to be(true), "Expected #{stat} to be valid"
      end
    end
  end

  describe 'factory' do
    it 'creates a valid ticket' do
      ticket = create(:ticket, user: user, room: room)
      expect(ticket).to be_valid
      expect(ticket.status).to eq('open')
    end

    it 'creates resolved ticket with trait' do
      ticket = create(:ticket, :resolved, user: user, room: room)
      expect(ticket.status).to eq('resolved')
      expect(ticket.resolved_by_user).not_to be_nil
    end
  end

  describe 'status transitions' do
    let(:ticket) { create(:ticket, user: user, room: room) }

    describe '#resolve!' do
      it 'changes status to resolved' do
        ticket.resolve!(by_user: staff, notes: 'Fixed')
        expect(ticket.status).to eq('resolved')
      end

      it 'records who resolved it' do
        ticket.resolve!(by_user: staff, notes: 'Fixed')
        expect(ticket.resolved_by_user_id).to eq(staff.id)
      end

      it 'records resolution notes' do
        ticket.resolve!(by_user: staff, notes: 'Issue fixed in commit abc123')
        expect(ticket.resolution_notes).to eq('Issue fixed in commit abc123')
      end

      it 'sets resolved_at timestamp' do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        ticket.resolve!(by_user: staff, notes: 'Fixed')
        expect(ticket.resolved_at).to eq(freeze_time)
      end

      it 'returns self for chaining' do
        result = ticket.resolve!(by_user: staff, notes: 'Fixed')
        expect(result).to eq(ticket)
      end
    end

    describe '#close!' do
      it 'changes status to closed' do
        ticket.close!(by_user: staff, notes: 'Duplicate')
        expect(ticket.status).to eq('closed')
      end

      it 'works without notes' do
        ticket.close!(by_user: staff)
        expect(ticket.status).to eq('closed')
      end

      it 'records who closed it' do
        ticket.close!(by_user: staff)
        expect(ticket.resolved_by_user_id).to eq(staff.id)
      end
    end

    describe '#reopen!' do
      before do
        ticket.resolve!(by_user: staff, notes: 'Fixed')
      end

      it 'changes status to open' do
        ticket.reopen!
        expect(ticket.status).to eq('open')
      end

      it 'clears resolution data' do
        ticket.reopen!
        expect(ticket.resolved_by_user_id).to be_nil
        expect(ticket.resolution_notes).to be_nil
        expect(ticket.resolved_at).to be_nil
      end
    end
  end

  describe '#investigate!' do
    let(:ticket) { create(:ticket, user: user, room: room) }

    it 'has investigated_at column in schema' do
      expect(Ticket.columns).to include(:investigated_at)
    end

    it 'sets investigation notes' do
      ticket.investigate!(notes: 'AI analysis complete')
      expect(ticket.investigation_notes).to eq('AI analysis complete')
    end

    it 'sets investigated_at timestamp' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      ticket.investigate!(notes: 'Analysis')
      expect(ticket.investigated_at).to eq(freeze_time)
    end
  end

  describe '#investigated?' do
    let(:ticket) { create(:ticket, user: user, room: room) }

    it 'returns false when no investigation' do
      expect(ticket.investigated?).to be false
    end

    it 'returns true when investigation notes exist' do
      ticket.investigate!(notes: 'Found the bug')
      expect(ticket.investigated?).to be true
    end

    it 'returns false when notes are empty' do
      ticket.update(investigation_notes: '')
      expect(ticket.investigated?).to be false
    end
  end

  describe 'status predicates' do
    it '#open? returns true when status is open' do
      ticket = create(:ticket, user: user, room: room, status: 'open')
      expect(ticket.open?).to be true
      expect(ticket.resolved?).to be false
      expect(ticket.closed?).to be false
    end

    it '#resolved? returns true when status is resolved' do
      ticket = create(:ticket, :resolved, user: user, room: room)
      expect(ticket.resolved?).to be true
      expect(ticket.open?).to be false
    end

    it '#closed? returns true when status is closed' do
      ticket = create(:ticket, :closed, user: user, room: room)
      expect(ticket.closed?).to be true
      expect(ticket.open?).to be false
    end
  end

  describe 'display methods' do
    let(:ticket) { create(:ticket, user: user, room: room, category: 'bug', status: 'open') }

    it '#category_display capitalizes category' do
      expect(ticket.category_display).to eq('Bug')
    end

    it '#status_display capitalizes status' do
      expect(ticket.status_display).to eq('Open')
    end
  end

  describe 'dataset methods' do
    let!(:open_bug) { create(:ticket, user: user, room: room, category: 'bug', status: 'open') }
    let!(:open_typo) { create(:ticket, user: user, room: room, category: 'typo', status: 'open') }
    let!(:resolved_bug) { create(:ticket, :resolved, user: user, room: room, category: 'bug') }
    let!(:closed_bug) { create(:ticket, :closed, user: user, room: room, category: 'bug') }

    describe '.open (scope)' do
      it 'returns only open tickets' do
        # Use dataset method directly to avoid Kernel#open conflict
        result = Ticket.dataset.status_open.all
        expect(result).to include(open_bug, open_typo)
        expect(result).not_to include(resolved_bug, closed_bug)
      end
    end

    describe '.resolved (scope)' do
      it 'returns only resolved tickets' do
        result = Ticket.dataset.resolved.all
        expect(result).to include(resolved_bug)
        expect(result).not_to include(open_bug, closed_bug)
      end
    end

    describe '.closed (scope)' do
      it 'returns only closed tickets' do
        result = Ticket.dataset.closed.all
        expect(result).to include(closed_bug)
        expect(result).not_to include(open_bug, resolved_bug)
      end
    end

    describe '.by_category' do
      it 'filters by category' do
        result = Ticket.by_category('bug').all
        expect(result).to include(open_bug, resolved_bug, closed_bug)
        expect(result).not_to include(open_typo)
      end
    end

    describe '.recent' do
      it 'returns tickets ordered by created_at desc' do
        result = Ticket.recent.all
        expect(result.first.created_at).to be >= result.last.created_at
      end

      it 'respects limit' do
        result = Ticket.recent(2).all
        expect(result.count).to eq(2)
      end
    end
  end

  describe '#to_admin_hash' do
    let(:ticket) { create(:ticket, user: user, room: room, category: 'bug') }

    it 'has investigated_at column in schema' do
      expect(Ticket.columns).to include(:investigated_at)
    end

    it 'returns a hash with all ticket data' do
      hash = ticket.to_admin_hash
      expect(hash[:id]).to eq(ticket.id)
      expect(hash[:user_id]).to eq(user.id)
      expect(hash[:username]).to eq(user.username)
      expect(hash[:category]).to eq('bug')
      expect(hash[:subject]).to eq(ticket.subject)
      expect(hash[:content]).to eq(ticket.content)
      expect(hash[:status]).to eq('open')
      expect(hash[:room_id]).to eq(room.id)
      expect(hash[:room_name]).to eq(room.name)
    end

    it 'includes resolution data when resolved' do
      ticket.resolve!(by_user: staff, notes: 'Fixed')
      hash = ticket.to_admin_hash
      expect(hash[:resolved_by]).to eq(staff.username)
      expect(hash[:resolution_notes]).to eq('Fixed')
      expect(hash[:resolved_at]).not_to be_nil
    end

    it 'includes system_generated field' do
      sys_ticket = Ticket.create(
        user_id: nil,
        category: 'documentation',
        subject: 'Test',
        content: 'Test content',
        status: 'open',
        system_generated: true
      )
      hash = sys_ticket.to_admin_hash
      expect(hash).to have_key(:system_generated)
      expect(hash[:system_generated]).to be true
    end

    it 'shows System for nil user' do
      sys_ticket = Ticket.create(
        user_id: nil,
        category: 'documentation',
        subject: 'Test',
        content: 'Test content',
        status: 'open',
        system_generated: true
      )
      hash = sys_ticket.to_admin_hash
      expect(hash[:username]).to eq('System')
    end
  end

  describe 'CATEGORIES' do
    it 'includes documentation' do
      expect(Ticket::CATEGORIES).to include('documentation')
    end
  end

  describe 'system-generated tickets' do
    it 'accepts documentation category' do
      ticket = Ticket.new(
        category: 'documentation',
        subject: 'Missing helpfile for damage thresholds',
        content: 'No documentation exists for the damage threshold system.',
        status: 'open',
        system_generated: true
      )
      expect(ticket.valid?).to be true
    end

    it 'allows nil user_id for system-generated tickets' do
      ticket = Ticket.create(
        user_id: nil,
        category: 'documentation',
        subject: 'Missing helpfile',
        content: 'Test content',
        status: 'open',
        system_generated: true
      )
      expect(ticket.id).not_to be_nil
      expect(ticket.user_id).to be_nil
    end
  end
end
