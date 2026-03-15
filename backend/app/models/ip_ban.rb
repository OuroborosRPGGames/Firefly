# frozen_string_literal: true

require 'ipaddr'

# IpBan stores IP bans with support for single IPs and CIDR ranges
#
# Supports both temporary and permanent bans. Uses Ruby's IPAddr for
# CIDR matching, allowing bans like "192.168.1.0/24" to block an entire subnet.
#
# Examples:
#   IpBan.ban_ip!("192.168.1.100", reason: "Harassment")
#   IpBan.ban_ip!("10.0.0.0/8", reason: "VPN range", expires_at: Time.now + (7 * 24 * 3600))
#   IpBan.banned?("192.168.1.50")  # => true if in banned range
#
class IpBan < Sequel::Model
  plugin :timestamps

  many_to_one :created_by_user, class: :User, key: :created_by_user_id

  BAN_TYPES = %w[permanent temporary].freeze

  # Check if an IP address is banned
  #
  # @param ip_address [String]
  # @return [Boolean]
  def self.banned?(ip_address)
    return false if StringHelper.blank?(ip_address)

    active_bans.any? { |ban| ban.matches_ip?(ip_address) }
  end

  # Get all currently active bans
  #
  # @return [Array<IpBan>]
  def self.active_bans
    where(active: true)
      .where { (expires_at =~ nil) | (expires_at > Time.now) }
      .all
  end

  # Find the ban record that matches an IP (if any)
  #
  # @param ip_address [String]
  # @return [IpBan, nil]
  def self.find_matching_ban(ip_address)
    return nil if StringHelper.blank?(ip_address)

    active_bans.find { |ban| ban.matches_ip?(ip_address) }
  end

  # Create a new IP ban
  #
  # @param ip_pattern [String] Single IP or CIDR notation
  # @param reason [String, nil] Reason for the ban
  # @param expires_at [Time, nil] When the ban expires (nil = permanent)
  # @param created_by [User, nil] Staff member who created the ban
  # @return [IpBan]
  def self.ban_ip!(ip_pattern, reason: nil, expires_at: nil, created_by: nil)
    ban_type = expires_at.nil? ? 'permanent' : 'temporary'

    create(
      ip_pattern: ip_pattern.to_s.strip,
      ban_type: ban_type,
      expires_at: expires_at,
      reason: reason,
      created_by_user_id: created_by&.id,
      active: true
    )
  end

  # Check if this ban matches a given IP address
  #
  # @param ip_address [String]
  # @return [Boolean]
  def matches_ip?(ip_address)
    return false if StringHelper.blank?(ip_address)

    begin
      if ip_pattern.include?('/')
        # CIDR range matching
        range = IPAddr.new(ip_pattern)
        target = IPAddr.new(ip_address)
        range.include?(target)
      else
        # Exact IP match
        ip_pattern == ip_address.to_s.strip
      end
    rescue IPAddr::InvalidAddressError => e
      warn "[IpBan] Invalid IP address in match: #{e.message}"
      false
    end
  end

  # Check if this ban has expired
  #
  # @return [Boolean]
  def expired?
    !expires_at.nil? && expires_at < Time.now
  end

  # Check if this is a permanent ban
  #
  # @return [Boolean]
  def permanent?
    ban_type == 'permanent' || expires_at.nil?
  end

  # Deactivate this ban
  #
  # @return [self]
  def deactivate!
    update(active: false)
    self
  end

  # Validate the IP pattern
  def validate
    super
    errors.add(:ip_pattern, 'cannot be empty') if StringHelper.blank?(ip_pattern)

    # Validate IP pattern format
    begin
      IPAddr.new(ip_pattern) if StringHelper.present?(ip_pattern)
    rescue IPAddr::InvalidAddressError
      errors.add(:ip_pattern, 'is not a valid IP address or CIDR range')
    end
  end

  # Format for admin display
  #
  # @return [Hash]
  def to_admin_hash
    {
      id: id,
      ip_pattern: ip_pattern,
      ban_type: ban_type,
      reason: reason,
      expires_at: expires_at&.iso8601,
      active: active,
      permanent: permanent?,
      expired: expired?,
      created_by: created_by_user&.username,
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end
end
