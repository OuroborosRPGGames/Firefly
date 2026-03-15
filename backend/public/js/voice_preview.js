/**
 * Voice Preview Manager
 * Handles TTS voice preview functionality for character creation
 */
class VoicePreviewManager {
  constructor() {
    this.audioElement = document.getElementById('voice-preview-audio');
    this.currentlyPlaying = null;
    this.previewCache = {};

    this.init();
  }

  init() {
    this.setupPreviewButtons();
    this.setupSliders();
    this.setupAudioEvents();
  }

  setupPreviewButtons() {
    document.querySelectorAll('.voice-preview-btn').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        const voice = btn.dataset.voice;
        this.playPreview(voice, btn);
      });
    });
  }

  setupSliders() {
    // Speed slider
    const speedSlider = document.getElementById('voice_speed');
    const speedDisplay = document.getElementById('speed-display');
    if (speedSlider && speedDisplay) {
      speedSlider.addEventListener('input', () => {
        speedDisplay.textContent = speedSlider.value + 'x';
      });
    }

    // Pitch slider
    const pitchSlider = document.getElementById('voice_pitch');
    const pitchDisplay = document.getElementById('pitch-display');
    if (pitchSlider && pitchDisplay) {
      pitchSlider.addEventListener('input', () => {
        const val = parseInt(pitchSlider.value);
        pitchDisplay.textContent = val > 0 ? '+' + val : val;
      });
    }
  }

  setupAudioEvents() {
    if (!this.audioElement) return;

    this.audioElement.addEventListener('ended', () => {
      this.resetButton(this.currentlyPlaying);
      this.currentlyPlaying = null;
    });

    this.audioElement.addEventListener('error', () => {
      this.resetButton(this.currentlyPlaying);
      this.currentlyPlaying = null;
      console.error('Audio playback error');
    });
  }

  async playPreview(voiceType, buttonElement) {
    // If same voice is playing, stop it
    if (this.currentlyPlaying === buttonElement && !this.audioElement.paused) {
      this.stopPlayback();
      return;
    }

    // Stop any current playback
    this.stopPlayback();

    // Update button state
    this.setButtonLoading(buttonElement);
    this.currentlyPlaying = buttonElement;

    // Get current speed and pitch values from sliders
    const speedSlider = document.getElementById('voice_speed');
    const pitchSlider = document.getElementById('voice_pitch');
    const voiceSpeed = speedSlider ? parseFloat(speedSlider.value) : 1.0;
    const voicePitch = pitchSlider ? parseFloat(pitchSlider.value) : 0.0;

    // Cache key includes speed/pitch since different settings = different audio
    const cacheKey = `${voiceType}_${voiceSpeed}_${voicePitch}`;

    try {
      // Check cache first
      if (this.previewCache[cacheKey]) {
        this.playAudio(this.previewCache[cacheKey], buttonElement);
        return;
      }

      // Fetch preview from API with speed/pitch settings
      const response = await fetch('/api/tts/preview', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          voice_type: voiceType,
          voice_speed: voiceSpeed,
          voice_pitch: voicePitch
        })
      });

      const data = await response.json();

      if (data.success && data.audio_url) {
        this.previewCache[cacheKey] = data.audio_url;
        this.playAudio(data.audio_url, buttonElement);
      } else {
        console.error('Preview generation failed:', data.error);
        const errorMsg = data.error || 'Preview unavailable';
        this.showError(buttonElement, errorMsg);

        // Show global error if TTS is not configured
        if (data.error?.includes('not configured') || data.error?.includes('API key')) {
          this.showGlobalError('Voice preview is currently unavailable. TTS service is not configured.');
        }
      }
    } catch (err) {
      console.error('Preview error:', err);

      // Check if it's a 404 or network error
      if (err.message?.includes('404') || err.message?.includes('Not Found')) {
        this.showError(buttonElement, 'TTS not available');
        this.showGlobalError('Voice preview is not available on this server.');
      } else {
        this.showError(buttonElement, 'Network error');
      }
    }
  }

  playAudio(url, buttonElement) {
    if (!this.audioElement) return;

    this.audioElement.src = url;
    this.audioElement.play()
      .then(() => {
        this.setButtonPlaying(buttonElement);
      })
      .catch(err => {
        console.error('Playback failed:', err);
        this.resetButton(buttonElement);
      });
  }

  stopPlayback() {
    if (this.audioElement) {
      this.audioElement.pause();
      this.audioElement.currentTime = 0;
    }
    if (this.currentlyPlaying) {
      this.resetButton(this.currentlyPlaying);
      this.currentlyPlaying = null;
    }
  }

  setButtonLoading(btn) {
    btn.innerHTML = '<span class="loading loading-spinner loading-sm"></span>';
    btn.disabled = true;
  }

  setButtonPlaying(btn) {
    btn.innerHTML = '<i class="bi bi-stop-fill"></i>';
    btn.disabled = false;
    btn.classList.remove('btn-outline');
    btn.classList.add('btn', 'btn-primary');
  }

  resetButton(btn) {
    if (!btn) return;
    btn.innerHTML = '<i class="bi bi-play-fill"></i>';
    btn.disabled = false;
    btn.classList.remove('btn-primary');
    btn.classList.add('btn', 'btn-outline');
  }

  showError(btn, message) {
    this.resetButton(btn);
    btn.classList.add('btn-error');

    // Show error tooltip
    const errorTooltip = document.createElement('div');
    errorTooltip.className = 'voice-preview-error';
    errorTooltip.textContent = message || 'Voice preview unavailable';
    errorTooltip.style.cssText = `
      position: absolute;
      background: #dc3545;
      color: white;
      padding: 4px 8px;
      border-radius: 4px;
      font-size: 12px;
      white-space: nowrap;
      z-index: 1000;
      transform: translateY(-100%);
      margin-top: -4px;
    `;

    // Position near button
    btn.style.position = 'relative';
    btn.appendChild(errorTooltip);

    setTimeout(() => {
      btn.classList.remove('btn-error');
      btn.classList.add('btn-primary');
      errorTooltip.remove();
    }, 3000);
  }

  showGlobalError(message) {
    // Show a global notification that TTS is unavailable
    const alertContainer = document.querySelector('.voice-grid')?.parentElement;
    if (!alertContainer) return;

    // Check if error already shown
    if (alertContainer.querySelector('.tts-error-alert')) return;

    const alert = document.createElement('div');
    alert.className = 'alert alert-warning tts-error-alert mt-3';
    alert.innerHTML = `
      <i class="bi bi-exclamation-triangle mr-2"></i>
      <span>${message || 'Voice preview is currently unavailable. You can still select a voice and configure it.'}</span>
    `;
    alertContainer.appendChild(alert);
  }
}

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
  module.exports = VoicePreviewManager;
}
