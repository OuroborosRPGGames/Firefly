# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Info::Observe, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      stance: 'standing'
    )
  end

  let(:user2) { create(:user) }
  let(:bob_character) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }
  let!(:bob_instance) do
    create(:character_instance,
      character: bob_character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      stance: 'standing'
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'observe another character' do
      it 'starts observing and shows character info' do
        result = command.execute('observe Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('begin observing Bob Smith')
        expect(character_instance.reload.observing_id).to eq(bob_instance.id)
      end

      it 'sets observing_id' do
        command.execute('observe Bob')
        expect(character_instance.reload.observing?).to be true
        expect(character_instance.observing_id).to eq(bob_instance.id)
      end

      it 'returns character data in structured field' do
        result = command.execute('observe Bob')
        expect(result[:success]).to be true
        expect(result[:data][:target_id]).to eq(bob_instance.id)
        expect(result[:data][:target_name]).to eq('Bob Smith')
      end

      it 'targets the left observe panel' do
        result = command.execute('observe Bob')
        expect(result[:target_panel]).to eq(:left_observe_window)
      end

      it 'returns structured character display data' do
        result = command.execute('observe Bob')
        expect(result[:structured]).to be_a(Hash)
        expect(result[:structured][:display_type]).to eq(:character)
        expect(result[:structured][:name]).to be_a(String)
      end
    end

    context 'observe self' do
      it 'allows observing self' do
        result = command.execute('observe self')
        expect(result[:success]).to be true
        expect(result[:message]).to include('begin observing yourself')
        expect(character_instance.reload.observing_id).to eq(character_instance.id)
      end

      it 'handles "observe me"' do
        result = command.execute('observe me')
        expect(result[:success]).to be true
        expect(result[:data][:is_self]).to be true
      end

      it 'targets the left observe panel' do
        result = command.execute('observe me')
        expect(result[:target_panel]).to eq(:left_observe_window)
      end
    end

    context 'stop observing' do
      before do
        character_instance.start_observing!(bob_instance)
      end

      it 'stops observing with "observe"' do
        result = command.execute('observe')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stop observing')
        expect(character_instance.reload.observing_id).to be_nil
      end

      it 'stops observing with "observe stop"' do
        result = command.execute('observe stop')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stop observing Bob Smith')
      end

      it 'errors when not observing anyone' do
        character_instance.stop_observing!
        result = command.execute('observe stop')
        expect(result[:success]).to be false
        expect(result[:message]).to include("not currently observing")
      end

      it 'includes stop_observing action in data' do
        result = command.execute('observe stop')
        expect(result[:data][:action]).to eq('stop_observing')
      end

      it 'targets the left observe panel' do
        result = command.execute('observe stop')
        expect(result[:target_panel]).to eq(:left_observe_window)
      end
    end

    context 'switching targets' do
      let(:user3) { create(:user) }
      let(:charlie_character) { create(:character, forename: 'Charlie', surname: 'Brown', user: user3) }
      let!(:charlie_instance) do
        create(:character_instance,
          character: charlie_character,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive',
          stance: 'standing'
        )
      end

      it 'switches to new target' do
        character_instance.start_observing!(bob_instance)
        result = command.execute('observe Charlie')
        expect(result[:success]).to be true
        expect(character_instance.reload.observing_id).to eq(charlie_instance.id)
      end
    end

    context 'target not found' do
      it 'returns error' do
        result = command.execute('observe Nobody')
        expect(result[:success]).to be false
        expect(result[:message]).to include("Nobody")
        expect(result[:message]).to include("observe")
      end
    end

    context 'target in different room' do
      it 'cannot observe character in different room' do
        other_room = Room.create(name: 'Other Room', short_description: 'Another room', location: location, room_type: 'standard')
        bob_instance.update(current_room: other_room)

        result = command.execute('observe Bob')
        expect(result[:success]).to be false
        expect(result[:message]).to include("Bob")
      end
    end

    context 'observers association' do
      it 'target can find their observers' do
        character_instance.start_observing!(bob_instance)
        expect(bob_instance.current_observers.all).to include(character_instance)
      end
    end

    context 'observe a place' do
      let!(:bar) do
        Place.create(
          name: 'The Bar',
          description: 'A long wooden bar',
          room: room,
          is_furniture: true,
          capacity: 5
        )
      end

      it 'starts observing the place' do
        result = command.execute('observe bar')
        expect(result[:success]).to be true
        expect(result[:message]).to include('begin observing The Bar')
        expect(character_instance.reload.observing_place_id).to eq(bar.id)
        expect(character_instance.observing_place?).to be true
      end

      it 'returns place data in structured field' do
        result = command.execute('observe bar')
        expect(result[:success]).to be true
        expect(result[:data][:target_type]).to eq('place')
        expect(result[:data][:target_name]).to eq('The Bar')
      end

      it 'returns structured place display data' do
        result = command.execute('observe bar')
        expect(result[:structured]).to be_a(Hash)
        expect(result[:structured][:display_type]).to eq(:place)
        expect(result[:structured][:name]).to eq('The Bar')
      end

      it 'targets the left observe panel' do
        result = command.execute('observe bar')
        expect(result[:target_panel]).to eq(:left_observe_window)
      end

      it 'shows characters at the place in structured data' do
        bob_instance.update(current_place_id: bar.id, stance: 'sitting')
        result = command.execute('observe bar')
        expect(result[:structured][:characters]).to be_an(Array)
        expect(result[:structured][:characters].first[:stance]).to eq('sitting')
      end

      it 'stops character observation when observing place' do
        character_instance.start_observing!(bob_instance)
        command.execute('observe bar')
        character_instance.reload
        expect(character_instance.observing_id).to be_nil
        expect(character_instance.observing_place_id).to eq(bar.id)
      end
    end

    context 'observe room' do
      it 'starts observing room with "observe room"' do
        result = command.execute('observe room')
        expect(result[:success]).to be true
        expect(character_instance.reload.observing_room).to be true
        expect(character_instance.observing_room?).to be true
      end

      it 'starts observing room with "observe here"' do
        result = command.execute('observe here')
        expect(result[:success]).to be true
        expect(character_instance.reload.observing_room?).to be true
      end

      it 'defaults to observing room with bare "observe" when not already observing' do
        result = command.execute('observe')
        expect(result[:success]).to be true
        expect(character_instance.reload.observing_room?).to be true
      end

      it 'returns room type for rich rendering' do
        result = command.execute('observe room')
        expect(result[:type]).to eq(:room)
      end

      it 'returns room data for client rendering' do
        result = command.execute('observe room')
        expect(result[:data]).to be_a(Hash)
        room_info = result[:data][:room] || result[:data]
        expect(room_info[:name]).to eq('Test Room')
      end

      it 'targets the left observe panel' do
        result = command.execute('observe room')
        expect(result[:target_panel]).to eq(:left_observe_window)
      end
    end

    context 'stop observing place' do
      let!(:bar) do
        Place.create(
          name: 'The Bar',
          room: room,
          is_furniture: true
        )
      end

      before do
        character_instance.start_observing_place!(bar)
      end

      it 'stops observing place with "observe stop"' do
        result = command.execute('observe stop')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stop observing The Bar')
        expect(character_instance.reload.observing_place_id).to be_nil
      end
    end

    context 'stop observing room' do
      before do
        character_instance.start_observing_room!
      end

      it 'stops observing room with "observe stop"' do
        result = command.execute('observe stop')
        expect(result[:success]).to be true
        expect(result[:message]).to include('stop observing the room')
        expect(character_instance.reload.observing_room).to be false
      end
    end

    context 'switching between observation types' do
      let!(:bar) do
        Place.create(
          name: 'The Bar',
          room: room,
          is_furniture: true
        )
      end

      it 'switches from character to place observation' do
        character_instance.start_observing!(bob_instance)
        command.execute('observe bar')
        character_instance.reload
        expect(character_instance.observing_id).to be_nil
        expect(character_instance.observing_place_id).to eq(bar.id)
      end

      it 'switches from place to room observation' do
        character_instance.start_observing_place!(bar)
        command.execute('observe room')
        character_instance.reload
        expect(character_instance.observing_place_id).to be_nil
        expect(character_instance.observing_room).to be true
      end

      it 'switches from room to character observation' do
        character_instance.start_observing_room!
        command.execute('observe Bob')
        character_instance.reload
        expect(character_instance.observing_room).to be false
        expect(character_instance.observing_id).to eq(bob_instance.id)
      end
    end
  end
end
