# frozen_string_literal: true

require 'spec_helper'

describe 'Phase 15 Edge Case E2E Tests - Events, Media, News' do
  let(:character) { create(:character, name: 'Test Character') }
  let(:character_instance) { create(:character_instance, character: character) }
  let(:room) { character_instance.current_room }

  describe 'Phase 15.1: Event Edge Cases' do
    # Test 1: Very long event name (200+ chars)
    describe 'event with very long name' do
      it 'creates event with truncation or errors gracefully' do
        long_name = 'A' * 250
        cmd = Commands::Events::CreateEvent.new(character_instance)

        result = cmd.execute("create event #{long_name}")

        # Should either create successfully with truncation or error about max length
        # Model has validates_max_length 200, :name
        if result[:success]
          event = Event.last
          expect(event.name.length).to be <= 200
        else
          # If it errors, message should be clear
          expect(result[:error] || result[:message]).not_to be_nil
        end
      end
    end

    # Test 2: XSS attack in event name
    describe 'event with XSS script tag' do
      it 'sanitizes XSS attack in name' do
        xss_name = "Party <script>alert('xss')</script>"
        cmd = Commands::Events::CreateEvent.new(character_instance)

        result = cmd.execute("create event #{xss_name}")

        # Event name should be sanitized/safe - at minimum HTML tags should be stripped
        if result[:success]
          event = Event.last
          expect(event.name).not_to include('<script>')
          expect(event.name).not_to include('</script>')
        end
      end
    end

    # Test 3: Multiple events in same room
    describe 'multiple events at same location' do
      it 'shows both events in events here' do
        # Create first event
        EventService.create_event(
          organizer: character,
          name: 'Event One',
          starts_at: Time.now + 3600,
          room: room,
          event_type: 'party'
        )

        # Create second event at same room
        EventService.create_event(
          organizer: character,
          name: 'Event Two',
          starts_at: Time.now + 7200,
          room: room,
          event_type: 'party'
        )

        # Query events at room
        events = EventService.events_at_room(room, limit: 10)
        expect(events.count).to eq(2)
        expect(events.map(&:name)).to include('Event One', 'Event Two')
      end
    end

    # Test 4: Enter event at different location
    describe 'enter event from different location' do
      it 'errors when trying to enter event from wrong location' do
        # Create event at current room
        event = EventService.create_event(
          organizer: character,
          name: 'Test Event',
          starts_at: Time.now,
          room: room,
          event_type: 'party'
        )
        event.start!

        # Try to enter from same room (should work)
        cmd = Commands::Events::EnterEvent.new(character_instance)
        result = cmd.execute('enter event')
        expect(result[:success]).to be true

        # Leave the event
        character_instance.update(in_event_id: nil)

        # Move to different room (if possible)
        other_room = Room.exclude(id: room.id).first
        if other_room
          character_instance.update(current_room_id: other_room.id)

          # Try to enter from different room (should fail)
          result = cmd.execute('enter event')
          expect(result[:success]).to be false
          expect((result[:error] || result[:message])).to include('no active event')
        end
      end
    end

    # Test 5: Rapid lifecycle transitions
    describe 'rapid event lifecycle transitions' do
      it 'handles create, start, end without errors' do
        # Create event
        create_cmd = Commands::Events::CreateEvent.new(character_instance)
        create_result = create_cmd.execute('create event Quick Test')
        expect(create_result[:success]).to be true

        event = Event.where(name: 'Quick Test').first
        expect(event).not_to be_nil

        # Start event
        event.start!
        expect(event.reload.active?).to be true

        # End event
        event.end_for_all!
        expect(event.reload.completed?).to be true
      end
    end

    # Test 6: Cancel event (if available)
    describe 'cancel event' do
      it 'handles cancel attempt' do
        # Create event
        event = EventService.create_event(
          organizer: character,
          name: 'Cancel Me',
          starts_at: Time.now + 3600,
          room: room,
          event_type: 'party'
        )

        # Try to cancel
        EventService.cancel_event!(event)
        expect(event.reload.cancelled?).to be true
      end
    end
  end

  describe 'Phase 15.2: Media Edge Cases' do
    # Test 1: Multiple stop attempts with no media playing
    describe 'media stop with nothing playing' do
      it 'errors gracefully on multiple stop attempts' do
        cmd = Commands::Entertainment::MediaControl.new(character_instance)

        # First stop attempt (nothing playing)
        result1 = cmd.execute('media stop')
        expect(result1[:success]).to be false
        expect((result1[:error] || result1[:message])).to include('playing')

        # Second stop attempt (still nothing)
        result2 = cmd.execute('media stop')
        expect(result2[:success]).to be false
        expect((result2[:error] || result2[:message])).to include('playing')
      end
    end

    # Test 2: Unknown media action
    describe 'unknown media action' do
      it 'errors with helpful message' do
        cmd = Commands::Entertainment::MediaControl.new(character_instance)
        result = cmd.execute('media foobar')

        expect(result[:success]).to be false
        expect((result[:error] || result[:message])).to include('Unknown action')
      end
    end
  end

  describe 'Phase 15.3: News Edge Cases' do
    let!(:user) { create(:user) }
    let!(:article) do
      StaffBulletin.create(
        news_type: 'announcement',
        title: 'Test Announcement',
        content: 'Test content for news edge cases.',
        is_published: true,
        published_at: Time.now,
        created_by_user_id: user.id
      )
    end

    # Test 1: Invalid article ID (9999)
    describe 'news with invalid article ID' do
      it 'errors not found or not published' do
        cmd = Commands::System::News.new(character_instance)
        result = cmd.execute('news 9999')

        expect(result[:success]).to be false
        expect((result[:error] || result[:message])).to include('not found')
      end
    end

    # Test 2: Zero article ID
    describe 'news with zero ID' do
      it 'errors asking for valid ID' do
        cmd = Commands::System::News.new(character_instance)
        result = cmd.execute('news 0')

        expect(result[:success]).to be false
        expect((result[:error] || result[:message])).to include('Please specify')
      end
    end

    # Test 3: Negative article ID (treated as unknown category since it's not numeric)
    describe 'news with negative ID' do
      it 'errors gracefully for negative ID' do
        cmd = Commands::System::News.new(character_instance)
        result = cmd.execute('news -1')

        expect(result[:success]).to be false
        expect((result[:error] || result[:message])).to include('Unknown category')
      end
    end

    # Test 4: Unknown category
    describe 'news with unknown category' do
      it 'errors about unknown category' do
        cmd = Commands::System::News.new(character_instance)
        result = cmd.execute('news sports')

        expect(result[:success]).to be false
        expect((result[:error] || result[:message])).to include('Unknown category')
      end
    end

    # Test 5: News base command
    describe 'news with no arguments' do
      it 'shows categories' do
        cmd = Commands::System::News.new(character_instance)
        result = cmd.execute('news')

        expect(result[:success]).to be true
        msg = result[:message] || ''
        expect(msg).to match(/News|Announcements/)
      end
    end

    # Test 6: Read same article twice
    describe 'read same article twice' do
      it 'second read does not error' do
        cmd = Commands::System::News.new(character_instance)

        # First read
        result1 = cmd.execute("news #{article.id}")
        expect(result1[:success]).to be true

        # Second read
        result2 = cmd.execute("news #{article.id}")
        expect(result2[:success]).to be true
      end
    end
  end
end
