# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Info::Meetup, type: :command do
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
  let(:other_character) { create(:character, forename: 'Bob') }
  let(:third_character) { create(:character, forename: 'Carol') }

  subject(:command) { described_class.new(character_instance) }

  it_behaves_like "command metadata", 'meetup', :info, %w[schedule findtime]

  describe '#execute' do
    context 'with no arguments' do
      it 'returns error asking for characters' do
        result = command.execute('meetup')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Who should be included?')
      end
    end

    context 'with "me" argument' do
      context 'with insufficient activity data' do
        let(:profile) { double('ActivityProfile', has_sufficient_data?: false, total_samples: 5) }

        before do
          allow(ActivityProfile).to receive(:for_character).with(character).and_return(profile)
        end

        it 'shows message about needing more data' do
          result = command.execute('meetup me')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Not enough activity data')
          expect(result[:message]).to include('20 samples')
          expect(result[:message]).to include('you have 5')
        end
      end

      context 'with sufficient activity data' do
        let(:profile) do
          double('ActivityProfile',
                 has_sufficient_data?: true,
                 share_schedule: true)
        end

        before do
          allow(ActivityProfile).to receive(:for_character).with(character).and_return(profile)
          allow(profile).to receive(:peak_times).with(limit: 5, threshold: 20).and_return([
                                                                                            { day: 'sat', hour: 20, score: 80 },
                                                                                            { day: 'sun', hour: 14, score: 60 }
                                                                                          ])
          allow(profile).to receive(:weekly_schedule).with(threshold: 20).and_return({
                                                                                       'sat' => [19, 20, 21],
                                                                                       'sun' => [13, 14, 15]
                                                                                     })
          allow(ActivityTrackingService).to receive(:full_day_name).with('sat').and_return('Saturday')
          allow(ActivityTrackingService).to receive(:full_day_name).with('sun').and_return('Sunday')
          allow(ActivityTrackingService).to receive(:format_hour) { |h| "#{h}:00" }
          allow(ActivityTrackingService).to receive(:format_hour_range).with([19, 20, 21]).and_return('7pm-10pm')
          allow(ActivityTrackingService).to receive(:format_hour_range).with([13, 14, 15]).and_return('1pm-4pm')
        end

        it 'shows activity schedule' do
          result = command.execute('meetup me')

          expect(result[:success]).to be true
          expect(result[:message]).to include('<h3>Your Activity Schedule</h3>')
        end

        it 'shows peak times' do
          result = command.execute('meetup me')

          expect(result[:message]).to include('Peak Activity Times:')
          expect(result[:message]).to include('Saturday')
          expect(result[:message]).to include('80%')
        end

        it 'shows weekly pattern' do
          result = command.execute('meetup me')

          expect(result[:message]).to include('Typical Weekly Pattern:')
          expect(result[:message]).to include('Saturday:')
          expect(result[:message]).to include('Sunday:')
        end

        it 'shows schedule sharing status when on' do
          result = command.execute('meetup me')

          expect(result[:message]).to include('Schedule sharing: ON')
        end

        it 'shows schedule sharing status when off' do
          allow(profile).to receive(:share_schedule).and_return(false)

          result = command.execute('meetup me')

          expect(result[:message]).to include('Schedule sharing: OFF')
        end

        it 'includes action in data' do
          result = command.execute('meetup me')

          expect(result[:data][:action]).to eq('meetup')
          expect(result[:data][:mode]).to eq('self')
        end
      end
    end

    context 'with single character name' do
      it 'returns error about needing at least 2 characters' do
        result = command.execute('meetup Alice')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Need at least 2 characters')
      end
    end

    context 'with multiple character names' do
      before do
        # Stub character finding
        allow(command).to receive(:find_character_by_name).with('Alice').and_return(character)
        allow(command).to receive(:find_character_by_name).with('Bob').and_return(other_character)
        allow(command).to receive(:find_character_by_name).with('Carol').and_return(third_character)
      end

      context 'when all characters found' do
        before do
          allow(character).to receive(:full_name).and_return('Alice Smith')
          allow(other_character).to receive(:full_name).and_return('Bob Jones')
          allow(third_character).to receive(:full_name).and_return('Carol White')
        end

        it 'returns error when service returns error' do
          allow(ActivityTrackingService).to receive(:find_meeting_times)
            .and_return({ error: 'Not enough data for some characters' })

          result = command.execute('meetup Alice Bob')

          expect(result[:success]).to be false
          expect(result[:error]).to include('Not enough data')
        end

        it 'shows no common availability when times empty' do
          allow(ActivityTrackingService).to receive(:find_meeting_times)
            .and_return({ times: [], summary: nil })

          result = command.execute('meetup Alice Bob')

          expect(result[:success]).to be true
          expect(result[:message]).to include('No common availability found')
          expect(result[:message]).to include("meetup me")
        end

        it 'shows meeting times when available' do
          allow(ActivityTrackingService).to receive(:find_meeting_times)
            .and_return({
                          times: [
                            { day: 'sat', hour: 20, attendees: [character, other_character], attendee_count: 2 },
                            { day: 'sun', hour: 14, attendees: [character, other_character], attendee_count: 2 }
                          ],
                          summary: 'Best overlap is Saturday evening'
                        })
          allow(ActivityTrackingService).to receive(:full_day_name).with('sat').and_return('Saturday')
          allow(ActivityTrackingService).to receive(:full_day_name).with('sun').and_return('Sunday')
          allow(ActivityTrackingService).to receive(:format_hour) { |h| "#{h}:00" }

          result = command.execute('meetup Alice Bob')

          expect(result[:success]).to be true
          expect(result[:message]).to include('<h3>Best Meeting Times</h3>')
          expect(result[:message]).to include('Characters: Alice Smith, Bob Jones')
          expect(result[:message]).to include('Saturday at 20:00')
          expect(result[:message]).to include('Sunday at 14:00')
          expect(result[:message]).to include('2/2')
          expect(result[:message]).to include('Best overlap is Saturday evening')
        end

        it 'shows partial availability' do
          allow(ActivityTrackingService).to receive(:find_meeting_times)
            .and_return({
                          times: [
                            { day: 'sat', hour: 20, attendees: [character], attendee_count: 1 }
                          ],
                          summary: nil
                        })
          allow(ActivityTrackingService).to receive(:full_day_name).with('sat').and_return('Saturday')
          allow(ActivityTrackingService).to receive(:format_hour).with(20).and_return('20:00')

          result = command.execute('meetup Alice Bob')

          expect(result[:message]).to include('1/2')
        end

        it 'includes data in response' do
          allow(ActivityTrackingService).to receive(:find_meeting_times)
            .and_return({ times: [], summary: nil })

          result = command.execute('meetup Alice Bob')

          expect(result[:data][:action]).to eq('meetup')
          expect(result[:data][:mode]).to eq('group')
          expect(result[:data][:characters]).to include('Alice Smith', 'Bob Jones')
        end
      end

      context 'when some characters not found' do
        before do
          allow(command).to receive(:find_character_by_name).with('NotExist').and_return(nil)
        end

        it 'returns error listing not found characters' do
          result = command.execute('meetup Alice NotExist')

          expect(result[:success]).to be false
          expect(result[:error]).to include('Could not find')
          expect(result[:error]).to include('NotExist')
        end

        it 'lists multiple not found characters' do
          allow(command).to receive(:find_character_by_name).with('Also').and_return(nil)

          result = command.execute('meetup Alice NotExist Also')

          expect(result[:error]).to include('NotExist')
          expect(result[:error]).to include('Also')
        end
      end
    end
  end

  describe '#find_character_by_name' do
    it 'finds character by forename' do
      found = command.send(:find_character_by_name, 'Alice')

      expect(found).to eq(character)
    end

    it 'finds character by surname' do
      character.update(surname: 'Johnson')

      found = command.send(:find_character_by_name, 'Johnson')

      expect(found.id).to eq(character.id)
    end

    it 'finds character by partial name' do
      found = command.send(:find_character_by_name, 'Ali')

      expect(found).to eq(character)
    end

    it 'is case insensitive' do
      found = command.send(:find_character_by_name, 'ALICE')

      expect(found).to eq(character)
    end

    it 'returns nil for non-existent character' do
      found = command.send(:find_character_by_name, 'NotExist')

      expect(found).to be_nil
    end
  end
end
