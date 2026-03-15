# frozen_string_literal: true

# Helpers for testing routes with authentication
module RouteTestHelpers
  # Generate auth headers for API routes
  def auth_headers(user = nil)
    user ||= create(:user)
    token = user.generate_api_token!
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
  end

  # Generate auth headers for admin routes
  def admin_auth_headers
    admin = create(:user, :admin)
    auth_headers(admin)
  end

  # Log in a user for session-based routes
  def login_as(user)
    env 'rack.session', { 'user_id' => user.id }
  end

  # Helper to check JSON response
  def json_response
    JSON.parse(last_response.body)
  end

  # Helper to check for redirect
  def expect_redirect_to(path)
    expect(last_response).to be_redirect
    expect(last_response.location).to include(path)
  end

  # Helper to check successful page load
  def expect_success
    expect(last_response).to be_ok
  end

  # Helper to check 401 unauthorized
  def expect_unauthorized
    expect(last_response.status).to eq(401)
  end

  # Helper to check 403 forbidden
  def expect_forbidden
    expect(last_response.status).to eq(403)
  end
end

RSpec.configure do |config|
  config.include RouteTestHelpers, type: :request
  config.include RouteTestHelpers, type: :controller
end
