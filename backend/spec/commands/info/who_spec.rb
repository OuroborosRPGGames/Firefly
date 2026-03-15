# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Info::Who, type: :command do
  let(:area) { create(:area, name: 'Test Area') }
  let(:location) { create(:location, zone: area, name: 'Test Location') }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:other_room) { create(:room, location: location, name: 'Other Room', short_description: 'Another room') }
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
  # Alice knows Bob so she sees his name in who
  let!(:alice_knows_bob) do
    create(:character_knowledge, knower_character: character, known_character: bob_character, known_name: 'Bob Smith')
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'who in room' do
      it 'lists online characters in the room' do
        result = command.execute('who here')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('Test Room')
      end

      it 'excludes the commanding character' do
        result = command.execute('who here')
        expect(result[:success]).to be true
        expect(result[:message]).not_to include('Alice Test')
      end

      it 'shows alone message when no others in room' do
        bob_instance.update(current_room: other_room)
        result = command.execute('who here')
        expect(result[:success]).to be true
        expect(result[:message]).to include("alone")
      end

      it 'includes stance information' do
        bob_instance.update(stance: 'sitting')
        result = command.execute('who here')
        expect(result[:success]).to be true
        expect(result[:message]).to include('sitting')
      end
    end

    context 'who in area' do
      it 'lists characters in the area' do
        result = command.execute('who')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob')
      end

      it 'groups by room when characters are in different rooms' do
        bob_instance.update(current_room: other_room)
        result = command.execute('who')
        expect(result[:success]).to be true
        # Should show both rooms if characters in different rooms
        expect(result[:message]).to include('Test Area')
      end
    end

    context 'who globally' do
      it 'lists all online characters' do
        result = command.execute('who all')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob')
        expect(result[:data][:scope]).to eq('global')
      end

      it 'shows only one online message when alone' do
        bob_instance.update(online: false)
        result = command.execute('who all')
        expect(result[:success]).to be true
        expect(result[:message]).to include("the only one online")
      end
    end

    context 'invalid scope' do
      it 'returns error for unknown scope' do
        result = command.execute('who somewhere')
        expect(result[:success]).to be false
        expect(result[:message]).to include("Unknown scope")
      end
    end

    context 'visibility filtering' do
      context 'private mode' do
        it 'hides characters in private mode from who all' do
          bob_instance.update(private_mode: true)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).not_to include('Bob')
        end

        it 'shows characters not in private mode' do
          bob_instance.update(private_mode: false)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Bob')
        end
      end

      context 'secluded rooms' do
        it 'hides characters in secluded rooms from who all' do
          other_room.update(publicity: 'secluded')
          bob_instance.update(current_room: other_room)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).not_to include('Bob')
        end

        it 'shows characters in semi_public rooms' do
          other_room.update(publicity: 'semi_public')
          bob_instance.update(current_room: other_room)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Bob')
        end

        it 'shows characters in public rooms' do
          other_room.update(publicity: 'public')
          bob_instance.update(current_room: other_room)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Bob')
        end
      end

      context 'event visibility' do
        let(:public_event) do
          Event.create(
            name: 'Public Party',
            title: 'Public Party',
            event_type: 'party',
            starts_at: Time.now + 3600,
            is_public: true,
            room: room,
            organizer: bob_character
          )
        end

        let(:private_event) do
          Event.create(
            name: 'Private Meeting',
            title: 'Private Meeting',
            event_type: 'private',
            starts_at: Time.now + 3600,
            is_public: false,
            room: room,
            organizer: bob_character
          )
        end

        it 'shows characters in public events under At Events section' do
          bob_instance.update(in_event_id: public_event.id)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Event: Public Party')
          expect(result[:message]).to include('Bob')
        end

        it 'hides characters in private events from non-attendees' do
          bob_instance.update(in_event_id: private_event.id)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).not_to include('Bob')
          expect(result[:message]).not_to include('Private Meeting')
        end

        it 'shows characters in private events to attendees' do
          bob_instance.update(in_event_id: private_event.id)
          EventAttendee.create(event: private_event, character: character, status: 'yes')
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Bob')
          expect(result[:message]).to include('Private Meeting')
        end

        it 'shows characters in private events to organizer' do
          private_event_as_organizer = Event.create(
            name: 'My Private Event',
            title: 'My Private Event',
            event_type: 'private',
            starts_at: Time.now + 3600,
            is_public: false,
            room: room,
            organizer: character
          )
          bob_instance.update(in_event_id: private_event_as_organizer.id)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Bob')
        end
      end

      context 'timeline visibility' do
        let(:flashback_reality) { Reality.create(name: 'Flashback', reality_type: 'flashback', time_offset: 0) }
        let(:timeline) do
          Timeline.create(
            reality: flashback_reality,
            timeline_type: 'historical',
            name: 'Year 1985 - Downtown',
            year: 1985,
            zone: area
          )
        end

        it 'shows characters in historical timelines under In Timelines section' do
          bob_instance.update(timeline_id: timeline.id)
          result = command.execute('who all')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Timeline:')
          expect(result[:message]).to include('Year 1985')
          expect(result[:message]).to include('Bob')
        end

        context 'snapshot timelines' do
          let(:snapshot) do
            CharacterSnapshot.create(
              character: bob_character,
              room: room,
              name: 'Memory Snapshot',
              frozen_state: Sequel.pg_jsonb_wrap({ level: 1 }),
              frozen_inventory: Sequel.pg_jsonb_wrap([]),
              frozen_descriptions: Sequel.pg_jsonb_wrap([]),
              allowed_character_ids: Sequel.pg_jsonb_wrap([bob_character.id]), # Only Bob is allowed
              snapshot_taken_at: Time.now
            )
          end

          let(:snapshot_reality) { Reality.create(name: 'Snapshot Reality', reality_type: 'flashback', time_offset: 0) }
          let(:snapshot_timeline) do
            Timeline.create(
              reality: snapshot_reality,
              timeline_type: 'snapshot',
              name: snapshot.name,
              snapshot_id: snapshot.id,
              source_character_id: bob_character.id
            )
          end

          it 'hides characters in snapshot timelines from non-participants' do
            # Alice (viewer) is NOT in the allowed_character_ids, so she can't see Bob
            bob_instance.update(timeline_id: snapshot_timeline.id)
            result = command.execute('who all')
            expect(result[:success]).to be true
            expect(result[:message]).not_to include('Bob')
          end

          it 'shows characters in snapshot timelines to participants' do
            # Add Alice (viewer) to allowed_character_ids so she can see Bob
            snapshot.update(allowed_character_ids: Sequel.pg_jsonb_wrap([character.id, bob_character.id]))
            bob_instance.update(timeline_id: snapshot_timeline.id)
            result = command.execute('who all')
            expect(result[:success]).to be true
            expect(result[:message]).to include('Bob')
            expect(result[:message]).to include('Memory Snapshot')
          end
        end
      end
    end

    context 'upcoming event display' do
      it 'shows upcoming public event at bottom of who all' do
        Event.create(
          name: 'Grand Opening',
          title: 'Grand Opening',
          event_type: 'party',
          starts_at: Time.now + 7200, # 2 hours from now
          is_public: true,
          room: room,
          organizer: character
        )
        result = command.execute('who all')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Next Event:')
        expect(result[:message]).to include('Grand Opening')
        expect(result[:message]).to match(/in [12] hours?/) # 1 or 2 hours due to timing
      end

      it 'shows "starting soon" for events less than an hour away' do
        Event.create(
          name: 'Imminent Party',
          title: 'Imminent Party',
          event_type: 'party',
          starts_at: Time.now + 1800, # 30 minutes from now
          is_public: true,
          room: room,
          organizer: character
        )
        result = command.execute('who all')
        expect(result[:success]).to be true
        expect(result[:message]).to include('starting soon')
      end

      it 'shows date for events more than 24 hours away' do
        Event.create(
          name: 'Future Party',
          title: 'Future Party',
          event_type: 'party',
          starts_at: Time.now + (48 * 3600), # 2 days from now
          is_public: true,
          room: room,
          organizer: character
        )
        result = command.execute('who all')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Future Party')
        # Should show date format like "Jan 24 at 03:00 PM"
        expect(result[:message]).to match(/\w+ \d+ at \d+:\d+ [AP]M/)
      end

      it 'does not show private events' do
        Event.create(
          name: 'Secret Meeting',
          title: 'Secret Meeting',
          event_type: 'private',
          starts_at: Time.now + 3600,
          is_public: false,
          room: room,
          organizer: bob_character
        )
        result = command.execute('who all')
        expect(result[:success]).to be true
        expect(result[:message]).not_to include('Secret Meeting')
      end
    end
  end
end
