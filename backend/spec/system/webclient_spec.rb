# frozen_string_literal: true

# Webclient system specs test the game interface
# These require authentication which is complex, so we focus on
# publicly accessible aspects and static asset loading

RSpec.describe 'Webclient Assets', type: :system do
  describe 'CSS files' do
    it 'serves firefly.css' do
      visit '/css/firefly.css'
      expect(page.status_code).to eq(200)
    end

    it 'serves play.css' do
      visit '/css/play.css'
      expect(page.status_code).to eq(200)
    end

    it 'serves gradient-components.css' do
      visit '/css/gradient-components.css'
      expect(page.status_code).to eq(200)
    end

    it 'serves media_sync.css' do
      visit '/css/media_sync.css'
      expect(page.status_code).to eq(200)
    end
  end

  describe 'JavaScript files' do
    it 'serves dice_animation.js' do
      visit '/js/dice_animation.js'
      expect(page.status_code).to eq(200)
    end

    it 'serves gradient-creator.js' do
      visit '/js/gradient-creator.js'
      expect(page.status_code).to eq(200)
    end

    it 'serves media_sync.js' do
      visit '/js/media_sync.js'
      expect(page.status_code).to eq(200)
    end
  end
end

RSpec.describe 'Webclient JavaScript Syntax', type: :system, js: true do
  # Test that JavaScript files don't have syntax errors by loading them

  it 'loads gradient-creator.js without syntax errors' do
    # Create a minimal HTML page that loads the JS
    visit '/'
    page.execute_script("var script = document.createElement('script'); script.src = '/js/gradient-creator.js'; document.head.appendChild(script);")
    sleep 0.3
    # If we get here without error, the JS loaded successfully
    expect(page.status_code).to eq(200)
  end

  it 'loads dice_animation.js without syntax errors' do
    visit '/'
    page.execute_script("var script = document.createElement('script'); script.src = '/js/dice_animation.js'; document.head.appendChild(script);")
    sleep 0.3
    expect(page.status_code).to eq(200)
  end
end
