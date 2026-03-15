# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ContactHistoryService do
  describe '.recent_contacts' do
    let(:character) { double('Character', id: 1) }

    context 'when character is nil' do
      it 'returns empty array' do
        expect(described_class.recent_contacts(nil)).to eq([])
      end
    end

    context 'when character has no memo history' do
      before do
        # Set up empty datasets
        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return([])

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)
      end

      it 'returns empty array' do
        expect(described_class.recent_contacts(character)).to eq([])
      end
    end

    context 'with sent memos' do
      let(:partner1) { double('Character', id: 2, full_name: 'Alice') }
      let(:partner2) { double('Character', id: 3, full_name: 'Bob') }
      let(:time1) { Time.now - 3600 }
      let(:time2) { Time.now - 7200 }

      before do
        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return([
          { recipient_id: 2, last_contact: time1 },
          { recipient_id: 3, last_contact: time2 }
        ])

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)

        allow(Character).to receive(:[]).with(2).and_return(partner1)
        allow(Character).to receive(:[]).with(3).and_return(partner2)
      end

      it 'returns contacts sorted by most recent first' do
        result = described_class.recent_contacts(character)

        expect(result.length).to eq(2)
        expect(result[0][:name]).to eq('Alice')
        expect(result[1][:name]).to eq('Bob')
      end

      it 'includes all required fields' do
        result = described_class.recent_contacts(character)

        expect(result[0]).to include(:id, :name, :last_contact)
        expect(result[0][:id]).to eq(2)
        expect(result[0][:last_contact]).to eq(time1)
      end
    end

    context 'with received memos' do
      let(:partner) { double('Character', id: 2, full_name: 'Alice') }
      let(:time1) { Time.now - 3600 }

      before do
        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return([])

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([
          { sender_id: 2, last_contact: time1 }
        ])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)

        allow(Character).to receive(:[]).with(2).and_return(partner)
      end

      it 'returns received contacts' do
        result = described_class.recent_contacts(character)

        expect(result.length).to eq(1)
        expect(result[0][:name]).to eq('Alice')
      end
    end

    context 'with both sent and received memos to same person' do
      let(:partner) { double('Character', id: 2, full_name: 'Alice') }
      let(:earlier_time) { Time.now - 7200 }
      let(:later_time) { Time.now - 3600 }

      before do
        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return([
          { recipient_id: 2, last_contact: earlier_time }
        ])

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([
          { sender_id: 2, last_contact: later_time }
        ])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)

        allow(Character).to receive(:[]).with(2).and_return(partner)
      end

      it 'uses most recent contact time' do
        result = described_class.recent_contacts(character)

        expect(result.length).to eq(1)
        expect(result[0][:last_contact]).to eq(later_time)
      end
    end

    context 'with self-memos (sender_id = recipient_id)' do
      let(:partner) { double('Character', id: 2, full_name: 'Alice') }

      before do
        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return([])

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([
          { sender_id: 1, last_contact: Time.now } # Self-memo
        ])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)
      end

      it 'excludes self from contacts' do
        result = described_class.recent_contacts(character)

        expect(result).to eq([])
      end
    end

    context 'with nil partner_id' do
      before do
        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return([
          { recipient_id: nil, last_contact: Time.now }
        ])

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)
      end

      it 'skips nil partner IDs' do
        result = described_class.recent_contacts(character)

        expect(result).to eq([])
      end
    end

    context 'when character no longer exists' do
      before do
        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return([
          { recipient_id: 2, last_contact: Time.now }
        ])

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)

        allow(Character).to receive(:[]).with(2).and_return(nil)
      end

      it 'skips deleted characters' do
        result = described_class.recent_contacts(character)

        expect(result).to eq([])
      end
    end

    context 'with limit parameter' do
      let(:partners) do
        (2..15).map { |i| double("Character#{i}", id: i, full_name: "Person #{i}") }
      end

      before do
        sent_records = (2..15).map do |i|
          { recipient_id: i, last_contact: Time.now - (i * 100) }
        end

        sent_dataset = double('Dataset')
        allow(sent_dataset).to receive(:select).and_return(sent_dataset)
        allow(sent_dataset).to receive(:group).and_return(sent_dataset)
        allow(sent_dataset).to receive(:all).and_return(sent_records)

        received_dataset = double('Dataset')
        allow(received_dataset).to receive(:select).and_return(received_dataset)
        allow(received_dataset).to receive(:group).and_return(received_dataset)
        allow(received_dataset).to receive(:all).and_return([])

        allow(Memo).to receive(:where).with(sender_id: 1).and_return(sent_dataset)
        allow(Memo).to receive(:where).with(recipient_id: 1).and_return(received_dataset)

        partners.each do |p|
          allow(Character).to receive(:[]).with(p.id).and_return(p)
        end
      end

      it 'defaults to 10 contacts' do
        result = described_class.recent_contacts(character)

        expect(result.length).to eq(10)
      end

      it 'respects custom limit' do
        result = described_class.recent_contacts(character, limit: 5)

        expect(result.length).to eq(5)
      end
    end

    context 'when database error occurs' do
      before do
        allow(Memo).to receive(:where).and_raise(StandardError.new('DB error'))
      end

      it 'returns empty array' do
        expect(described_class.recent_contacts(character)).to eq([])
      end

      it 'logs the error' do
        expect { described_class.recent_contacts(character) }
          .to output(/ContactHistoryService.*Failed to get recent contacts.*DB error/).to_stderr
      end
    end
  end
end
