/**
 * AudioQueueManager - Manages TTS audio queue for accessibility mode
 *
 * Provides sequential audio playback with:
 * - Queue management (enqueue, clear, skip to latest)
 * - Playback controls (play, pause, resume)
 * - Skip forward/backward by seconds
 * - Automatic pause on typing detection
 * - Keyboard shortcuts for accessibility
 *
 * @example
 *   const audioQueue = new AudioQueueManager();
 *   audioQueue.enqueue({ audio_url: '/audio/tts/123.mp3', content_type: 'narrator' });
 *   audioQueue.play();
 */
class AudioQueueManager {
  constructor(options = {}) {
    // Queue state
    this.queue = [];
    this.currentAudio = null;
    this.currentItem = null;
    this.currentIndex = 0;

    // Playback state
    this.isPaused = false;
    this.isPlaying = false;
    this.volume = options.volume || 1.0;
    this.playbackRate = options.playbackRate || 1.0;

    // Settings
    this.pauseOnTyping = options.pauseOnTyping !== false;
    this.autoResumeDelay = options.autoResumeDelay || 1500; // ms after typing stops
    this.skipSeconds = options.skipSeconds || 15;
    this.enabled = options.enabled !== false;

    // Typing detection state
    this.typingTimer = null;
    this.wasPlayingBeforeTyping = false;

    // Callbacks
    this.onPlay = options.onPlay || null;
    this.onPause = options.onPause || null;
    this.onEnded = options.onEnded || null;
    this.onQueueEmpty = options.onQueueEmpty || null;
    this.onError = options.onError || null;
    this.onItemStart = options.onItemStart || null;

    // Bind methods for event listeners
    this._onAudioEnded = this._onAudioEnded.bind(this);
    this._onAudioError = this._onAudioError.bind(this);
    this._onKeyDown = this._onKeyDown.bind(this);
    this._onTypingStart = this._onTypingStart.bind(this);
    this._onTypingEnd = this._onTypingEnd.bind(this);

    // Initialize
    this._setupKeyboardShortcuts();
    this._setupTypingDetection();
  }

  // ========================================
  // Queue Management
  // ========================================

  /**
   * Add an item to the audio queue
   * @param {Object} item - Audio item with audio_url, content_type, original_text
   * @returns {number} Queue position
   */
  enqueue(item) {
    if (!this.enabled) return -1;

    const queueItem = {
      id: item.id || Date.now(),
      audio_url: item.audio_url,
      content_type: item.content_type || 'narrator',
      original_text: item.original_text || '',
      duration_seconds: item.duration_seconds || 0,
      sequence_number: item.sequence_number || this.queue.length,
      enqueued_at: new Date()
    };

    this.queue.push(queueItem);

    // Auto-start if not playing
    if (!this.isPlaying && !this.isPaused) {
      this.play();
    }

    return this.queue.length - 1;
  }

  /**
   * Add multiple items to the queue
   * @param {Array} items - Array of audio items
   */
  enqueueAll(items) {
    items.forEach(item => this.enqueue(item));
  }

  /**
   * Clear all pending items from the queue
   * @returns {number} Number of items cleared
   */
  clear() {
    const count = this.queue.length;
    this.queue = [];
    this.currentIndex = 0;

    if (this.currentAudio) {
      this.currentAudio.pause();
      this.currentAudio = null;
      this.currentItem = null;
    }

    this.isPlaying = false;
    this.isPaused = false;

    return count;
  }

  /**
   * Get queue statistics
   * @returns {Object} Queue stats
   */
  getStats() {
    return {
      total: this.queue.length,
      remaining: this.queue.length - this.currentIndex,
      currentIndex: this.currentIndex,
      isPlaying: this.isPlaying,
      isPaused: this.isPaused,
      currentItem: this.currentItem
    };
  }

  // ========================================
  // Playback Controls
  // ========================================

