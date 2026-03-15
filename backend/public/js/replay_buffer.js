/**
 * ReplayBufferManager - Per-pane message replay for screen reader accessibility.
 *
 * Maintains ring buffers of recent messages for the left (OOC) and right (RP/game)
 * panes of the Firefly webclient. Users can navigate backward and forward through
 * message history using keyboard shortcuts, with each message announced via an
 * aria-live region for screen reader users.
 *
 * Usage:
 *   const replay = new ReplayBufferManager({
 *     size: 25,                          // messages per buffer (default: 25)
 *     announcer: document.getElementById('srAnnouncer'),  // aria-live element
 *     onNavigate: (pane, position, total) => { ... }      // visual feedback callback
 *   });
 *
 *   // Push incoming messages
 *   replay.push('left', '<b>Someone</b> says "hello"');
 *   replay.push('right', '<span class="combat">You attack!</span>');
 *
 *   // Navigate with keyboard shortcuts
 *   replay.navigatePrev('right');  // Go to most recent, then older
 *   replay.navigateNext('right');  // Go newer, or end replay at newest
 *   replay.resetNavigation('right'); // Cancel replay (e.g. on Escape)
 *   replay.resetNavigation(null);    // Reset both panes
 */
class ReplayBufferManager {
  /**
   * @param {Object} options
   * @param {number} [options.size=25] - Maximum messages per buffer
   * @param {HTMLElement} [options.announcer] - aria-live element for announcements
   * @param {Function} [options.onNavigate] - Callback: (pane, position, total) => void
   */
  constructor(options = {}) {
    this._size = options.size || 25;
    this._announcer = options.announcer || null;
    this._onNavigate = options.onNavigate || null;

    this._buffers = {
      left: [],
      right: []
    };

    // null means not navigating; otherwise index into buffer
    this._cursors = {
      left: null,
      right: null
    };
  }

  /**
   * Push a new message into the specified pane's buffer.
   * HTML is stripped to plain text before storage.
   *
   * @param {string} pane - 'left' or 'right'
   * @param {string} html - HTML content of the message
   */
  push(pane, html) {
    const buffer = this._buffers[pane];
    if (!buffer) return;

    const text = this._stripHtml(html);
    if (!text) return;

    buffer.push(text);

    // Trim to max size, adjusting cursor if navigating
    if (buffer.length > this._size) {
      buffer.shift();

      if (this._cursors[pane] !== null) {
        this._cursors[pane]--;
        if (this._cursors[pane] < 0) {
          this._cursors[pane] = 0;
        }
      }
    }
  }

  /**
   * Navigate to the previous (older) message in the buffer.
   * First call starts at the most recent message.
   *
   * @param {string} pane - 'left' or 'right'
   * @returns {string|null} The message text, or null if buffer is empty
   */
  navigatePrev(pane) {
    const buffer = this._buffers[pane];
    if (!buffer) return null;

    if (buffer.length === 0) {
      this._announce('No messages to replay.');
      return null;
    }

    if (this._cursors[pane] === null) {
      // Start navigating at most recent message
      this._cursors[pane] = buffer.length - 1;
    } else if (this._cursors[pane] > 0) {
      this._cursors[pane]--;
    } else {
      // Already at oldest
      const text = buffer[0];
      this._announce('Beginning of message history.');
      if (this._onNavigate) {
        this._onNavigate(pane, 1, buffer.length);
      }
      return text;
    }

    const cursor = this._cursors[pane];
    const text = buffer[cursor];
    this._announce(text);

    if (this._onNavigate) {
      this._onNavigate(pane, cursor + 1, buffer.length);
    }

    return text;
  }

  /**
   * Navigate to the next (newer) message in the buffer.
   * When reaching the end, resets navigation.
   *
   * @param {string} pane - 'left' or 'right'
   * @returns {string|null} The message text, or null if not navigating/at end
   */
  navigateNext(pane) {
    const buffer = this._buffers[pane];
    if (!buffer) return null;

    if (this._cursors[pane] === null) {
      this._announce('Press previous message key first to start replaying.');
      return null;
    }

    if (this._cursors[pane] < buffer.length - 1) {
      this._cursors[pane]++;
      const cursor = this._cursors[pane];
      const text = buffer[cursor];
      this._announce(text);

      if (this._onNavigate) {
        this._onNavigate(pane, cursor + 1, buffer.length);
      }

      return text;
    }

    // At the newest message - end replay
    this._cursors[pane] = null;
    this._announce('Most recent message. Replay ended.');

    if (this._onNavigate) {
      this._onNavigate(pane, 0, buffer.length);
    }

    return null;
  }

  /**
   * Reset navigation cursor. Pass null to reset both panes.
   *
   * @param {string|null} pane - 'left', 'right', or null for both
   */
  resetNavigation(pane) {
    if (pane === null || pane === undefined) {
      this._cursors.left = null;
      this._cursors.right = null;
    } else {
      this._cursors[pane] = null;
    }
  }

  /**
   * Check if currently navigating the specified pane.
   *
   * @param {string} pane - 'left' or 'right'
   * @returns {boolean}
   */
  isNavigating(pane) {
    return this._cursors[pane] !== null;
  }

  /**
   * Announce text via the aria-live region.
   * Clears then sets after a delay to force screen reader re-announcement.
   *
   * @param {string} text
   * @private
   */
  _announce(text) {
    if (!this._announcer) return;

    this._announcer.textContent = '';
    setTimeout(() => {
      this._announcer.textContent = text;
    }, 50);
  }

  /**
   * Strip HTML tags from a string, returning plain text content.
   *
   * @param {string} html
   * @returns {string}
   * @private
   */
  _stripHtml(html) {
    const div = document.createElement('div');
    div.innerHTML = html;
    return (div.textContent || div.innerText || '').trim();
  }
}
