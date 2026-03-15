# frozen_string_literal: true

require 'sendgrid-ruby'

# Service for sending emails via SendGrid
#
# Uses GameSetting for configuration:
# - sendgrid_api_key: SendGrid API key
# - email_from_address: From email address
# - email_from_name: From display name
#
# @example Send verification email
#   EmailService.send_verification_email(user)
#
# @example Send generic email
#   EmailService.send_email(
#     to: 'user@example.com',
#     subject: 'Hello',
#     body: 'Welcome to the game!'
#   )
#
class EmailService
  class << self
    # Send password reset link to user
    #
    # @param user [User] The user requesting password reset
    # @return [Boolean] true if sent successfully, false otherwise
    def send_password_reset(user)
      return false unless configured?

      token = user.generate_password_reset_token!
      reset_url = build_password_reset_url(token)

      subject = GameSetting.get('email_password_reset_subject') || 'Reset your password'
      game_name = GameSetting.get('game_name') || 'Firefly'

      body = <<~HTML
        <html>
          <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <h1 style="color: #333;">Password Reset Request</h1>
            <p>We received a request to reset your password for #{game_name}.</p>
            <p style="text-align: center; margin: 30px 0;">
              <a href="#{reset_url}"
                 style="background-color: #2196F3; color: white; padding: 15px 30px; text-decoration: none; border-radius: 5px; font-size: 16px;">
                Reset Password
              </a>
            </p>
            <p style="color: #666; font-size: 14px;">
              Or copy and paste this link into your browser:<br>
              <a href="#{reset_url}">#{reset_url}</a>
            </p>
            <p style="color: #999; font-size: 12px; margin-top: 30px;">
              This link will expire in 1 hour. If you didn't request a password reset, you can ignore this email.
            </p>
          </body>
        </html>
      HTML

      send_email(to: user.email, subject: subject, body: body, html: true)
    end

    # Send email verification link to user
    #
    # @param user [User] The user to send verification to
    # @return [Boolean] true if sent successfully, false otherwise
    def send_verification_email(user)
      return false unless configured?

      token = user.generate_confirmation_token!
      verification_url = build_verification_url(token)

      subject = GameSetting.get('email_verification_subject') || 'Verify your email address'
      game_name = GameSetting.get('game_name') || 'Firefly'

      body = <<~HTML
        <html>
          <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <h1 style="color: #333;">Welcome to #{game_name}!</h1>
            <p>Please click the button below to verify your email address:</p>
            <p style="text-align: center; margin: 30px 0;">
              <a href="#{verification_url}"
                 style="background-color: #4CAF50; color: white; padding: 15px 30px; text-decoration: none; border-radius: 5px; font-size: 16px;">
                Verify Email Address
              </a>
            </p>
            <p style="color: #666; font-size: 14px;">
              Or copy and paste this link into your browser:<br>
              <a href="#{verification_url}">#{verification_url}</a>
            </p>
            <p style="color: #999; font-size: 12px; margin-top: 30px;">
              This link will expire in 24 hours. If you didn't create an account, you can ignore this email.
            </p>
          </body>
        </html>
      HTML

      send_email(to: user.email, subject: subject, body: body, html: true)
    end

    # Send a generic email
    #
    # @param to [String] Recipient email address
    # @param subject [String] Email subject
    # @param body [String] Email body (text or HTML)
    # @param html [Boolean] Whether body is HTML (default: false)
    # @return [Boolean] true if sent successfully, false otherwise
    def send_email(to:, subject:, body:, html: false)
      return false unless configured?

      api_key = GameSetting.get('sendgrid_api_key')
      from_address = GameSetting.get('email_from_address')
      from_name = GameSetting.get('email_from_name') || GameSetting.get('game_name') || 'Firefly'

      sg = SendGrid::API.new(api_key: api_key)

      from = SendGrid::Email.new(email: from_address, name: from_name)
      to_email = SendGrid::Email.new(email: to)

      content = if html
                  SendGrid::Content.new(type: 'text/html', value: body)
                else
                  SendGrid::Content.new(type: 'text/plain', value: body)
                end

      mail = SendGrid::Mail.new(from, subject, to_email, content)

      response = sg.client.mail._('send').post(request_body: mail.to_json)

      # 2xx status codes indicate success
      response.status_code.to_i >= 200 && response.status_code.to_i < 300
    rescue StandardError => e
      warn "[EmailService] Error sending email: #{e.message}"
      false
    end

    # Check if email service is properly configured
    #
    # @return [Boolean] true if API key and from address are set
    def configured?
      api_key = GameSetting.get('sendgrid_api_key')
      from_address = GameSetting.get('email_from_address')

      !api_key.to_s.strip.empty? && !from_address.to_s.strip.empty?
    end

    # Send a test email to verify configuration
    #
    # @param to [String] Recipient email for test
    # @return [Boolean] true if sent successfully
    def send_test_email(to)
      game_name = GameSetting.get('game_name') || 'Firefly'

      send_email(
        to: to,
        subject: "Test Email from #{game_name}",
        body: <<~HTML,
          <html>
            <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
              <h1 style="color: #4CAF50;">Email Configuration Test</h1>
              <p>This is a test email from #{game_name}.</p>
              <p>If you received this email, your SendGrid configuration is working correctly!</p>
              <p style="color: #666; font-size: 14px; margin-top: 30px;">
                Sent at: #{Time.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}
              </p>
            </body>
          </html>
        HTML
        html: true
      )
    end

    private

    # Build the full verification URL
    #
    # @param token [String] The confirmation token
    # @return [String] Full URL for email verification
    def build_verification_url(token)
      # Get base URL from environment or default
      base_url = ENV['APP_BASE_URL'] || 'http://localhost:3000'
      "#{base_url}/verify-email/#{token}"
    end

    # Build the full password reset URL
    #
    # @param token [String] The password reset token
    # @return [String] Full URL for password reset
    def build_password_reset_url(token)
      # Get base URL from environment or default
      base_url = ENV['APP_BASE_URL'] || 'http://localhost:3000'
      "#{base_url}/reset-password/#{token}"
    end
  end
end