  /**
   * Start or resume playback
   */
  play() {
    if (!this.enabled) return;

    if (this.isPaused && this.currentAudio) {
      // Resume paused audio
      this.currentAudio.play();
      this.isPaused = false;
      this.isPlaying = true;
      if (this.onPlay) this.onPlay(this.currentItem);
      return;
    }

    // Start next item in queue
    this._playNext();
  }

  /**
   * Pause current playback
   */
  pause() {
    if (this.currentAudio && this.isPlaying) {
      this.currentAudio.pause();
      this.isPaused = true;
      this.isPlaying = false;
      if (this.onPause) this.onPause(this.currentItem);
    }
  }

  /**
   * Resume from pause
   */
  resume() {
    if (this.isPaused) {
      this.play();
    }
  }

  /**
   * Toggle play/pause
   */
  toggle() {
    if (this.isPlaying) {
      this.pause();
    } else {
      this.play();
    }
  }

  /**
   * Stop playback completely
   */
  stop() {
    if (this.currentAudio) {
      this.currentAudio.pause();
      this.currentAudio.currentTime = 0;
      this.currentAudio = null;
      this.currentItem = null;
    }
    this.isPlaying = false;
    this.isPaused = false;
  }

  /**
   * Skip to the latest/newest content (clear queue, play most recent)
   */
  skipToCurrent() {
    if (this.queue.length === 0) return;

    // Jump to last item
    this.currentIndex = this.queue.length - 1;

    if (this.currentAudio) {
      this.currentAudio.pause();
      this.currentAudio = null;
    }

    this._playNext();
  }

  /**
   * Skip forward by specified seconds
   * @param {number} seconds - Seconds to skip (default: 15)
   */
  skipForward(seconds = null) {
    const skipAmount = seconds || this.skipSeconds;

    if (this.currentAudio) {
      const newTime = Math.min(
        this.currentAudio.currentTime + skipAmount,
        this.currentAudio.duration
      );
      this.currentAudio.currentTime = newTime;

      // If we've skipped past the end, move to next
      if (newTime >= this.currentAudio.duration) {
        this._playNext();
      }
    }
  }

  /**
   * Skip backward by specified seconds
   * @param {number} seconds - Seconds to skip back (default: 15)
   */
  skipBackward(seconds = null) {
    const skipAmount = seconds || this.skipSeconds;

    if (this.currentAudio) {
      const newTime = Math.max(
        this.currentAudio.currentTime - skipAmount,
        0
      );
      this.currentAudio.currentTime = newTime;
    }
  }

  /**
   * Set playback volume
   * @param {number} volume - Volume level (0.0 to 1.0)
   */
  setVolume(volume) {
    this.volume = Math.max(0, Math.min(1, volume));
    if (this.currentAudio) {
      this.currentAudio.volume = this.volume;
    }
  }

  /**
   * Set playback speed
   * @param {number} rate - Playback rate (0.5 to 2.0)
   */
  setPlaybackRate(rate) {
    this.playbackRate = Math.max(0.5, Math.min(2.0, rate));
    if (this.currentAudio) {
      this.currentAudio.playbackRate = this.playbackRate;
    }
  }

  // ========================================
  // Typing Detection
  // ========================================

  /**
   * Called when user starts typing
   */
  onTypingStart() {
    if (!this.pauseOnTyping) return;

    // Clear any pending resume timer
    if (this.typingTimer) {
      clearTimeout(this.typingTimer);
      this.typingTimer = null;
    }

    // Remember if we were playing, then pause
    if (this.isPlaying && !this.isPaused) {
      this.wasPlayingBeforeTyping = true;
      this.pause();
    }
  }

  /**
   * Called when user stops typing (with auto-resume delay)
   */
  onTypingEnd() {
    if (!this.pauseOnTyping) return;

    // Clear any existing timer
    if (this.typingTimer) {
      clearTimeout(this.typingTimer);
    }

    // Set timer to resume after delay
    this.typingTimer = setTimeout(() => {
      if (this.wasPlayingBeforeTyping && this.isPaused) {
        this.resume();
        this.wasPlayingBeforeTyping = false;
      }
      this.typingTimer = null;
    }, this.autoResumeDelay);
  }

