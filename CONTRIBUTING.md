# Contributing to Firefly MUD Engine

Thank you for your interest in contributing to Firefly! This document provides guidelines and instructions for contributing.

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Workflow](#development-workflow)
4. [Code Style](#code-style)
5. [Testing](#testing)
6. [Commit Messages](#commit-messages)
7. [Pull Requests](#pull-requests)
8. [Documentation](#documentation)

## Code of Conduct

Be respectful, inclusive, and constructive. We're building a game engine for collaborative storytelling—let's apply those values to our development community too.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone <your-fork-url>`
3. Follow the [Getting Started Guide](backend/GETTING_STARTED.md) for setup
4. Create a branch for your work: `git checkout -b feature/your-feature`

## Development Workflow

### 1. Check for Existing Work

Before starting, check:
- Open issues for the feature/bug
- Open pull requests for related work
- Existing documentation in `backend/docs/`

### 2. Create a Branch

Use descriptive branch names:

```bash
# Features
git checkout -b feature/whisper-command
git checkout -b feature/inventory-system

# Bug fixes
git checkout -b fix/sql-injection-room-model
git checkout -b fix/rate-limit-bypass

# Documentation
git checkout -b docs/api-documentation
git checkout -b docs/plugin-guide
```

### 3. Make Changes

- Write code following the [style guide](#code-style)
- Add tests for new functionality
- Update documentation as needed
- Reference the [Security Best Practices](backend/docs/SECURITY.md) for secure coding

### 4. Test Your Changes

```bash
cd backend

# Run all tests
bundle exec rspec

# Run specific tests
bundle exec rspec spec/models/room_spec.rb

# Run with coverage
COVERAGE=true bundle exec rspec

# Run linting
bundle exec rubocop

# Test with MCP agents (optional but recommended)
bundle exec ruby scripts/create_test_agent.rb
# Then use MCP tools to test your feature
```

### 5. Commit and Push

```bash
git add .
git commit -m "feat(commands): add whisper command for private messages"
git push origin feature/whisper-command
```

### 6. Create Pull Request

Open a PR against the `main` branch with:
- Clear title following commit message format
- Description of changes
- Testing notes
- Screenshots (for UI changes)

## Code Style

### Ruby Style

We follow the [Ruby Style Guide](https://github.com/rubocop/ruby-style-guide) with some modifications:

```ruby
# frozen_string_literal: true

module Commands
  module Communication
    # Short class description
    class Whisper < Commands::Base::Command
      command_name 'whisper'
      aliases 'wh', 'tell'
      category :communication
      help_text 'Send a private message to another character'

      requires_alive

      protected

      def perform_command(parsed_input)
        # Implementation
      end

      private

      def helper_method
        # Private helper
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Whisper)
```

### Key Conventions

1. **Frozen string literal**: Add to all Ruby files
2. **Two-space indentation**: No tabs
3. **Snake_case**: For methods and variables
4. **CamelCase**: For classes and modules
5. **SCREAMING_SNAKE_CASE**: For constants
6. **Max line length**: 120 characters

### Command Structure

Follow the existing command pattern:

```ruby
# 1. Metadata at top
command_name 'mycommand'
aliases 'mc'
category :category
help_text 'Description'

# 2. Requirements
requires_alive
requires_standing

# 3. Protected perform_command
protected

def perform_command(parsed_input)
  # Main logic
end

# 4. Private helpers
private

def helper_methods
end

# 5. Registration at bottom
Commands::Base::Registry.register(...)
```

### Rubocop

Run rubocop before committing:

```bash
bundle exec rubocop

# Auto-fix safe issues
bundle exec rubocop --autocorrect

# Fix all issues (review changes)
bundle exec rubocop --autocorrect-all
```

## Testing

### Test Requirements

- All new features need tests
- Bug fixes should include a regression test
- Aim for >80% coverage on new code

### Test Structure

```ruby
# spec/commands/category/mycommand_spec.rb
require 'spec_helper'

RSpec.describe Commands::Category::MyCommand do
  # Setup
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           status: 'alive',
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  describe '#execute' do
    context 'when input is valid' do
      it 'succeeds' do
        result = command.execute('mycommand valid_input')
        expect(result[:success]).to be true
      end

      it 'returns structured data' do
        result = command.execute('mycommand valid_input')
        expect(result[:type]).to eq(:expected_type)
      end
    end

    context 'when input is invalid' do
      it 'returns an error' do
        result = command.execute('mycommand')
        expect(result[:success]).to be false
        expect(result[:error]).to be_present
      end
    end

    context 'when requirements not met' do
      before { character_instance.update(status: 'dead') }

      it 'fails with requirement message' do
        result = command.execute('mycommand valid_input')
        expect(result[:success]).to be false
        expect(result[:error]).to include('dead')
      end
    end
  end
end
```

### MCP Agent Testing

For complex features, use the MCP testing tools:

```python
# Test your command
mcp__firefly-test__execute_command(command: "mycommand arg")

# Test multi-agent scenarios
mcp__firefly-test__test_feature(
    objective="Test mycommand with edge cases",
    agent_count=2,
    max_steps_per_agent=10
)
```

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Code style (formatting, semicolons) |
| `refactor` | Code change that neither fixes bug nor adds feature |
| `perf` | Performance improvement |
| `test` | Adding or fixing tests |
| `chore` | Maintenance tasks |

### Scopes

| Scope | Description |
|-------|-------------|
| `commands` | Command system changes |
| `models` | Database models |
| `api` | REST API changes |
| `websocket` | WebSocket/AnyCable |
| `auth` | Authentication/authorization |
| `plugins` | Plugin system |
| `docs` | Documentation |

### Examples

```
feat(commands): add whisper command for private messages

Implements private messaging between characters in the same room.
Includes sender/recipient validation and message persistence.

Closes #42
```

```
fix(models): prevent SQL injection in Room.visible_characters

Use Sequel.case() instead of string interpolation when building
the CASE expression for sightline quality.

Fixes #56
```

```
docs(api): add agent API endpoint documentation

Documents all /api/agent/* endpoints with request/response
examples and error handling.
```

## Pull Requests

### PR Title

Follow the same format as commit messages:

```
feat(commands): add whisper command for private messages
```

### PR Description Template

```markdown
## Summary

Brief description of what this PR does.

- Change 1
- Change 2
- Change 3

## Testing

How to test these changes:

1. Start the server
2. Execute command X
3. Verify behavior Y

## Checklist

- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] Follows code style guide
- [ ] Security considerations reviewed
- [ ] No breaking changes (or documented)
```

### Review Process

1. All PRs require at least one approval
2. CI must pass (tests, linting, coverage)
3. Address all review comments
4. Squash commits before merge (or use "Squash and merge")

## Documentation

### When to Update Docs

- New features: Update relevant guides
- API changes: Update `docs/API.md`
- Configuration changes: Update `.env.example`
- Command changes: Update command help text
- Security-related: Update `docs/SECURITY.md`

### Documentation Style

- Use clear, concise language
- Include code examples
- Show both correct and incorrect patterns
- Add to table of contents for longer docs

### CLAUDE.md

Keep `CLAUDE.md` updated with:
- Current project status
- Quick reference to new docs
- Important architectural decisions

## Issue Labels

| Label | Description |
|-------|-------------|
| `bug` | Something isn't working |
| `enhancement` | New feature request |
| `documentation` | Documentation improvements |
| `good first issue` | Good for newcomers |
| `help wanted` | Extra attention needed |
| `security` | Security-related issue |
| `p1-critical` | Critical priority |
| `p2-important` | Important priority |
| `p3-minor` | Minor priority |

## Getting Help

- Check existing documentation in `backend/docs/`
- Look at similar implementations in `plugins/core/`
- Open an issue for discussion
- Reference `plugins/examples/greeting/` for command patterns

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
