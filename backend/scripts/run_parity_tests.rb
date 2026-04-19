#!/usr/bin/env ruby
# frozen_string_literal: true

# Parity test runner for Ruby CombatResolutionService vs Rust combat-core.
#
# This script:
#   1. Builds the Rust combat-rng and combat-server if needed
#   2. Starts combat-server in JSON mode
#   3. Runs the parity test suite
#   4. Stops combat-server on exit
#
# Rust is the production combat engine as of 2026-04-19 — this runner is the
# overnight safety net that re-verifies Ruby/Rust agreement across the full
# 30-50 seeds-per-scenario statistical matrix. Expect ~10 hours for the full
# spec/parity/ tree; pass a filter (-e, --example) to run a subset.
#
# Usage:
#   cd backend && bundle exec ruby scripts/run_parity_tests.rb [rspec args...]
#
# Examples:
#   bundle exec ruby scripts/run_parity_tests.rb
#   bundle exec ruby scripts/run_parity_tests.rb --format documentation
#   bundle exec ruby scripts/run_parity_tests.rb -e "1v1 melee"
#   nohup bundle exec ruby scripts/run_parity_tests.rb > /tmp/parity.log 2>&1 &    # overnight

CARGO = File.expand_path('~/.cargo/bin/cargo')
COMBAT_ENGINE_DIR = File.expand_path('../../combat-engine', __dir__)
COMBAT_SERVER = File.join(COMBAT_ENGINE_DIR, 'target/release/combat-server')
COMBAT_RNG_LIB = File.join(COMBAT_ENGINE_DIR, 'target/release/libcombat_rng.so')
SOCKET_PATH = ENV.fetch('COMBAT_ENGINE_SOCKET', '/tmp/combat-engine.sock')

server_pid = nil

at_exit do
  if server_pid
    Process.kill('TERM', server_pid) rescue nil
    Process.wait(server_pid) rescue nil
    File.delete(SOCKET_PATH) if File.exist?(SOCKET_PATH)
    puts "\nCombat-server stopped."
  end
end

# Step 1: Build Rust binaries if needed
puts "=" * 60
puts "Combat Engine Parity Test Runner"
puts "=" * 60
puts

unless File.exist?(COMBAT_RNG_LIB)
  puts "Building combat-rng..."
  system("#{CARGO} build --release -p combat-rng --manifest-path #{COMBAT_ENGINE_DIR}/Cargo.toml") || abort("Failed to build combat-rng")
end

unless File.exist?(COMBAT_SERVER)
  puts "Building combat-server..."
  system("#{CARGO} build --release -p combat-server --manifest-path #{COMBAT_ENGINE_DIR}/Cargo.toml") || abort("Failed to build combat-server")
end

# Step 2: Start combat-server if not already running
if File.socket?(SOCKET_PATH)
  puts "Combat-server already running at #{SOCKET_PATH}"
else
  puts "Starting combat-server (JSON mode)..."
  File.delete(SOCKET_PATH) if File.exist?(SOCKET_PATH)

  server_pid = spawn(
    { 'COMBAT_ENGINE_FORMAT' => 'json', 'COMBAT_ENGINE_SOCKET' => SOCKET_PATH },
    COMBAT_SERVER,
    out: '/dev/null',
    err: $stderr
  )

  # Wait for socket to appear
  30.times do
    break if File.socket?(SOCKET_PATH)
    sleep 0.1
  end

  unless File.socket?(SOCKET_PATH)
    Process.kill('TERM', server_pid) rescue nil
    abort "Combat-server failed to start (socket not created after 3s)"
  end

  puts "Combat-server started (pid=#{server_pid})"
end

puts

# Step 3: Run parity tests
rspec_args = ARGV.any? ? ARGV : ['--format', 'documentation']
cmd = ['bundle', 'exec', 'rspec', 'spec/parity/', *rspec_args]
puts "Running: #{cmd.join(' ')}"
puts "-" * 60

exit_status = system(*cmd)

puts
puts "=" * 60
puts exit_status ? "PARITY TESTS PASSED" : "PARITY TESTS FAILED"
puts "=" * 60

exit(exit_status ? 0 : 1)