  // ========================================
  // Settings
  // ========================================

  /**
   * Enable or disable the audio queue
   * @param {boolean} enabled
   */
  setEnabled(enabled) {
    this.enabled = enabled;
    if (!enabled) {
      this.stop();
      this.clear();
    }
  }

  /**
   * Enable or disable pause on typing
   * @param {boolean} enabled
   */
  setPauseOnTyping(enabled) {
    this.pauseOnTyping = enabled;
  }

  /**
   * Set auto-resume delay after typing stops
   * @param {number} ms - Milliseconds
   */
  setAutoResumeDelay(ms) {
    this.autoResumeDelay = ms;
  }

  // ========================================
  // Private Methods
  // ========================================

  /**
   * Play the next item in the queue
   * @private
   */
  _playNext() {
    // Check if there are more items
    if (this.currentIndex >= this.queue.length) {
      this.isPlaying = false;
      this.currentItem = null;
      if (this.onQueueEmpty) this.onQueueEmpty();
      return;
    }

    // Get next item
    const item = this.queue[this.currentIndex];
    this.currentItem = item;
    this.currentIndex++;

    // Create audio element
    this.currentAudio = new Audio(item.audio_url);
    this.currentAudio.volume = this.volume;
    this.currentAudio.playbackRate = this.playbackRate;

    // Set up event listeners
    this.currentAudio.addEventListener('ended', this._onAudioEnded);
    this.currentAudio.addEventListener('error', this._onAudioError);

    // Start playback
    this.currentAudio.play()
      .then(() => {
        this.isPlaying = true;
        this.isPaused = false;
        if (this.onItemStart) this.onItemStart(item);
      })
      .catch(error => {
        console.error('[AudioQueueManager] Playback failed:', error);
        if (this.onError) this.onError(error, item);
        // Try next item
        this._playNext();
      });
  }

  /**
   * Handle audio ended event
   * @private
   */
  _onAudioEnded() {
    if (this.onEnded) this.onEnded(this.currentItem);
    this._playNext();
  }

  /**
   * Handle audio error event
   * @private
   */
  _onAudioError(event) {
    console.error('[AudioQueueManager] Audio error:', event);
    if (this.onError) this.onError(event, this.currentItem);
    // Try next item
    this._playNext();
  }

  /**
   * Set up keyboard shortcuts
   * @private
   */
  _setupKeyboardShortcuts() {
    document.addEventListener('keydown', this._onKeyDown);
  }

  /**
   * Handle keyboard shortcuts
   * @private
   */
  _onKeyDown(event) {
    // Don't trigger if typing in an input field
    const target = event.target;
    if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable) {
      return;
    }

    // Check for modifier keys (only allow with Alt for accessibility)
    if (!event.altKey) return;

