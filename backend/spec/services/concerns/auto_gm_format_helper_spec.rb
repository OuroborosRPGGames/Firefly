# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoGm::AutoGmFormatHelper do
  # Create a test class that extends the module
  let(:formatter) do
    Class.new { extend AutoGm::AutoGmFormatHelper }
  end

  describe '#format_list' do
    it 'returns "none" for nil' do
      expect(formatter.format_list(nil)).to eq('none')
    end

    it 'returns "none" for empty array' do
      expect(formatter.format_list([])).to eq('none')
    end

    it 'joins string items with commas' do
      expect(formatter.format_list(%w[sword shield potion])).to eq('sword, shield, potion')
    end

    it 'extracts name from hashes with string keys' do
      items = [{ 'name' => 'Dragon' }, { 'name' => 'Goblin' }]
      expect(formatter.format_list(items)).to eq('Dragon, Goblin')
    end

    it 'extracts name from hashes with symbol keys' do
      items = [{ name: 'Dragon' }, { name: 'Goblin' }]
      expect(formatter.format_list(items)).to eq('Dragon, Goblin')
    end

    it 'converts non-string items to strings' do
      expect(formatter.format_list([1, 2, 3])).to eq('1, 2, 3')
    end
  end

  describe '#format_gm_message' do
    it 'returns a hash with content, html, and type' do
      result = formatter.format_gm_message('The room grows dark.')
      expect(result).to have_key(:content)
      expect(result).to have_key(:html)
      expect(result).to have_key(:type)
    end

    it 'sets type to auto_gm_narration' do
      result = formatter.format_gm_message('Test')
      expect(result[:type]).to eq('auto_gm_narration')
    end

    it 'wraps content in em tags' do
      result = formatter.format_gm_message('Narration text')
      expect(result[:html]).to include('<em>')
      expect(result[:html]).to include('</em>')
    end

    it 'wraps html in narration div' do
      result = formatter.format_gm_message('Test')
      expect(result[:html]).to include("class='auto-gm-narration'")
    end

    it 'escapes HTML in text' do
      result = formatter.format_gm_message('<script>alert("xss")</script>')
      expect(result[:html]).not_to include('<script>')
      expect(result[:html]).to include('&lt;script&gt;')
    end

    it 'converts markdown bold to strong tags in html' do
      result = formatter.format_gm_message('The dragon **roars** loudly.')
      expect(result[:html]).to include('<strong>roars</strong>')
      expect(result[:html]).not_to include('**')
    end

    it 'converts markdown italic to em tags in html' do
      result = formatter.format_gm_message('A *gentle* breeze blows.')
      expect(result[:html]).to include('<em>gentle</em>')
      expect(result[:html]).not_to include('*gentle*')
    end

    it 'strips markdown from plain text content' do
      result = formatter.format_gm_message('The **bold** and *italic* text.')
      expect(result[:content]).to eq('The bold and italic text.')
    end

    it 'handles mixed bold and italic markdown' do
      result = formatter.format_gm_message('The **dark** tower *shimmers* in light.')
      expect(result[:html]).to include('<strong>dark</strong>')
      expect(result[:html]).to include('<em>shimmers</em>')
    end
  end

  describe '#format_event_message' do
    it 'sets type to auto_gm_random_event' do
      result = formatter.format_event_message('Something happens!')
      expect(result[:type]).to eq('auto_gm_random_event')
    end

    it 'includes Random Event prefix' do
      result = formatter.format_event_message('A crash echoes.')
      expect(result[:content]).to include('Random Event:')
    end

    it 'converts markdown in event text' do
      result = formatter.format_event_message('A *mysterious* stranger appears.')
      expect(result[:html]).to include('<em>mysterious</em>')
      expect(result[:html]).not_to include('*mysterious*')
    end

    it 'wraps html in event div' do
      result = formatter.format_event_message('Test')
      expect(result[:html]).to include("class='auto-gm-event'")
    end
  end

  describe '#format_revelation_message' do
    it 'sets type to auto_gm_revelation' do
      result = formatter.format_revelation_message('A hidden passage!')
      expect(result[:type]).to eq('auto_gm_revelation')
    end

    it 'includes Secret Revealed prefix in content' do
      result = formatter.format_revelation_message('The villain is the butler.')
      expect(result[:content]).to include('Secret Revealed:')
    end

    it 'wraps html in revelation div' do
      result = formatter.format_revelation_message('Test')
      expect(result[:html]).to include("class='auto-gm-revelation'")
    end

    it 'strips HTML tags from the secret text' do
      result = formatter.format_revelation_message('<b>bold</b>')
      expect(result[:html]).not_to include('<b>')
      expect(result[:html]).to include('bold')
    end
  end

  describe '#format_twist_message' do
    it 'sets type to auto_gm_twist' do
      result = formatter.format_twist_message('The allies betray you!')
      expect(result[:type]).to eq('auto_gm_twist')
    end

    it 'includes TWIST! prefix in content' do
      result = formatter.format_twist_message('Everything changes.')
      expect(result[:content]).to include('TWIST!')
    end

    it 'wraps html in twist div' do
      result = formatter.format_twist_message('Test')
      expect(result[:html]).to include("class='auto-gm-twist'")
    end
  end

  describe '#format_stage_message' do
    it 'sets type to auto_gm_stage_transition' do
      result = formatter.format_stage_message('name' => 'Act 2', 'description' => 'The journey begins')
      expect(result[:type]).to eq('auto_gm_stage_transition')
    end

    it 'includes stage name as atmospheric separator' do
      result = formatter.format_stage_message('name' => 'Climax', 'description' => 'Final battle')
      expect(result[:content]).to include('Climax')
      expect(result[:content]).to include('—')
    end

    it 'does not expose stage description to players' do
      result = formatter.format_stage_message('name' => 'Act 1', 'description' => 'Setup')
      expect(result[:content]).not_to include('Setup')
    end

    it 'works with symbol keys' do
      result = formatter.format_stage_message(name: 'Finale', description: 'The end')
      expect(result[:content]).to include('Finale')
    end

    it 'wraps html in stage div' do
      result = formatter.format_stage_message('name' => 'Test', 'description' => 'Desc')
      expect(result[:html]).to include("class='auto-gm-stage'")
    end

    it 'escapes HTML in name and description' do
      result = formatter.format_stage_message('name' => '<script>', 'description' => '<img onerror=x>')
      expect(result[:html]).not_to include('<script>')
      expect(result[:html]).to include('&lt;script&gt;')
    end
  end
end
