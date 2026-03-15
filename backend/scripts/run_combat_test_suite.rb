# frozen_string_literal: true

# Run the combat test suite through the real combat pipeline.
#
# Usage:
#   bundle exec ruby scripts/run_combat_test_suite.rb           # 1 repetition each
#   bundle exec ruby scripts/run_combat_test_suite.rb 3         # 3 reps each
#   bundle exec ruby scripts/run_combat_test_suite.rb --no-battlemaps  # skip battlemap rooms
#

require_relative '../app'

$stdout.sync = true

repetitions = 1
use_battlemaps = true

ARGV.each do |arg|
  case arg
  when /\A\d+\z/
    repetitions = arg.to_i
  when '--no-battlemaps'
    use_battlemaps = false
  when '--help', '-h'
    puts 'Usage: bundle exec ruby scripts/run_combat_test_suite.rb [repetitions] [--no-battlemaps]'
    exit 0
  end
end

puts "Combat Test Suite"
puts "  Repetitions: #{repetitions}"
puts "  Battlemaps: #{use_battlemaps ? 'included' : 'excluded'}"
puts ''

service = CombatTestSuiteService.new(repetitions: repetitions, use_battlemaps: use_battlemaps)
results = service.run_all!
service.print_report(results)