    switch (event.key) {
      case 'ArrowRight':
        // Alt+Right: Skip forward 15 seconds
        event.preventDefault();
        this.skipForward();
        break;

      case 'ArrowLeft':
        // Alt+Left: Skip backward 15 seconds
        event.preventDefault();
        this.skipBackward();
        break;

      case 'ArrowUp':
        // Alt+Up: Increase volume
        event.preventDefault();
        this.setVolume(this.volume + 0.1);
        break;

      case 'ArrowDown':
        // Alt+Down: Decrease volume
        event.preventDefault();
        this.setVolume(this.volume - 0.1);
        break;

      case ' ':
      case 'p':
        // Alt+Space or Alt+P: Toggle play/pause
        event.preventDefault();
        this.toggle();
        break;

      case 's':
        // Alt+S: Skip to current (latest)
        event.preventDefault();
        this.skipToCurrent();
        break;

      case 'c':
        // Alt+C: Clear queue
        event.preventDefault();
        this.clear();
        break;
    }
  }

  /**
   * Set up typing detection on input fields
   * @private
   */
  _setupTypingDetection() {
    // Use event delegation for efficiency
    document.addEventListener('focusin', (event) => {
      const target = event.target;
      if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable) {
        this._onTypingStart();
      }
    });

    document.addEventListener('focusout', (event) => {
      const target = event.target;
      if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable) {
        this._onTypingEnd();
      }
    });

    // Also detect actual keystrokes in inputs
    document.addEventListener('keydown', (event) => {
      const target = event.target;
      if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable) {
        // Reset the typing timer on each keystroke
        if (this.wasPlayingBeforeTyping) {
          this._onTypingStart();
        }
      }
    });
  }

  /**
   * Internal typing start handler
   * @private
   */
  _onTypingStart() {
    this.onTypingStart();
  }

  /**
   * Internal typing end handler
   * @private
   */
  _onTypingEnd() {
    this.onTypingEnd();
  }

  /**
   * Clean up event listeners
   */
  destroy() {
    document.removeEventListener('keydown', this._onKeyDown);

    if (this.typingTimer) {
      clearTimeout(this.typingTimer);
      this.typingTimer = null;
    }

    if (this.currentAudio) {
      this.currentAudio.removeEventListener('ended', this._onAudioEnded);
      this.currentAudio.removeEventListener('error', this._onAudioError);
      this.currentAudio.pause();
      this.currentAudio = null;
    }

    this.queue = [];
    this.currentItem = null;
    this.isPlaying = false;
    this.isPaused = false;
    this.enabled = false;
    this.wasPlayingBeforeTyping = false;
  }
}

// ========================================
// WebSocket Integration Helper
// ========================================

/**
 * Connect AudioQueueManager to WebSocket for real-time TTS updates
 * @param {AudioQueueManager} audioQueue - The audio queue instance
 * @param {WebSocket} socket - WebSocket connection
 */
function connectAudioQueueToWebSocket(audioQueue, socket) {
  socket.addEventListener('message', (event) => {
    try {
      const data = JSON.parse(event.data);

      // Handle TTS audio messages
      if (data.type === 'tts_audio' || data.type === 'audio_queue_item') {
        audioQueue.enqueue({
          id: data.id,
          audio_url: data.audio_url,
          content_type: data.content_type,
          original_text: data.original_text,
          duration_seconds: data.duration_seconds,
          sequence_number: data.sequence_number
        });
      }

      // Handle TTS control commands
      if (data.type === 'tts_control') {
        switch (data.action) {
          case 'pause':
            audioQueue.pause();
            break;
          case 'resume':
            audioQueue.resume();
            break;
          case 'clear':
            audioQueue.clear();
            break;
          case 'skip_to_current':
            audioQueue.skipToCurrent();
            break;
        }
      }
    } catch (e) {
      // Not JSON or not a TTS message - skip silently
      if (e instanceof SyntaxError) {
        console.warn('[AudioQueueManager] Failed to parse WebSocket message:', e.message);
      }
    }
  });
}

// ========================================
// API Polling Helper (for non-WebSocket setups)
// ========================================

/**
 * Poll API for pending audio items
 * @param {AudioQueueManager} audioQueue - The audio queue instance
 * @param {string} apiUrl - API endpoint for pending items
 * @param {number} pollInterval - Polling interval in ms (default: 2000)
 * @returns {Function} Stop polling function
 */
function startAudioQueuePolling(audioQueue, apiUrl, pollInterval = 2000) {
  let lastSequence = 0;

  const poll = async () => {
    try {
      const response = await fetch(`${apiUrl}?from_sequence=${lastSequence}`);
      if (response.ok) {
        const data = await response.json();
        if (data.items && data.items.length > 0) {
          data.items.forEach(item => {
            audioQueue.enqueue(item);
            if (item.sequence_number > lastSequence) {
              lastSequence = item.sequence_number;
            }
          });
        }
      }
    } catch (error) {
      console.error('[AudioQueuePolling] Error:', error);
    }
  };

  const intervalId = setInterval(poll, pollInterval);
  poll(); // Initial poll

  // Return stop function
  return () => clearInterval(intervalId);
}

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    AudioQueueManager,
    connectAudioQueueToWebSocket,
    startAudioQueuePolling
  };
}
