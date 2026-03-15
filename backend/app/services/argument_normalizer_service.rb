# frozen_string_literal: true

# ArgumentNormalizerService normalizes natural language variations into
# consistent argument formats before commands process them.
#
# Handles:
# - Preposition reordering ("give sword to bob" → target: bob, item: sword)
# - Article removal ("give bob the sword" → target: bob, item: sword)
# - Container/placement parsing ("get sword from bag" → item: sword, container: bag)
# - Comma-prefix direct address ("bob, hello" → say to bob)
#
# Usage:
#   result = ArgumentNormalizerService.normalize('say', 'hello to bob')
#   # => { target: 'bob', message: 'hello' }
#
#   result = ArgumentNormalizerService.normalize('get', 'the sword from the table')
#   # => { item: 'sword', container: 'table', preposition: 'from' }
#
#   result = ArgumentNormalizerService.normalize_direct_address('bob, hello')
#   # => { command: 'say', target: 'bob', message: 'hello' }
#
class ArgumentNormalizerService
  COMMUNICATION_COMMANDS = %w[
    say whisper tell ask yell shout
    mutter grumble scream moan gasp sob
    stutter murmur flirt lecture argue confess
    sayto order instruct beg demand tease mock taunt
    whi wh
    private priv attempt propose request
    pemit semit subtle
    npcquery asknpc querynpc
    seed
    pemote npcemote
    summon call beckon
    sceneinstructions sceneinstruct
  ].freeze

  TRANSFER_COMMANDS = %w[
    give hand show throw toss
    offer pass slip gift display present
  ].freeze

  CONTAINER_COMMANDS = %w[
    get take pickup grab
    drop discard put
  ].freeze

  class << self
    # Normalize arguments for a specific command
    # @param command [String] the command name
    # @param args [String] the raw argument string
    # @return [Hash] normalized arguments
    def normalize(command, args)
      return { raw: args } if args.nil? || args.strip.empty?

      args = args.strip
      cmd = command.downcase

      if COMMUNICATION_COMMANDS.include?(cmd)
        normalize_communication(args)
      elsif TRANSFER_COMMANDS.include?(cmd)
        normalize_transfer(args)
      elsif CONTAINER_COMMANDS.include?(cmd)
        normalize_container(args)
      else
        { raw: args }
      end
    end

    # Check for and normalize comma-prefix direct address
    # "bob, hello there" → { command: 'say', target: 'bob', message: 'hello there' }
    # @param input [String] full input line
    # @return [Hash, nil] normalized result or nil if not direct address
    def normalize_direct_address(input)
      return nil if input.nil?

      # Match: "name, message" pattern
      match = input.match(/^([a-zA-Z][a-zA-Z0-9_\- ]*?),\s*(.+)$/m)
      return nil unless match

      target = match[1].strip
      message = match[2].strip

      return nil if target.empty? || message.empty?

      { command: 'say', target: target, message: message }
    end

    private

    # Normalize communication command arguments
    # Handles: "to bob hello", "hello to bob", "bob hello"
    def normalize_communication(args)
      # Pattern 1: "to <target> <message>"
      if args =~ /^to\s+(\S+)\s+(.+)$/i
        return { target: ::Regexp.last_match(1), message: ::Regexp.last_match(2) }
      end

      # Pattern 2: "<message> to <target>" (message at end)
      if args =~ /^(.+?)\s+to\s+(\S+)$/i
        return { target: ::Regexp.last_match(2), message: ::Regexp.last_match(1) }
      end

      # Pattern 3: "<target> <message>" (tell bob hello)
      # First word is target, rest is message
      words = args.split(/\s+/, 2)
      if words.length == 2
        return { target: words[0], message: words[1] }
      end

      { raw: args }
    end

    # Normalize transfer command arguments
    # Handles: "sword to bob", "bob the sword", "bob sword"
    def normalize_transfer(args)
      # Pattern 1: "<item> to <target>"
      if args =~ /^(.+?)\s+to\s+(\S+)$/i
        return { target: ::Regexp.last_match(2), item: ::Regexp.last_match(1).strip }
      end

      # Pattern 2: "<target> the <item>"
      if args =~ /^(\S+)\s+the\s+(.+)$/i
        return { target: ::Regexp.last_match(1), item: ::Regexp.last_match(2).strip }
      end

      # Pattern 3: "<target> <item>" (already correct format)
      words = args.split(/\s+/, 2)
      if words.length == 2
        return { target: words[0], item: words[1] }
      end

      { raw: args }
    end

    # Normalize container/placement command arguments
    # Handles: "sword from bag", "the sword from the table", "sword in bag"
    def normalize_container(args)
      # Pattern 1: "<item> from/in/on/off/into/onto <container>"
      if args =~ /^(.+?)\s+(from|off|in|on|into|onto)\s+(.+)$/i
        item = strip_articles(::Regexp.last_match(1))
        preposition = ::Regexp.last_match(2).downcase
        container = strip_articles(::Regexp.last_match(3))
        return { item: item, container: container, preposition: preposition }
      end

      # Pattern 2: Strip leading article from single item ("the sword" → "sword")
      stripped = strip_articles(args)
      return { item: stripped } if stripped != args

      { raw: args }
    end

    # Remove leading articles (the, a, an, some) from text
    def strip_articles(text)
      text.sub(/^(?:the|a|an|some)\s+/i, '').strip
    end
  end
end
