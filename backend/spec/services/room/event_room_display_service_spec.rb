# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EventRoomDisplayService do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Event Hall') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:viewer_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end
  let(:organizer_character) { create(:character, forename: 'Organizer') }
  let(:event) do
    double('Event',
           id: 1,
           name: 'Festival',
           description: 'A grand celebration',
           event_type: 'festival',
           organizer: organizer_character,
           organizer_id: organizer_character.id,
           starts_at: Time.now - 3600,
           active?: true,
           attendee_count: 25)
  end

  subject(:service) { described_class.new(room, viewer_instance, event) }

  describe 'inheritance' do
    it 'inherits from RoomDisplayService' do
      expect(described_class.superclass).to eq(RoomDisplayService)
    end
  end

  describe 'initialization' do
    it 'accepts room, viewer_instance, and event parameters' do
      expect(service.instance_variable_get(:@room)).to eq(room)
      expect(service.instance_variable_get(:@viewer)).to eq(viewer_instance)
      expect(service.event).to eq(event)
    end

    it 'exposes event via attr_reader' do
      expect(service.event).to eq(event)
    end
  end

  describe '#build_display' do
    before do
      allow(room).to receive(:location).and_return(location)
      allow(room).to receive(:current_description).and_return('A grand hall.')
      allow(room).to receive(:current_background_url).and_return('https://example.com/bg.jpg')
      allow(room).to receive(:short_description).and_return('Grand Hall')
      allow(room).to receive(:room_type).and_return('hall')
      allow(room).to receive(:safe_room).and_return(true)
      allow(room).to receive(:visible_places) do
        dataset = double('PlacesDataset')
        allow(dataset).to receive(:all).and_return([])
        allow(dataset).to receive(:each) { |&block| [].each(&block) }
        dataset
      end
      allow(room).to receive(:visible_decorations) do
        dataset = double('DecorationsDataset')
        allow(dataset).to receive(:all).and_return([])
        allow(dataset).to receive(:each) { |&block| [].each(&block) }
        dataset
      end
      allow(GameTimeService).to receive(:time_of_day).and_return('evening')
      allow(GameTimeService).to receive(:season).and_return('summer')
      allow(EventService).to receive(:is_host_or_staff?).and_return(false)
    end

    context 'when event is active' do
      let(:room_state) do
        double('RoomState',
               effective_description: 'Decorated for the festival!',
               effective_background_url: 'https://example.com/festival-bg.jpg')
      end
      let(:event_place) do
        double('EventPlace',
               id: 10,
               name: 'Stage',
               description: 'A grand stage',
               place_type: 'stage',
               is_furniture: false,
               sit_action: nil,
               image_url: 'https://example.com/stage.jpg')
      end
      let(:event_decoration) do
        double('EventDecoration',
               id: 20,
               name: 'Banner',
               description: 'Festival banner',
               image_url: 'https://example.com/banner.jpg')
      end

      before do
        allow(event).to receive(:room_state_for).with(room).and_return(room_state)
        allow(event).to receive(:places_for).with(room) do
          dataset = double('EventPlacesDataset')
          allow(dataset).to receive(:all).and_return([event_place])
          allow(dataset).to receive(:each) { |&block| [event_place].each(&block) }
          dataset
        end
        allow(event).to receive(:decorations_for).with(room) do
          dataset = double('EventDecorationsDataset')
          allow(dataset).to receive(:all).and_return([event_decoration])
          allow(dataset).to receive(:each) { |&block| [event_decoration].each(&block) }
          dataset
        end
        allow(CharacterInstance).to receive(:where).and_call_original
      end

      it 'includes event info in display' do
        # Need to stub the parent class's build_display
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        expect(result[:event][:id]).to eq(1)
        expect(result[:event][:name]).to eq('Festival')
        expect(result[:event][:description]).to eq('A grand celebration')
        expect(result[:event][:event_type]).to eq('festival')
        expect(result[:event][:attendee_count]).to eq(25)
      end

      it 'marks room as in_event' do
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        expect(result[:room][:in_event]).to be true
        expect(result[:room][:event_name]).to eq('Festival')
      end

      it 'uses event room description override' do
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        expect(result[:room][:description]).to eq('Decorated for the festival!')
      end

      it 'uses event background override' do
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        expect(result[:room][:background_picture_url]).to eq('https://example.com/festival-bg.jpg')
      end

      it 'includes event places' do
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        event_place_data = result[:places].find { |p| p[:is_event_place] }
        expect(event_place_data).not_to be_nil
        expect(event_place_data[:name]).to eq('Stage')
        expect(event_place_data[:event_id]).to eq(1)
      end

      it 'includes event decorations' do
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        event_dec_data = result[:decorations].find { |d| d[:is_event_decoration] }
        expect(event_dec_data).not_to be_nil
        expect(event_dec_data[:name]).to eq('Banner')
        expect(event_dec_data[:event_id]).to eq(1)
      end

      it 'includes merged thumbnails' do
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        expect(result[:thumbnails]).to be_an(Array)
        expect(result[:thumbnails].any? { |t| t[:type] == 'event_place' }).to be true
        expect(result[:thumbnails].any? { |t| t[:type] == 'event_decoration' }).to be true
      end

      it 'indicates if viewer is host' do
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

        result = service.build_display

        expect(result[:event][:is_host]).to be false
      end

      context 'when viewer is organizer' do
        before do
          allow(event).to receive(:organizer_id).and_return(character.id)
        end

        it 'marks viewer as host' do
          allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

          result = service.build_display

          expect(result[:event][:is_host]).to be true
        end
      end

      context 'when viewer is staff' do
        before do
          allow(EventService).to receive(:is_host_or_staff?).and_return(true)
        end

        it 'marks viewer as staff' do
          allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return({})

          result = service.build_display

          expect(result[:event][:is_staff]).to be true
        end
      end
    end

    context 'when event is not active' do
      before do
        allow(event).to receive(:active?).and_return(false)
      end

      it 'returns base display without event modifications' do
        base_result = { room: { name: 'Event Hall' } }
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return(base_result)

        result = service.build_display

        expect(result).to eq(base_result)
        expect(result[:event]).to be_nil
      end
    end

    context 'when event is nil' do
      subject(:service) { described_class.new(room, viewer_instance, nil) }

      it 'returns base display' do
        base_result = { room: { name: 'Event Hall' } }
        allow_any_instance_of(RoomDisplayService).to receive(:build_display).and_return(base_result)

        result = service.build_display

        expect(result).to eq(base_result)
      end
    end
  end

  describe '#event_room_info' do
    before do
      allow(room).to receive(:location).and_return(location)
      allow(room).to receive(:current_description).and_return('A grand hall.')
      allow(room).to receive(:current_background_url).and_return('https://example.com/bg.jpg')
      allow(room).to receive(:short_description).and_return('Grand Hall')
      allow(room).to receive(:room_type).and_return('hall')
      allow(room).to receive(:safe_room).and_return(true)
      allow(GameTimeService).to receive(:time_of_day).and_return('evening')
      allow(GameTimeService).to receive(:season).and_return('summer')
    end

    context 'with room state override' do
      let(:room_state) do
        double('RoomState',
               effective_description: 'Festival decorations!',
               effective_background_url: 'https://example.com/festival.jpg')
      end

      before do
        allow(event).to receive(:room_state_for).with(room).and_return(room_state)
      end

      it 'overrides description' do
        result = service.send(:event_room_info)

        expect(result[:description]).to eq('Festival decorations!')
      end

      it 'overrides background URL' do
        result = service.send(:event_room_info)

        expect(result[:background_picture_url]).to eq('https://example.com/festival.jpg')
      end
    end

    context 'without room state override' do
      before do
        allow(event).to receive(:room_state_for).with(room).and_return(nil)
      end

      it 'uses original room description' do
        result = service.send(:event_room_info)

        expect(result[:description]).to eq('A grand hall.')
      end
    end
  end

  describe '#event_places' do
    let(:event_place) do
      double('EventPlace',
             id: 10,
             name: 'Dance Floor',
             description: 'A wooden floor for dancing',
             place_type: 'dance_floor',
             is_furniture: false,
             sit_action: 'dance on',
             image_url: 'https://example.com/floor.jpg')
    end

    before do
      allow(event).to receive(:places_for).with(room).and_return(double(all: [event_place]))
      allow(CharacterInstance).to receive(:where).and_call_original
    end

    it 'returns event places with prefixed ID' do
      result = service.send(:event_places)

      expect(result.first[:id]).to eq('event_place_10')
    end

    it 'marks places as event places' do
      result = service.send(:event_places)

      expect(result.first[:is_event_place]).to be true
      expect(result.first[:event_id]).to eq(1)
    end

    it 'includes all place attributes' do
      result = service.send(:event_places)
      place = result.first

      expect(place[:name]).to eq('Dance Floor')
      expect(place[:description]).to eq('A wooden floor for dancing')
      expect(place[:place_type]).to eq('dance_floor')
      expect(place[:default_sit_action]).to eq('dance on')
      expect(place[:image_url]).to eq('https://example.com/floor.jpg')
      expect(place[:has_image]).to be true
    end
  end

  describe '#event_decorations' do
    let(:event_decoration) do
      double('EventDecoration',
             id: 20,
             name: 'Streamers',
             description: 'Colorful streamers',
             image_url: 'https://example.com/streamers.jpg')
    end

    before do
      allow(event).to receive(:decorations_for).with(room).and_return(double(all: [event_decoration]))
    end

    it 'returns event decorations with prefixed ID' do
      result = service.send(:event_decorations)

      expect(result.first[:id]).to eq('event_dec_20')
    end

    it 'marks decorations as event decorations' do
      result = service.send(:event_decorations)

      expect(result.first[:is_event_decoration]).to be true
      expect(result.first[:event_id]).to eq(1)
    end

    it 'includes all decoration attributes' do
      result = service.send(:event_decorations)
      dec = result.first

      expect(dec[:name]).to eq('Streamers')
      expect(dec[:description]).to eq('Colorful streamers')
      expect(dec[:image_url]).to eq('https://example.com/streamers.jpg')
      expect(dec[:has_image]).to be true
    end

    context 'with decoration without image' do
      before do
        allow(event_decoration).to receive(:image_url).and_return('')
      end

      it 'marks has_image as false' do
        result = service.send(:event_decorations)

        expect(result.first[:has_image]).to be false
      end
    end
  end

  describe '#event_info' do
    before do
      allow(EventService).to receive(:is_host_or_staff?).and_return(false)
    end

    it 'returns complete event information' do
      result = service.send(:event_info)

      expect(result[:id]).to eq(1)
      expect(result[:name]).to eq('Festival')
      expect(result[:description]).to eq('A grand celebration')
      expect(result[:event_type]).to eq('festival')
      expect(result[:organizer_name]).to eq('Organizer')
      expect(result[:starts_at]).to eq(event.starts_at)
      expect(result[:attendee_count]).to eq(25)
    end

    it 'checks if viewer is host' do
      result = service.send(:event_info)

      expect(result[:is_host]).to be false
    end

    it 'checks if viewer is staff' do
      result = service.send(:event_info)

      expect(result[:is_staff]).to be false
    end

    context 'when viewer is organizer' do
      before do
        allow(event).to receive(:organizer_id).and_return(character.id)
      end

      it 'marks as host' do
        result = service.send(:event_info)

        expect(result[:is_host]).to be true
      end
    end
  end

  describe '#merged_thumbnails' do
    let(:permanent_place) { double('Place', image_url: 'https://example.com/perm-place.jpg', has_image?: true, name: 'Table') }
    let(:permanent_decoration) { double('Decoration', image_url: 'https://example.com/perm-dec.jpg', has_image?: true, name: 'Painting') }
    let(:event_place) { double('EventPlace', image_url: 'https://example.com/event-place.jpg', name: 'Stage') }
    let(:event_decoration) { double('EventDecoration', image_url: 'https://example.com/event-dec.jpg', name: 'Banner') }
    let(:room_state) { double('RoomState', effective_background_url: 'https://example.com/event-bg.jpg') }

    before do
      allow(room).to receive(:location).and_return(location)
      allow(room).to receive(:visible_places).and_return([permanent_place])
      allow(room).to receive(:visible_decorations).and_return([permanent_decoration])
      allow(room).to receive(:current_background_url).and_return('https://example.com/bg.jpg')
      allow(event).to receive(:places_for).with(room).and_return([event_place])
      allow(event).to receive(:decorations_for).with(room).and_return([event_decoration])
      allow(event).to receive(:room_state_for).with(room).and_return(room_state)
    end

    it 'includes permanent place thumbnails' do
      result = service.send(:merged_thumbnails)

      place_thumb = result.find { |t| t[:type] == 'place' }
      expect(place_thumb[:url]).to eq('https://example.com/perm-place.jpg')
      expect(place_thumb[:alt]).to eq('Table')
    end

    it 'includes event place thumbnails' do
      result = service.send(:merged_thumbnails)

      event_place_thumb = result.find { |t| t[:type] == 'event_place' }
      expect(event_place_thumb[:url]).to eq('https://example.com/event-place.jpg')
      expect(event_place_thumb[:alt]).to eq('Stage')
    end

    it 'includes permanent decoration thumbnails' do
      result = service.send(:merged_thumbnails)

      dec_thumb = result.find { |t| t[:type] == 'decoration' }
      expect(dec_thumb[:url]).to eq('https://example.com/perm-dec.jpg')
      expect(dec_thumb[:alt]).to eq('Painting')
    end

    it 'includes event decoration thumbnails' do
      result = service.send(:merged_thumbnails)

      event_dec_thumb = result.find { |t| t[:type] == 'event_decoration' }
      expect(event_dec_thumb[:url]).to eq('https://example.com/event-dec.jpg')
      expect(event_dec_thumb[:alt]).to eq('Banner')
    end

    it 'uses event background for background thumbnail' do
      result = service.send(:merged_thumbnails)

      bg_thumb = result.find { |t| t[:type] == 'background' }
      expect(bg_thumb[:url]).to eq('https://example.com/event-bg.jpg')
    end

    context 'without event room state' do
      before do
        allow(event).to receive(:room_state_for).with(room).and_return(nil)
      end

      it 'uses original room background' do
        result = service.send(:merged_thumbnails)

        bg_thumb = result.find { |t| t[:type] == 'background' }
        expect(bg_thumb[:url]).to eq('https://example.com/bg.jpg')
      end
    end

    context 'with empty image URLs' do
      before do
        allow(event_place).to receive(:image_url).and_return('')
        allow(event_decoration).to receive(:image_url).and_return(nil)
      end

      it 'excludes items without images' do
        result = service.send(:merged_thumbnails)

        expect(result.none? { |t| t[:type] == 'event_place' }).to be true
        expect(result.none? { |t| t[:type] == 'event_decoration' }).to be true
      end
    end
  end
end
