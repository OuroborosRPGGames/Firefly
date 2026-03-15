# frozen_string_literal: true

require 'spec_helper'

# Template Link Audit
#
# Scans all ERB templates for internal href links and verifies each one
# resolves to a real route (not a 404). This catches dead links in navigation,
# footers, and page content that would otherwise go unnoticed.
#
# Only checks static paths (no ERB interpolation). Dynamic paths like
# href="/admin/users/<%= user.id %>" are skipped since they need runtime data.

RSpec.describe 'Template Link Audit', type: :request do
  # Extract all static internal href values from ERB templates
  def self.extract_template_links
    template_dir = File.expand_path('../../app/views', __dir__)
    links = {}

    Dir.glob(File.join(template_dir, '**', '*.erb')).each do |file|
      content = File.read(file)
      relative = file.sub("#{template_dir}/", '')

      # Match href="..." but skip:
      # - External URLs (http://, https://, //)
      # - Anchors (#)
      # - JavaScript (javascript:)
      # - Paths with ERB interpolation (<%= %>)
      # - Empty hrefs
      content.scan(/href="([^"]*)"/).flatten.each do |href|
        next if href.empty?
        next if href.start_with?('http://', 'https://', '//', '#', 'javascript:', 'mailto:')
        next if href.include?('<%')
        next if href.include?('${')
        next if href == '/'

        # Strip query strings and anchors for route checking
        path = href.split('?').first.split('#').first

        # Skip API routes (tested separately) and websocket paths
        next if path.start_with?('/api/', '/cable')

        links[path] ||= []
        links[path] << relative
      end
    end

    links
  end

  TEMPLATE_LINKS = extract_template_links

  # Public routes - no auth needed, expect 200
  PUBLIC_PATHS = %w[
    /info /info/rules /info/getting-started /info/commands
    /info/helps /info/systems /info/terms /info/privacy /info/contact
    /world /world/lore /world/locations /world/factions
    /profiles /news /register /login
  ].freeze

  # Protected routes - redirect to login (302) when not authenticated
  PROTECTED_PATH_PREFIXES = %w[
    /dashboard /settings /characters /play /webclient /popout /admin /events /logs
  ].freeze

  def path_is_protected?(path)
    PROTECTED_PATH_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
  end

  describe 'all template links resolve to valid routes' do
    TEMPLATE_LINKS.each do |path, templates|
      it "#{path} is a valid route (linked from #{templates.first}#{templates.size > 1 ? " +#{templates.size - 1} more" : ''})" do
        get path

        status = last_response.status

        if path_is_protected?(path)
          # Protected routes should redirect to login, not 404
          expect(status).not_to eq(404),
            "#{path} returned 404 (dead link). Linked from: #{templates.join(', ')}"
          expect([200, 302, 303]).to include(status),
            "#{path} returned #{status} (expected 200 or redirect). Linked from: #{templates.join(', ')}"
        else
          expect(status).not_to eq(404),
            "#{path} returned 404 (dead link). Linked from: #{templates.join(', ')}"
          expect([200, 301, 302]).to include(status),
            "#{path} returned #{status} (expected 200 or redirect). Linked from: #{templates.join(', ')}"
        end
      end
    end
  end

  it 'found links to audit' do
    expect(TEMPLATE_LINKS).not_to be_empty,
      'No template links found - check that ERB templates exist in app/views/'
  end
end
