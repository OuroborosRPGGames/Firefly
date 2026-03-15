# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Journey, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area, world: world, name: 'Starting City') }
  let(:destination_location) { create(:location, zone: area, world: world, name: 'Ravencroft', city_name: 'Ravencroft') }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_room)
    allow(BroadcastService).to receive(:send_system_message)
  end

  describe 'command registration' do
    it 'is registered with the registry' do
      cmd_class, _ = Commands::Base::Registry.find_command('journey')
      expect(cmd_class).to eq(described_class)
    end

    it 'has correct command name' do
      expect(described_class.command_name).to eq('journey')
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('world_travel', 'voyage', 'travel')
    end

    it 'has category navigation' do
      expect(described_class.category).to eq(:navigation)
    end

    it 'has help text' do
      expect(described_class.help_text).not_to be_empty
    end

    it 'has usage' do
      expect(described_class.usage).to include('journey')
    end
  end

  describe '#execute' do
    context 'when in combat' do
      before do
        allow(character_instance).to receive(:in_combat?).and_return(true)
      end

      it 'returns error' do
        result = command.execute('journey')

        expect(result[:success]).to be false
        expect(result[:message]).to include('combat')
      end
    end

    context 'with no arguments' do
      context 'when traveling' do
        let(:journey) do
          double('WorldJourney',
                 destination_location: destination_location,
                 time_remaining_display: '2 hours')
        end

        before do
          allow(character_instance).to receive(:traveling?).and_return(true)
          allow(character_instance).to receive(:flashback_instanced?).and_return(false)
          allow(character_instance).to receive(:current_world_journey).and_return(journey)
        end

        it 'shows current journey menu' do
          result = command.execute('journey')

          expect(result[:success]).to be true
        end
      end

      context 'when in flashback instance' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)
          allow(character_instance).to receive(:flashback_instanced?).and_return(true)
          allow(character_instance).to receive(:flashback_travel_mode).and_return('return')
          allow(character_instance).to receive(:flashback_origin_room).and_return(room)
          allow(character_instance).to receive(:flashback_time_reserved).and_return(3600)
          allow(FlashbackTimeService).to receive(:format_time).and_return('1 hour')
        end

        it 'shows flashback status menu' do
          result = command.execute('journey')

          expect(result[:success]).to be true
        end
      end

      context 'when not traveling' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)
          allow(character_instance).to receive(:flashback_instanced?).and_return(false)
        end

        it 'opens travel GUI' do
          result = command.execute('journey')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:open_gui)
          expect(result[:data][:gui]).to eq('travel_map')
        end
      end
    end

    context 'with "to <destination>" argument' do
      before do
        allow(character_instance).to receive(:traveling?).and_return(false)
        # Mock the Location query chain - need to support: where().where().exclude().first
        # and also: where().where().first
        location_result = double('LocationResult', first: nil)
        allow(location_result).to receive(:exclude).and_return(location_result)
        location_dataset = double('LocationDataset')
        allow(location_dataset).to receive(:where).and_return(location_result)
        allow(Location).to receive(:where).and_return(location_dataset)

        zone_dataset = double('ZoneDataset')
        allow(zone_dataset).to receive(:where).and_return(double(first: nil))
        allow(Zone).to receive(:where).and_return(zone_dataset)
      end

      context 'when already traveling' do
        let(:journey) do
          double('WorldJourney',
                 destination_location: destination_location)
        end

        before do
          allow(character_instance).to receive(:traveling?).and_return(true)
          allow(character_instance).to receive(:current_world_journey).and_return(journey)
        end

        it 'returns error' do
          result = command.execute('journey to Ravencroft')

          expect(result[:success]).to be false
          expect(result[:message]).to include('already on a journey')
        end
      end

      context 'when destination not found' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)
        end

        it 'returns error' do
          result = command.execute('journey to Nonexistent')

          expect(result[:success]).to be false
          expect(result[:message]).to include("Cannot find a location")
        end
      end

      context 'when destination is current location' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)

          # Mock finding the current location as destination
          location_dataset = double('Dataset')
          allow(Location).to receive(:where).with(world_id: world.id).and_return(location_dataset)
          allow(location_dataset).to receive(:where).with(Sequel.ilike(:city_name, 'Starting City')).and_return(
            double(first: location)
          )

          allow(room).to receive(:location).and_return(location)
        end

        it 'returns error' do
          result = command.execute('journey to Starting City')

          expect(result[:success]).to be false
          expect(result[:message]).to include("already at")
        end
      end

      context 'when destination is valid' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)

          # Mock successful destination lookup
          location_dataset = double('Dataset')
          allow(Location).to receive(:where).with(world_id: world.id).and_return(location_dataset)
          allow(location_dataset).to receive(:where).with(Sequel.ilike(:city_name, 'Ravencroft')).and_return(
            double(first: destination_location)
          )

          allow(JourneyService).to receive(:travel_options).and_return({
            success: true,
            destination: { id: destination_location.id, name: 'Ravencroft' },
            origin: { id: location.id, name: 'Starting City' },
            journey_time_display: '4 hours',
            flashback: { available: 0, basic: { success: false }, return: { success: false }, backloaded: { success: false } },
            available_modes: ['train']
          })
        end

        it 'shows travel quickmenu' do
          result = command.execute('journey to Ravencroft')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:quickmenu)
          expect(result[:data][:options].any? { |i| i[:key] == 'assemble_party' }).to be true
        end

        it 'calls JourneyService for travel options' do
          command.execute('journey to Ravencroft')

          expect(JourneyService).to have_received(:travel_options)
            .with(character_instance, destination_location)
        end
      end

      context 'when JourneyService returns error' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)

          location_dataset = double('Dataset')
          allow(Location).to receive(:where).with(world_id: world.id).and_return(location_dataset)
          allow(location_dataset).to receive(:where).with(Sequel.ilike(:city_name, 'Ravencroft')).and_return(
            double(first: destination_location)
          )

          allow(JourneyService).to receive(:travel_options).and_return({
            success: false,
            error: 'No transport available'
          })
        end

        it 'returns error' do
          result = command.execute('journey to Ravencroft')

          expect(result[:success]).to be false
          expect(result[:message]).to include('No transport available')
        end
      end
    end

    context 'with "party" argument' do
      context 'when traveling' do
        let(:journey) do
          j = double('WorldJourney',
                     destination_location: destination_location,
                     vehicle_type: 'train',
                     passengers: [character_instance],
                     driver: nil,
                     time_remaining_display: '2 hours')
          allow(j).to receive(:driver).and_return(nil)
          j
        end

        before do
          allow(character_instance).to receive(:traveling?).and_return(true)
          allow(character_instance).to receive(:current_world_journey).and_return(journey)
          allow(character_instance).to receive(:full_name).and_return(character.full_name)
        end

        it 'shows passengers' do
          result = command.execute('journey party')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:travel_passengers)
        end
      end

      context 'when not traveling' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)
          allow(TravelParty).to receive(:where).and_return(double(first: nil))
          allow(TravelPartyMember).to receive(:join).and_return(
            double(where: double(where: double(first: nil)))
          )
        end

        it 'returns error if no party' do
          result = command.execute('journey party')

          expect(result[:success]).to be false
          # Message uses HTML entities for apostrophes (&#39; or &#x27;)
          expect(result[:message]).to match(/don(&#39;|&#x27;)t have an active travel party/)
        end

        context 'when leader of a party' do
          let(:party) do
            p = double('TravelParty',
                       id: 1,
                       status_summary: {
                         destination: 'Ravencroft',
                         travel_mode: 'train',
                         flashback_mode: 'none',
                         members: [
                           { name: character.full_name, status: 'accepted', is_leader: true }
                         ]
                       })
            p
          end

          before do
            allow(TravelParty).to receive(:where).and_return(double(first: party))
          end

          it 'shows party status' do
            result = command.execute('journey party')

            expect(result[:success]).to be true
            expect(result[:message]).to include('Travel Party')
          end
        end
      end
    end

    context 'with "return" argument' do
      context 'when not in flashback instance' do
        before do
          allow(character_instance).to receive(:flashback_instanced?).and_return(false)
        end

        it 'returns error' do
          result = command.execute('journey return')

          expect(result[:success]).to be false
          expect(result[:message]).to include("not in a flashback instance")
        end
      end

      context 'when in flashback instance' do
        before do
          allow(character_instance).to receive(:flashback_instanced?).and_return(true)
          allow(character_instance).to receive(:flashback_travel_mode).and_return('return')
          allow(character_instance).to receive(:flashback_origin_room).and_return(room)
          allow(character_instance).to receive(:flashback_time_reserved).and_return(3600)
          allow(character_instance).to receive(:flashback_return_debt).and_return(0)

          allow(FlashbackTravelService).to receive(:end_flashback_instance).and_return({
            success: true,
            message: 'You return to your origin.',
            instant: true
          })
          allow(FlashbackTimeService).to receive(:format_time).and_return('1 hour')
        end

        it 'ends flashback instance' do
          result = command.execute('journey return')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:flashback_return)
        end

        it 'calls FlashbackTravelService' do
          command.execute('journey return')

          expect(FlashbackTravelService).to have_received(:end_flashback_instance)
            .with(character_instance)
        end
      end

      context 'when flashback return fails' do
        before do
          allow(character_instance).to receive(:flashback_instanced?).and_return(true)
          allow(character_instance).to receive(:flashback_travel_mode).and_return('return')
          allow(character_instance).to receive(:flashback_origin_room).and_return(room)
          allow(character_instance).to receive(:flashback_time_reserved).and_return(3600)
          allow(character_instance).to receive(:flashback_return_debt).and_return(0)

          allow(FlashbackTravelService).to receive(:end_flashback_instance).and_return({
            success: false,
            error: 'Origin room no longer exists'
          })
        end

        it 'returns error' do
          result = command.execute('journey return')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Origin room no longer exists')
        end
      end
    end

    context 'with "disembark" argument' do
      context 'when not traveling' do
        before do
          allow(character_instance).to receive(:traveling?).and_return(false)
        end

        it 'returns error' do
          result = command.execute('journey disembark')

          expect(result[:success]).to be false
          expect(result[:message]).to include("not currently on a journey")
        end
      end

      context 'when traveling' do
        let(:journey) do
          j = double('WorldJourney',
                     destination_location: destination_location,
                     vehicle_type: 'train',
                     passengers: [character_instance])
          j
        end
        let(:wilderness_room) { create(:room, location: location, name: 'Wilderness') }

        before do
          allow(character_instance).to receive(:traveling?).and_return(true)
          allow(character_instance).to receive(:current_world_journey).and_return(journey)
          allow(WorldTravelService).to receive(:disembark).and_return({
            success: true,
            message: 'You disembark from the train.',
            room: wilderness_room
          })
        end

        it 'disembarks successfully' do
          result = command.execute('journey disembark')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:world_travel)
          expect(result[:data][:action]).to eq('disembarked')
        end

        it 'calls WorldTravelService.disembark' do
          command.execute('journey disembark')

          expect(WorldTravelService).to have_received(:disembark).with(character_instance)
        end
      end

      context 'when disembark fails' do
        let(:journey) do
          double('WorldJourney',
                 destination_location: destination_location,
                 vehicle_type: 'train',
                 passengers: [])
        end

        before do
          allow(character_instance).to receive(:traveling?).and_return(true)
          allow(character_instance).to receive(:current_world_journey).and_return(journey)
          allow(WorldTravelService).to receive(:disembark).and_return({
            success: false,
            error: 'Cannot disembark in this area'
          })
        end

        it 'returns error' do
          result = command.execute('journey disembark')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Cannot disembark')
        end
      end
    end

    context 'with "invite <name>" argument' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user, name: 'Bob') }
      let(:other_instance) do
        create(:character_instance,
               character: other_character,
               reality: reality,
               current_room: room,
               online: true)
      end

      context 'when no active party' do
        before do
          allow(TravelParty).to receive(:where).and_return(double(first: nil))
        end

        it 'returns error' do
          result = command.execute('journey invite Bob')

          expect(result[:success]).to be false
          expect(result[:message]).to match(/don(&#39;|&#x27;)t have an active travel party/)
        end
      end

      context 'when party exists' do
        let(:party) do
          p = double('TravelParty', id: 1)
          allow(p).to receive(:member?).and_return(false)
          allow(p).to receive(:invite!).and_return({ success: true })
          p
        end

        before do
          allow(TravelParty).to receive(:where).and_return(double(first: party))
        end

        context 'when target not found' do
          before do
            allow(CharacterInstance).to receive(:join).and_return(
              double(join: double(where: double(where: double(where: double(exclude: double(select_all: double(first: nil)))))))
            )
          end

          it 'returns error' do
            result = command.execute('journey invite Nobody')

            expect(result[:success]).to be false
            expect(result[:message]).to include("Cannot find")
          end
        end

        context 'when inviting self' do
          before do
            allow(CharacterInstance).to receive(:join).and_return(
              double(join: double(where: double(where: double(where: double(exclude: double(select_all: double(first: character_instance)))))))
            )
          end

          it 'returns error' do
            # The exclude should prevent this, but testing the case
            result = command.execute('journey invite Self')

            expect(result[:success]).to be false
          end
        end

        context 'when target already in party' do
          before do
            allow(CharacterInstance).to receive(:join).and_return(
              double(join: double(where: double(where: double(where: double(exclude: double(select_all: double(first: other_instance)))))))
            )
            allow(party).to receive(:member?).with(other_instance).and_return(true)
            allow(other_instance).to receive(:character).and_return(other_character)
          end

          it 'returns error' do
            result = command.execute('journey invite Bob')

            expect(result[:success]).to be false
            expect(result[:message]).to include('already in the party')
          end
        end

        context 'when invite succeeds' do
          before do
            allow(CharacterInstance).to receive(:join).and_return(
              double(join: double(where: double(where: double(where: double(exclude: double(select_all: double(first: other_instance)))))))
            )
            allow(other_instance).to receive(:character).and_return(other_character)
          end

          it 'invites the character' do
            result = command.execute('journey invite Bob')

            expect(result[:success]).to be true
            expect(result[:message]).to include('Invited')
          end

          it 'calls party.invite!' do
            command.execute('journey invite Bob')

            expect(party).to have_received(:invite!).with(other_instance)
          end
        end
      end
    end

    context 'with "launch" argument' do
      context 'when no active party' do
        before do
          allow(TravelParty).to receive(:where).and_return(double(first: nil))
        end

        it 'returns error' do
          result = command.execute('journey launch')

          expect(result[:success]).to be false
          expect(result[:message]).to match(/don(&#39;|&#x27;)t have an active travel party/)
        end
      end

      context 'when party exists' do
        let(:party) do
          p = double('TravelParty',
                     id: 1,
                     destination: destination_location,
                     accepted_members: [character_instance])
          allow(p).to receive(:can_launch?).and_return(true)
          allow(p).to receive(:launch!).and_return({
            success: true,
            message: 'Party departed!'
          })
          p
        end

        before do
          allow(TravelParty).to receive(:where).and_return(double(first: party))
          allow(character_instance).to receive(:character).and_return(character)
        end

        context 'when cannot launch' do
          before do
            allow(party).to receive(:can_launch?).and_return(false)
          end

          it 'returns error' do
            result = command.execute('journey launch')

            expect(result[:success]).to be false
            expect(result[:message]).to include('Cannot launch')
          end
        end

        context 'when launch succeeds' do
          it 'launches the party' do
            result = command.execute('journey launch')

            expect(result[:success]).to be true
            expect(result[:message]).to include('departed')
          end

          it 'broadcasts departure' do
            command.execute('journey launch')

            expect(BroadcastService).to have_received(:to_room)
          end
        end

        context 'when launch fails' do
          before do
            allow(party).to receive(:launch!).and_return({
              success: false,
              error: 'Transport unavailable'
            })
          end

          it 'returns error' do
            result = command.execute('journey launch')

            expect(result[:success]).to be false
            expect(result[:message]).to include('Transport unavailable')
          end
        end
      end
    end

    context 'with "cancel" argument' do
      context 'when no active party' do
        before do
          allow(TravelParty).to receive(:where).and_return(double(first: nil))
        end

        it 'returns error' do
          result = command.execute('journey cancel')

          expect(result[:success]).to be false
          expect(result[:message]).to match(/don(&#39;|&#x27;)t have an active travel party/)
        end
      end

      context 'when party exists' do
        let(:party) do
          p = double('TravelParty', id: 1)
          allow(p).to receive(:cancel!)
          p
        end

        before do
          allow(TravelParty).to receive(:where).and_return(double(first: party))
        end

        it 'cancels the party' do
          result = command.execute('journey cancel')

          expect(result[:success]).to be true
          expect(result[:message]).to include('cancelled')
        end

        it 'calls party.cancel!' do
          command.execute('journey cancel')

          expect(party).to have_received(:cancel!)
        end
      end
    end

    context 'with unknown text (treated as destination)' do
      before do
        allow(character_instance).to receive(:traveling?).and_return(false)

        location_dataset = double('Dataset')
        allow(Location).to receive(:where).with(world_id: world.id).and_return(location_dataset)
        allow(location_dataset).to receive(:where).with(Sequel.ilike(:city_name, 'SomeCity')).and_return(
          double(first: destination_location)
        )

        allow(JourneyService).to receive(:travel_options).and_return({
          success: true,
          destination: { id: destination_location.id, name: 'SomeCity' },
          origin: { id: location.id, name: 'Starting City' },
          journey_time_display: '4 hours',
          flashback: { available: 0, basic: { success: false }, return: { success: false }, backloaded: { success: false } },
          available_modes: ['train']
        })
      end

      it 'treats text as destination' do
        result = command.execute('journey SomeCity')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end
    end
  end

  describe 'flashback travel modes' do
    before do
      allow(character_instance).to receive(:traveling?).and_return(false)

      location_dataset = double('Dataset')
      allow(Location).to receive(:where).with(world_id: world.id).and_return(location_dataset)
      allow(location_dataset).to receive(:where).with(Sequel.ilike(:city_name, 'Ravencroft')).and_return(
        double(first: destination_location)
      )

      allow(FlashbackTimeService).to receive(:format_time).and_return('1 hour')
    end

    context 'when flashback basic is available with instant' do
      before do
        allow(JourneyService).to receive(:travel_options).and_return({
          success: true,
          destination: { id: destination_location.id, name: 'Ravencroft' },
          origin: { id: location.id, name: 'Starting City' },
          journey_time_display: '4 hours',
          flashback: {
            available: 3600,
            basic: { success: true, can_instant: true, flashback_used: 3600 },
            return: { success: false },
            backloaded: { success: false }
          },
          available_modes: ['train']
        })
      end

      it 'includes flashback instant option' do
        result = command.execute('journey to Ravencroft')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        options = result[:data][:options]
        expect(options.any? { |i| i[:key] == 'flashback_basic' }).to be true
      end
    end

    context 'when flashback return is available' do
      before do
        allow(JourneyService).to receive(:travel_options).and_return({
          success: true,
          destination: { id: destination_location.id, name: 'Ravencroft' },
          origin: { id: location.id, name: 'Starting City' },
          journey_time_display: '4 hours',
          flashback: {
            available: 7200,
            basic: { success: false },
            return: { success: true, can_instant: true, reserved_for_return: 3600 },
            backloaded: { success: false }
          },
          available_modes: ['train']
        })
      end

      it 'includes flashback return option' do
        result = command.execute('journey to Ravencroft')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        options = result[:data][:options]
        expect(options.any? { |i| i[:key] == 'flashback_return' }).to be true
      end
    end

    context 'when backloaded flashback is available' do
      before do
        allow(JourneyService).to receive(:travel_options).and_return({
          success: true,
          destination: { id: destination_location.id, name: 'Ravencroft' },
          origin: { id: location.id, name: 'Starting City' },
          journey_time_display: '4 hours',
          flashback: {
            available: 1800,
            basic: { success: false },
            return: { success: false },
            backloaded: { success: true, return_debt: 7200 }
          },
          available_modes: ['train']
        })
      end

      it 'includes backloaded option' do
        result = command.execute('journey to Ravencroft')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        options = result[:data][:options]
        expect(options.any? { |i| i[:key] == 'flashback_backloaded' }).to be true
      end
    end
  end

  describe 'passengers display' do
    let(:other_user) { create(:user) }
    let(:other_character) { create(:character, user: other_user, name: 'Bob') }
    let(:other_instance) do
      create(:character_instance,
             character: other_character,
             reality: reality,
             current_room: room,
             online: true)
    end

    let(:journey) do
      j = double('WorldJourney',
                 destination_location: destination_location,
                 vehicle_type: 'train',
                 passengers: [character_instance, other_instance],
                 driver: character_instance,
                 time_remaining_display: '2 hours')
      j
    end

    before do
      allow(character_instance).to receive(:traveling?).and_return(true)
      allow(character_instance).to receive(:current_world_journey).and_return(journey)
      allow(character_instance).to receive(:full_name).and_return(character.full_name)
      allow(other_instance).to receive(:full_name).and_return(other_character.full_name)
    end

    it 'shows all passengers' do
      result = command.execute('journey party')

      expect(result[:success]).to be true
      expect(result[:data][:passenger_count]).to eq(2)
    end

    it 'identifies driver' do
      result = command.execute('journey party')

      passengers = result[:data][:passengers]
      driver_entry = passengers.find { |p| p[:is_driver] }
      expect(driver_entry).not_to be_nil
      expect(driver_entry[:id]).to eq(character_instance.id)
    end
  end

  describe 'error handling' do
    context 'when journey not found during disembark' do
      before do
        allow(character_instance).to receive(:traveling?).and_return(true)
        allow(character_instance).to receive(:current_world_journey).and_return(nil)
      end

      it 'returns error' do
        result = command.execute('journey disembark')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Journey data not found')
      end
    end

    context 'when disembark notification fails' do
      let(:journey) do
        j = double('WorldJourney',
                   destination_location: destination_location,
                   vehicle_type: 'train',
                   passengers: [character_instance])
        allow(j).to receive(:passengers).and_raise(StandardError, 'DB error')
        j
      end
      let(:wilderness_room) { create(:room, location: location) }

      before do
        allow(character_instance).to receive(:traveling?).and_return(true)
        allow(character_instance).to receive(:current_world_journey).and_return(journey)
        allow(WorldTravelService).to receive(:disembark).and_return({
          success: true,
          message: 'Disembarked',
          room: wilderness_room
        })
      end

      it 'still succeeds' do
        # The error is caught and logged, but disembark still succeeds
        result = command.execute('journey disembark')

        expect(result[:success]).to be true
      end
    end
  end
end
