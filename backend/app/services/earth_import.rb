# frozen_string_literal: true

# Earth Import module for importing real Earth topography data
module EarthImport
  class Error < StandardError; end
  class DownloadError < Error; end
  class ParseError < Error; end
end

# Load all earth_import services
Dir[File.join(__dir__, 'earth_import', '*.rb')].sort.each { |f| require f }
