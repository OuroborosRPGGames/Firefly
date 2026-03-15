# frozen_string_literal: true

# Helpfile model for command and topic documentation
#
# Stores help content in the database for dynamic updates without restart.
# Each helpfile can be associated with a command and have multiple synonyms.
#
# Staff-only fields (source_file, source_line, staff_notes, code_references)
# store implementation details visible only to staff characters and admins.
#
class Helpfile < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  # Configure pg_array columns
  plugin :pg_array_associations

  # Content type for lore embeddings
  LORE_EMBEDDING_TYPE = 'world_lore'

  # Content type for autohelper semantic search
  HELPFILE_EMBEDDING_TYPE = 'helpfile'

  # Ensure array columns are handled as pg arrays
  def before_save
    self.aliases = Sequel.pg_array(aliases || [], :text) if aliases.is_a?(Array)
    self.related_commands = Sequel.pg_array(related_commands || [], :text) if related_commands.is_a?(Array)
    self.see_also = Sequel.pg_array(see_also || [], :text) if see_also.is_a?(Array)
    # Ensure code_references is valid JSONB
    if code_references.is_a?(Array)
      self.code_references = Sequel.pg_jsonb(code_references)
    end
    super
  end

  # Update embeddings after save
  # - All helpfiles are embedded for autohelper semantic search
  # - Lore helpfiles get additional world_lore embedding
  def after_save
    super
    # Embed all helpfiles for autohelper
    embed_helpfile_content! unless hidden

    # Handle lore embedding separately
    if is_lore
      embed_lore_content!
    else
      remove_lore_embedding!
    end
  end

  # Remove embeddings before destroy
  def before_destroy
    remove_helpfile_embedding!
    remove_lore_embedding! if is_lore
    super
  end

  one_to_many :helpfile_synonyms, key: :helpfile_id

  # Validations
  def validate
    super
    validates_presence [:command_name, :topic, :plugin, :summary]
    validates_unique :command_name
    validates_unique :topic
  end

  # Find helpfile by topic or any synonym
  # @param search [String] topic, command name, or synonym
  # @return [Helpfile, nil]
  def self.find_by_topic(search)
    return nil if search.nil? || search.empty?

    normalized = search.downcase.strip

    # Try exact match on command_name or topic first
    helpfile = first(Sequel.function(:lower, :command_name) => normalized) ||
               first(Sequel.function(:lower, :topic) => normalized)

    return helpfile if helpfile

    # Try synonym lookup
    synonym = HelpfileSynonym.first(Sequel.function(:lower, :synonym) => normalized)
    synonym&.helpfile
  end

  # Search helpfiles with fuzzy matching
  # @param query [String] search query
  # @param options [Hash] search options
  # @return [Array<Helpfile>]
  def self.search(query, options = {})
    return [] if query.nil? || query.strip.empty?

    normalized = query.downcase.strip
    results = []

    # Exact matches first
    results += where(Sequel.function(:lower, :command_name) => normalized).all
    results += where(Sequel.function(:lower, :topic) => normalized).all

    # Category match - if query matches a category name, return all commands in that category
    category_results = where(Sequel.function(:lower, :category) => normalized).all
    results += category_results

    # Partial matches
    pattern = "%#{normalized}%"
    results += where(Sequel.ilike(:command_name, pattern))
               .or(Sequel.ilike(:topic, pattern))
               .or(Sequel.ilike(:summary, pattern))
               .or(Sequel.ilike(:category, pattern))
               .exclude(id: results.map(&:id))
               .limit(options[:limit] || 20)
               .all

    # Filter by category if specified
    if options[:category]
      results = results.select { |h| h.category == options[:category].to_s }
    end

    # Filter out hidden unless admin
    unless options[:include_hidden]
      results = results.reject(&:hidden)
    end

    # Filter out admin-only unless admin
    unless options[:admin]
      results = results.reject(&:admin_only)
    end

    results.uniq(&:id)
  end

  # Generate helpfile from command class metadata
  # @param command_class [Class] command class with DSL metadata
  # @return [Helpfile]
  def self.generate_from_command(command_class)
    return nil unless command_class.respond_to?(:command_name)

    cmd_name = command_class.command_name
    existing = first(command_name: cmd_name)

    # Extract source location
    source_info = extract_source_info(command_class)

    # Extract requirements summary
    requirements_text = extract_requirements_summary(command_class)

    attrs = {
      command_name: cmd_name,
      topic: cmd_name,
      plugin: command_class.respond_to?(:plugin_name) ? command_class.plugin_name.to_s : 'core',
      category: command_class.respond_to?(:category) ? command_class.category.to_s : nil,
      summary: command_class.respond_to?(:help_text) ? command_class.help_text : "The #{cmd_name} command",
      syntax: command_class.respond_to?(:usage) ? (command_class.usage || cmd_name) : cmd_name,
      examples: build_examples_json(command_class),
      aliases: command_class.respond_to?(:alias_names) ? command_class.alias_names : [],
      auto_generated: true,
      toc_section: command_class.respond_to?(:category) ? command_class.category.to_s.capitalize : 'General',
      # Staff fields
      source_file: source_info[:file],
      source_line: source_info[:line],
      requirements_summary: requirements_text,
      # Preserve existing staff_notes if updating (don't overwrite manual notes)
      staff_notes: existing&.staff_notes
    }

    if existing
      # Don't overwrite manually set staff_notes
      attrs.delete(:staff_notes) if existing.staff_notes && !existing.staff_notes.empty?
      existing.update(attrs)
      existing
    else
      create(attrs)
    end
  end

  # Extract source file and line from command class using Ruby reflection
  # @param command_class [Class]
  # @return [Hash] { file: String, line: Integer }
  def self.extract_source_info(command_class)
    # Try to get location from the execute or perform_command method
    method_name = command_class.instance_methods(false).include?(:perform_command) ? :perform_command : :execute

    begin
      location = command_class.instance_method(method_name).source_location
      if location
        file = location[0]
        line = location[1]

        # Make path relative to backend/
        relative_path = file.to_s.sub(%r{.*/backend/}, '')

        return { file: relative_path, line: line }
      end
    rescue StandardError => e
      warn "[Helpfile] Failed to extract command source location: #{e.message}"
    end

    { file: nil, line: nil }
  end

  # Extract human-readable requirements summary from command class
  # @param command_class [Class]
  # @return [String, nil]
  def self.extract_requirements_summary(command_class)
    return nil unless command_class.respond_to?(:requirements)

    requirements = command_class.requirements
    return 'Always available' if requirements.nil? || requirements.empty?

    # Build human-readable summary
    summaries = requirements.map do |req|
      case req[:type]
      when :in_combat then 'Must be in combat'
      when :not_in_combat then 'Cannot be in combat'
      when :room_type then "Must be in #{req[:args].join(' or ')} room"
      when :character_state
        state = req[:args].first
        case state
        when :alive then 'Must be alive'
        when :conscious then 'Must be conscious'
        when :standing then 'Must be standing'
        else "Character must be #{state}"
        end
      when :has_equipped then "Must have #{req[:args].first} equipped"
      when :has_item then "Must have #{req[:args].first}"
      when :has_resource then "Must have enough #{req[:args].first}"
      when :era then "Available in: #{req[:args].join(', ')}"
      when :not_era then "Not available in: #{req[:args].join(', ')}"
      when :has_phone then 'Requires a phone/communicator'
      when :digital_currency then 'Requires digital currency era'
      when :taxi_available then 'Requires taxi service'
      when :can_communicate_ic then 'Must be able to communicate in-character'
      when :can_modify_rooms then 'Must be able to modify rooms (not in timeline)'
      else req[:message] || "Requires: #{req[:type]}"
      end
    end

    summaries.join('; ')
  end

  # Sync all registered commands to helpfiles
  # @return [Integer] number of helpfiles synced
  def self.sync_all_commands!
    return 0 unless defined?(Commands::Base::Registry)

    count = 0
    Commands::Base::Registry.commands.values.each do |command_class|
      begin
        generate_from_command(command_class)
        count += 1
      rescue StandardError => e
        warn "[Helpfile] Failed to sync #{command_class}: #{e.message}"
      end
    end
    count
  end

  # Render full help content
  # @return [String] formatted help content
  def full_content
    content = []
    content << "# #{command_name.upcase}"
    content << ""
    content << summary
    content << ""

    if syntax && !syntax.empty?
      content << "## Syntax"
      content << "```"
      content << syntax
      content << "```"
      content << ""
    end

    if description && !description.empty?
      content << "## Description"
      content << description
      content << ""
    end

    if parsed_examples.any?
      content << "## Examples"
      parsed_examples.each do |ex|
        content << "- `#{ex['input']}`"
        content << "  #{ex['explanation']}" if ex['explanation']
      end
      content << ""
    end

    if aliases&.any?
      content << "## Aliases"
      content << aliases.join(', ')
      content << ""
    end

    if related_commands&.any?
      content << "## See Also"
      content << related_commands.join(', ')
    end

    content.join("\n")
  end

  # Format for agent/API consumption
  # @return [Hash]
  def to_agent_format
    {
      command: command_name,
      topic: topic,
      plugin: plugin,
      category: category,
      summary: summary,
      syntax: syntax,
      description: description,
      examples: parsed_examples,
      aliases: aliases || [],
      related_commands: related_commands || [],
      see_also: see_also || []
    }
  end

  # Format for staff view (includes implementation details)
  # @return [Hash]
  def to_staff_format
    to_agent_format.merge(
      source_file: source_file,
      source_line: source_line,
      staff_notes: staff_notes,
      requirements_summary: requirements_summary,
      code_references: parsed_code_references
    )
  end

  # Render player-visible help content
  # @return [String]
  def to_player_display
    lines = []
    lines << "<h4>Help: #{command_name.upcase}</h4>"
    lines << summary
    lines << ''

    if syntax && !syntax.empty?
      lines << "Usage: #{syntax}"
      lines << ''
    end

    if aliases && !aliases.empty?
      lines << "Aliases: #{aliases.to_a.join(', ')}"
      lines << ''
    end

    if parsed_examples.any?
      lines << 'Examples:'
      parsed_examples.each do |ex|
        lines << "  #{ex['input']}"
      end
      lines << ''
    end

    lines << "Category: #{category}" if category

    lines.join("\n")
  end

  # Render staff-visible help content (includes implementation details)
  # @return [String]
  def to_staff_display
    lines = [to_player_display]
    lines << ''
    lines << '<h4>Staff Information</h4>'

    if source_file
      source = source_file
      source += ":#{source_line}" if source_line
      lines << "Source: #{source}"
    end

    if requirements_summary && !requirements_summary.empty?
      lines << "Requirements: #{requirements_summary}"
    end

    if staff_notes && !staff_notes.empty?
      lines << ''
      lines << 'Implementation Notes:'
      lines << staff_notes
    end

    refs = parsed_code_references
    if refs.any?
      lines << ''
      lines << 'Related Files:'
      refs.each do |ref|
        desc = ref['desc'] || ref['description'] || ''
        file_ref = ref['file']
        file_ref += ":#{ref['line']}" if ref['line']
        lines << "  - #{file_ref}#{desc.empty? ? '' : " (#{desc})"}"
      end
    end

    lines.join("\n")
  end

  # Parse code_references JSONB into array of hashes
  # @return [Array<Hash>]
  def parsed_code_references
    return [] if code_references.nil?

    case code_references
    when Array
      code_references
    when String
      begin
        JSON.parse(code_references)
      rescue JSON::ParserError
        []
      end
    else
      code_references.to_a rescue []
    end
  end

  # Add a synonym for this helpfile
  # @param synonym [String]
  # @return [HelpfileSynonym, nil]
  def add_synonym(synonym)
    normalized = synonym.downcase.strip
    return nil if normalized.empty?

    # Check if synonym already exists (for any helpfile)
    existing = HelpfileSynonym.first(synonym: normalized)
    return existing if existing&.helpfile_id == id # Already linked to this helpfile

    # If exists for another helpfile, skip (synonyms are globally unique)
    return nil if existing

    # Create new synonym
    HelpfileSynonym.create(helpfile_id: id, synonym: normalized)
  rescue Sequel::ValidationFailed
    # Handle race condition where synonym was created between check and create
    nil
  end

  # Remove a synonym
  # @param synonym [String]
  def remove_synonym(synonym)
    normalized = synonym.downcase.strip
    HelpfileSynonym.where(helpfile_id: id, synonym: normalized).delete
  end

  # Sync aliases to synonyms table
  def sync_synonyms!
    # Remove existing synonyms
    HelpfileSynonym.where(helpfile_id: id).delete

    # Add current aliases
    (aliases || []).each do |alias_name|
      add_synonym(alias_name)
    end

    # Add command name as synonym
    add_synonym(command_name)
  end

  # ============================================
  # Lore Helpfile Methods
  # ============================================

  # Get all visible lore helpfiles
  # @return [Array<Helpfile>]
  def self.lore_topics
    where(is_lore: true, hidden: false).all
  end

  # Search lore helpfiles using semantic similarity
  # Uses Voyage AI embeddings with input_type: 'query' for asymmetric retrieval
  #
  # @param query [String] search query
  # @param limit [Integer] max results to return
  # @return [Array<Helpfile>] relevant lore helpfiles sorted by similarity
  def self.search_lore(query, limit: 5)
    return [] if query.nil? || query.strip.empty?

    # Use Embedding.search which handles input_type: 'query' automatically
    results = Embedding.search(
      query,
      limit: limit,
      content_type: LORE_EMBEDDING_TYPE,
      threshold: 0.4
    )

    return [] if results.empty?

    # Load helpfile records
    helpfile_ids = results.map { |r| r[:embedding].content_id }
    helpfiles = where(id: helpfile_ids).all
    helpfiles_by_id = helpfiles.each_with_object({}) { |h, hash| hash[h.id] = h }

    # Return in similarity order
    results.map { |r| helpfiles_by_id[r[:embedding].content_id] }.compact
  end

  # Get lore context for NPC prompts
  # Returns formatted lore content relevant to a query
  #
  # @param query [String] context query (e.g., recent conversation)
  # @param limit [Integer] max lore entries
  # @return [String] formatted lore for LLM context
  def self.lore_context_for(query, limit: 3)
    lore = search_lore(query, limit: limit)
    return '' if lore.empty?

    lore.map { |h| "#{h.topic}: #{h.summary}" }.join("\n")
  end

  # Store embedding for this helpfile's lore content
  # Called automatically when is_lore is set to true
  def embed_lore_content!
    return unless is_lore

    # Combine topic and summary for richer embedding
    lore_text = "#{topic}: #{summary}"
    lore_text += "\n#{description}" if description && !description.empty?

    Embedding.store(
      content_type: LORE_EMBEDDING_TYPE,
      content_id: id,
      text: lore_text,
      input_type: 'document' # Critical for asymmetric retrieval
    )
  rescue StandardError => e
    # Log but don't fail the save
    warn "[Helpfile] Failed to embed lore for #{topic}: #{e.message}"
  end

  # Remove lore embedding when is_lore is unset
  def remove_lore_embedding!
    Embedding.remove(content_type: LORE_EMBEDDING_TYPE, content_id: id)
  rescue StandardError => e
    warn "[Helpfile] Failed to remove lore embedding for #{topic}: #{e.message}"
  end

  # Check if this helpfile has a lore embedding
  # @return [Boolean]
  def lore_embedded?
    Embedding.exists_for?(content_type: LORE_EMBEDDING_TYPE, content_id: id)
  end

  # ============================================
  # Helpfile Embedding Methods (for Autohelper)
  # ============================================

  # Store embedding for this helpfile's searchable content
  # Called automatically on save for all non-hidden helpfiles
  def embed_helpfile_content!
    # Combine topic, summary, syntax, and description for rich embedding
    text_parts = [topic, summary]
    text_parts << "Syntax: #{syntax}" if syntax && !syntax.to_s.strip.empty?
    text_parts << description if description && !description.to_s.strip.empty?
    text_parts << "Aliases: #{aliases.to_a.join(', ')}" if aliases&.any?

    helpfile_text = text_parts.compact.join("\n")

    Embedding.store(
      content_type: HELPFILE_EMBEDDING_TYPE,
      content_id: id,
      text: helpfile_text,
      input_type: 'document'
    )
  rescue StandardError => e
    warn "[Helpfile] Failed to embed helpfile #{topic}: #{e.message}"
  end

  # Remove helpfile embedding when deleted or hidden
  def remove_helpfile_embedding!
    Embedding.remove(content_type: HELPFILE_EMBEDDING_TYPE, content_id: id)
  rescue StandardError => e
    warn "[Helpfile] Failed to remove helpfile embedding for #{topic}: #{e.message}"
  end

  # Check if this helpfile has a helpfile embedding
  # @return [Boolean]
  def helpfile_embedded?
    Embedding.exists_for?(content_type: HELPFILE_EMBEDDING_TYPE, content_id: id)
  end

  # Batch re-embed all non-hidden helpfiles
  # Use after adding embedding support or if embeddings are corrupted
  # @return [Integer] number of helpfiles embedded
  def self.embed_all_helpfiles!
    count = 0
    where(hidden: false).each do |helpfile|
      helpfile.embed_helpfile_content!
      count += 1
    rescue StandardError => e
      warn "[Helpfile] Failed to embed #{helpfile.topic}: #{e.message}"
    end
    count
  end

  # Search helpfiles using semantic similarity for autohelper
  # @param query [String] search query
  # @param limit [Integer] max results to return
  # @return [Array<Helpfile>] relevant helpfiles sorted by similarity
  def self.search_helpfiles(query, limit: 5)
    return [] if query.nil? || query.strip.empty?

    results = Embedding.search(
      query,
      limit: limit,
      content_type: HELPFILE_EMBEDDING_TYPE,
      threshold: 0.3
    )

    return [] if results.empty?

    helpfile_ids = results.map { |r| r[:embedding].content_id }
    helpfiles = where(id: helpfile_ids).all
    helpfiles_by_id = helpfiles.each_with_object({}) { |h, hash| hash[h.id] = h }

    # Return in similarity order with scores
    results.map do |r|
      hf = helpfiles_by_id[r[:embedding].content_id]
      next nil unless hf
      { helpfile: hf, similarity: r[:similarity] }
    end.compact
  end

  private

  def parsed_examples
    return [] if examples.nil? || examples.empty?

    begin
      JSON.parse(examples)
    rescue JSON::ParserError
      # Handle legacy string format
      examples.split("\n").map { |ex| { 'input' => ex.strip } }
    end
  end

  def self.build_examples_json(command_class)
    return '[]' unless command_class.respond_to?(:examples_list)

    examples = command_class.examples_list
    return '[]' if examples.nil? || examples.empty?

    examples.map do |ex|
      case ex
      when String
        { 'input' => ex }
      when Hash
        ex
      else
        { 'input' => ex.to_s }
      end
    end.to_json
  end
end
