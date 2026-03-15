/**
 * MediaSync - Watch2Gether-style media synchronization
 *
 * Features:
 * - Screen/tab sharing via PeerJS WebRTC
 * - YouTube synchronized playback
 * - Host-only controls with viewer sync
 * - Polling-based state synchronization (no WebSocket required)
 */

const MediaSync = (function() {
  'use strict';

  // State
  let peer = null;
  let currentSession = null;
  let isHost = false;
  let connections = new Map();
  let mediaStream = null;
  let youtubePlayer = null;
  let pollInterval = null;
  let heartbeatInterval = null;
  let timeSyncInterval = null;
  let timeDisplayInterval = null;
  let lastEventTimestamp = null;
  let initialized = false;
  let hostBuffering = false;
  let mediaSize = 'small';  // 'small' (100px) or 'large' (half screen)
  let dismissedSessionId = null;  // Prevent auto-rejoin after user closes player

  // Config - Tighter sync for better experience
  const POLL_INTERVAL = 1500;  // 1.5 seconds (was 2)
  const HEARTBEAT_INTERVAL = 30000;  // 30 seconds
  const SYNC_THRESHOLD = 1.5;  // 1.5 seconds of drift before seeking (was 3)
  const TIME_CHECK_INTERVAL = 500;  // Check time every 500ms for viewers

  // PeerJS config (free cloud server)
  const PEER_CONFIG = {
    debug: 1,
    config: {
      iceServers: [
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun1.l.google.com:19302' }
      ]
    }
  };

  // ========================================
  // Initialization
  // ========================================

  function init() {
    if (initialized) return;
    initialized = true;

    // Start polling for media events
    startMediaPoll();

    // Load YouTube IFrame API
    loadYouTubeAPI();

  }

  function updateMediaButtonVisibility(hasSession) {
    const btn = document.getElementById('mediaTrigger');
    if (btn) {
      btn.style.display = hasSession ? 'inline-flex' : 'none';
    }
  }

  function getCharacterInstanceId() {
    const el = document.getElementById('character_instance_id');
    return el ? parseInt(el.textContent, 10) : null;
  }

  function loadYouTubeAPI() {
    if (window.YT) return;

    const tag = document.createElement('script');
    tag.src = 'https://www.youtube.com/iframe_api';
    const firstScript = document.getElementsByTagName('script')[0];
    firstScript.parentNode.insertBefore(tag, firstScript);
  }

  // ========================================
  // Screen/Tab Sharing (Host)
  // ========================================

  async function startScreenShare(shareType, requestAudio) {
    requestAudio = requestAudio !== false && shareType === 'tab';

    try {
      // Get display media (requires user activation in this window)
      const constraints = {
        video: {
          cursor: 'always',
          displaySurface: shareType === 'tab' ? 'browser' : 'monitor'
        },
        audio: requestAudio
      };

      const stream = await navigator.mediaDevices.getDisplayMedia(constraints);

      // Detect if user cancelled
      if (!stream || stream.getTracks().length === 0) {
        throw new Error('Share cancelled');
      }

      await startScreenShareWithStream(stream, shareType);

    } catch (error) {
      console.error('[MediaSync] Screen share error:', error);
      showNotification(`Share failed: ${error.message}`, 'error');
      cleanup();
    }
  }

  // Start a screen share with an already-acquired MediaStream.
  // Called directly by startScreenShare, or from the popout via window.opener
  // when it captures the stream (since getDisplayMedia needs user activation
  // in the window where the click happens).
  async function startScreenShareWithStream(stream, shareType) {
    mediaStream = stream;
    const hasAudio = stream.getAudioTracks().length > 0;

    // Initialize PeerJS
    await initPeer();

    // Register session with server
    const response = await fetch('/api/media/register_share', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
      body: JSON.stringify({
        peer_id: peer.id,
        share_type: shareType,
        has_audio: hasAudio
      })
    });

    const data = await response.json();
    if (!data.success) {
      throw new Error(data.error);
    }

    currentSession = data.session;
    isHost = true;
    updateMediaButtonVisibility(true);

    // Handle stream end
    mediaStream.getVideoTracks()[0].onended = () => {
      stopSharing();
    };

    // Show host UI
    showHostControls();
    showNotification('Screen share started', 'success');

    // Start heartbeat
    startHeartbeat();
  }

  async function initPeer() {
    return new Promise((resolve, reject) => {
      peer = new Peer(undefined, PEER_CONFIG);

      peer.on('open', (id) => {
        resolve(id);
      });

      peer.on('error', (error) => {
        console.error('[MediaSync] Peer error:', error);
        reject(error);
      });

      // Host: handle incoming connections from viewers
      peer.on('call', (call) => {
        if (!isHost || !mediaStream) return;

        call.answer(mediaStream);

        connections.set(call.peer, call);

        call.on('close', () => {
          connections.delete(call.peer);
          updateViewerCount();
        });

        updateViewerCount();
      });
    });
  }

  function stopSharing() {
    if (!isHost) return;

    // End session on server
    if (currentSession) {
      fetch('/api/media/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
        body: JSON.stringify({
          session_id: currentSession.id,
          action: 'end'
        })
      }).catch(e => console.warn('[MediaSync] Error ending session:', e));
    }

    cleanup();
    hideHostControls();
    showNotification('Share ended', 'info');
  }

  function cleanup() {
    // Stop all tracks
    if (mediaStream) {
      mediaStream.getTracks().forEach(track => track.stop());
      mediaStream = null;
    }

    // Close peer connections
    connections.forEach(conn => conn.close());
    connections.clear();

    // Destroy peer
    if (peer) {
      peer.destroy();
      peer = null;
    }

    currentSession = null;
    isHost = false;
    hostBuffering = false;
    updateMediaButtonVisibility(false);

    // Clear intervals
    if (heartbeatInterval) {
      clearInterval(heartbeatInterval);
      heartbeatInterval = null;
    }
    stopViewerTimeSync();
    stopTimeDisplayUpdates();
  }

  function destroy() {
    cleanup();
    if (pollInterval) {
      clearInterval(pollInterval);
      pollInterval = null;
    }
    initialized = false;
  }

  // ========================================
  // Media Size Toggle (Small vs Large)
  // ========================================

  // ========================================
  // Viewer Time Sync (for tighter synchronization)
  // ========================================

  function startViewerTimeSync() {
    if (isHost || timeSyncInterval) return;

    timeSyncInterval = setInterval(() => {
      if (!youtubePlayer || !currentSession?.is_playing || currentSession?.is_buffering) return;

      // Calculate expected position based on server timestamp
      const expectedPosition = calculateExpectedPosition(currentSession);
      if (expectedPosition === null) return;

      const currentTime = youtubePlayer.getCurrentTime();
      const drift = Math.abs(currentTime - expectedPosition);

      if (drift > SYNC_THRESHOLD) {
        youtubePlayer.seekTo(expectedPosition, true);
      }
    }, TIME_CHECK_INTERVAL);
  }

  function stopViewerTimeSync() {
    if (timeSyncInterval) {
      clearInterval(timeSyncInterval);
      timeSyncInterval = null;
    }
  }

  // Calculate expected position based on server timestamp and playback rate
  function calculateExpectedPosition(session) {
    if (!session || !session.playback_started_at) {
      return session?.position || 0;
    }

    const serverTime = new Date(session.playback_started_at).getTime();
    const elapsed = (Date.now() - serverTime) / 1000;
    const rate = session.playback_rate || 1.0;
    return (session.position || 0) + (elapsed * rate);
  }

  // ========================================
  // Viewing Screen Share
  // ========================================

  async function joinScreenShare(session) {
    if (!session.host_peer_id) {
      console.error('[MediaSync] No host peer ID');
      return;
    }

    try {
      await initPeer();
      currentSession = session;

      // Register as viewer
      await fetch('/api/media/join', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
        body: JSON.stringify({
          session_id: session.id,
          peer_id: peer.id
        })
      });

      // Call the host (empty stream to receive only)
      const emptyStream = new MediaStream();
      const call = peer.call(session.host_peer_id, emptyStream);

      call.on('stream', (remoteStream) => {

        // Notify server we're connected
        fetch('/api/media/viewer_connected', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
          body: JSON.stringify({ session_id: session.id })
        });

        showScreenShareViewer(remoteStream, session.has_audio);
      });

      call.on('close', () => {
        hideScreenShareViewer();
        showNotification('Share ended', 'info');
      });

      call.on('error', (error) => {
        console.error('[MediaSync] Call error:', error);
        showNotification('Connection failed', 'error');
      });

    } catch (error) {
      console.error('[MediaSync] Join error:', error);
    }
  }

  function showScreenShareViewer(stream, hasAudio) {
    // Render into #lobserve panel instead of floating widget
    const lobserve = document.getElementById('lobserve');
    let container = document.getElementById('screenShareViewer');
    if (!container) {
      container = document.createElement('div');
      container.id = 'screenShareViewer';
      if (lobserve) {
        lobserve.appendChild(container);
      } else {
        document.body.appendChild(container);
      }
    }

    // Make lobserve visible and hide observe-specific UI
    showLobserveForMedia(lobserve);

    // Hide battle map when media is active
    const battleMap = document.getElementById('battle-map-container');
    if (battleMap) battleMap.classList.add('hidden');

    // Detect if this is audio-only (no video tracks)
    const hasVideo = stream.getVideoTracks().length > 0;

    const hostName = currentSession?.host_name || 'Someone';
    const noAudioBadge = !hasAudio ? '<span class="no-audio-badge">No Audio</span>' : '';
    const waveformHtml = hasAudio ? `
      <div class="audio-waveform">
        <span class="bar"></span><span class="bar"></span><span class="bar"></span><span class="bar"></span><span class="bar"></span>
      </div>
    ` : '';

    container.className = 'media-lobserve-player';
    container.innerHTML = `
      <div class="media-widget-header">
        <div class="media-widget-info">
          <span class="host-name">${hostName}</span>
          <span class="media-title">Screen Share</span>
          <span class="viewer-count"><span id="shareViewerCount">0</span> viewers</span>
          ${noAudioBadge}
        </div>
        <div class="media-widget-play-state playing">
          ${waveformHtml}
        </div>
        <div class="media-widget-controls">
          <button class="media-widget-btn close-btn" onclick="MediaSync.leaveViewer()" title="Close">&times;</button>
        </div>
      </div>
      <video id="screenShareVideo" autoplay playsinline></video>
    `;

    const video = document.getElementById('screenShareVideo');
    video.srcObject = stream;
    video.muted = !hasAudio;
    container.style.display = 'flex';
  }

  function notifyViewerDisconnected(sessionId) {
    if (!sessionId) return;
    fetch('/api/media/viewer_disconnected', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
      body: JSON.stringify({ session_id: sessionId })
    }).catch(() => {});
  }

  function hideScreenShareViewer(sessionIdOverride) {
    const container = document.getElementById('screenShareViewer');
    if (container) {
      const video = document.getElementById('screenShareVideo');
      if (video) video.srcObject = null;
      container.remove();
    }

    const sessionId = sessionIdOverride || (currentSession ? currentSession.id : null);
    notifyViewerDisconnected(sessionId);

    restoreBattleMap();
  }

  function leaveViewer() {
    const sessionId = currentSession ? currentSession.id : null;

    // Remember this session so polling doesn't auto-rejoin it
    if (sessionId) {
      dismissedSessionId = sessionId;
    }
    hideScreenShareViewer(sessionId);
    cleanup();
    hideYouTubePlayer();
  }

  // ========================================
  // YouTube Sync (Host)
  // ========================================

  async function startYouTubeSync(videoId, title, duration) {
    try {
      const response = await fetch('/api/media/youtube', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
        body: JSON.stringify({ video_id: videoId, title: title, duration: duration })
      });

      const data = await response.json();
      if (!data.success) throw new Error(data.error);

      currentSession = data.session;
      isHost = true;
      updateMediaButtonVisibility(true);

      showYouTubePlayer(videoId, true, data.session);
      showNotification('Watch party started!', 'success');
      startHeartbeat();

    } catch (error) {
      showNotification(`Failed: ${error.message}`, 'error');
    }
  }

  function showYouTubePlayer(videoId, asHost, session) {
    // Use provided session data, fall back to currentSession
    const sessionData = session || currentSession;

    // Render into #lobserve panel instead of floating widget
    const lobserve = document.getElementById('lobserve');
    let container = document.getElementById('youtubeSyncPlayer');
    if (!container) {
      container = document.createElement('div');
      container.id = 'youtubeSyncPlayer';
      if (lobserve) {
        lobserve.appendChild(container);
      } else {
        document.body.appendChild(container);
      }
    }

    // Make lobserve visible and hide observe-specific UI
    showLobserveForMedia(lobserve);

    // Hide battle map when media is active
    const battleMap = document.getElementById('battle-map-container');
    if (battleMap) battleMap.classList.add('hidden');

    const hostName = sessionData?.host_name || 'Someone';
    const videoTitle = sessionData?.youtube_title || 'Video';
    const hostBadge = asHost ? '<span class="ysp-badge">HOST</span>' : '';
    const sizeIcon = mediaSize === 'small' ? '&#9650;' : '&#9660;';  // ▲ or ▼

    container.className = 'media-lobserve-player';
    container.innerHTML = `
      <div class="media-widget-header">
        <div class="media-widget-info">
          <span class="host-name">${hostName}</span>
          ${hostBadge}
          <span class="media-title" title="${videoTitle}">${videoTitle}</span>
        </div>
        <div class="media-widget-controls">
          <button class="media-widget-btn toggle-btn" onclick="MediaSync.toggleSize()" title="Toggle size" id="mediaSizeToggle">${sizeIcon}</button>
          <button class="media-widget-btn close-btn" onclick="MediaSync.closeYouTube()" title="Close">&times;</button>
        </div>
      </div>
      <div id="ytPlayerContainer"></div>
    `;

    container.style.display = 'flex';

    // Apply current size class to lobserve
    applyMediaSize(lobserve);

    // Create YouTube player when API is ready
    if (window.YT && window.YT.Player) {
      createYTPlayer(videoId, asHost);
    } else {
      window.onYouTubeIframeAPIReady = () => createYTPlayer(videoId, asHost);
    }
  }

  function createYTPlayer(videoId, asHost) {
    const playerDiv = document.getElementById('ytPlayerContainer');
    if (!playerDiv) return;

    youtubePlayer = new YT.Player('ytPlayerContainer', {
      height: '100%',
      width: '100%',
      videoId: videoId,
      playerVars: {
        'autoplay': asHost ? 1 : 0,
        'controls': 1,
        'modestbranding': 1,
        'rel': 0
      },
      events: {
        'onReady': asHost ? onPlayerReady : onViewerPlayerReady,
        'onStateChange': asHost ? onHostStateChange : onViewerStateChange,
        'onPlaybackRateChange': asHost ? onHostRateChange : null,
        'onError': onPlayerError
      }
    });
  }

  function onPlayerError(event) {
    const code = event.data;
    const messages = {
      2: 'Invalid video ID',
      5: 'Video cannot be played in HTML5',
      100: 'Video not found or removed',
      101: 'Video owner does not allow embedding',
      150: 'Video owner does not allow embedding'
    };
    const msg = messages[code] || `YouTube error (code ${code})`;
    console.error('[MediaSync] YouTube player error:', code, msg);
    showNotification(msg, 'error');

    // Clean up the broken player
    hideYouTubePlayer();
  }

  function startTimeDisplayUpdates() {
    if (timeDisplayInterval) return;
    timeDisplayInterval = setInterval(updateTimeDisplay, 1000);
  }

  function stopTimeDisplayUpdates() {
    if (timeDisplayInterval) {
      clearInterval(timeDisplayInterval);
      timeDisplayInterval = null;
    }
  }

  // Viewer-specific player ready handler
  function onViewerPlayerReady(event) {
    // Check start muted preference
    const wrapper = document.getElementById('clientwrapper');
    const startMuted = wrapper && wrapper.dataset.mediaStartMuted === 'true';
    if (startMuted && youtubePlayer) {
      youtubePlayer.mute();
    }

    // Sync to current position if joining
    if (currentSession) {
      const pos = calculateExpectedPosition(currentSession);
      youtubePlayer.seekTo(pos, true);

      // Sync playback rate
      if (currentSession.playback_rate && currentSession.playback_rate !== 1) {
        youtubePlayer.setPlaybackRate(currentSession.playback_rate);
      }

      if (currentSession.is_playing && !currentSession.is_buffering) {
        youtubePlayer.playVideo();
      }
    }

    // Start tighter time sync for viewers
    startViewerTimeSync();

    // Update time display periodically
    startTimeDisplayUpdates();
  }

  function onPlayerReady(event) {
    if (isHost) {
      // Host: explicitly play (autoplay can be unreliable across browsers)
      if (currentSession) {
        const pos = currentSession.position || 0;
        if (pos > 1) {
          youtubePlayer.seekTo(pos, true);
        }
      }
      youtubePlayer.playVideo();
    } else if (currentSession) {
      // Viewer: sync to current position
      const pos = calculateExpectedPosition(currentSession);
      youtubePlayer.seekTo(pos, true);
      if (currentSession.is_playing) {
        youtubePlayer.playVideo();
      }
    }

    // Update time display periodically
    startTimeDisplayUpdates();
  }

  function onHostStateChange(event) {
    if (!isHost) return;

    const state = event.data;
    const currentTime = youtubePlayer.getCurrentTime();

    switch (state) {
      case YT.PlayerState.PLAYING:
        hostBuffering = false;
        sendControlAction('play', { position: currentTime });
        break;
      case YT.PlayerState.PAUSED:
        // Only send pause if we weren't buffering (buffering often triggers pause first)
        if (!hostBuffering) {
          sendControlAction('pause', { position: currentTime });
        }
        break;
      case YT.PlayerState.BUFFERING:
        hostBuffering = true;
        sendControlAction('buffering', { position: currentTime });
        break;
      case YT.PlayerState.ENDED:
        // Check if session has a playlist — advance to next track
        if (currentSession && currentSession.playlist_id) {
          advancePlaylist();
        } else {
          sendControlAction('end');
        }
        break;
    }
  }

  // Handle playback rate changes from host
  function onHostRateChange(event) {
    if (!isHost) return;

    const newRate = event.data;
    sendControlAction('rate', { playback_rate: newRate });
  }

  // Advance to next track in playlist
  async function advancePlaylist() {
    if (!currentSession || !currentSession.playlist_id) return;

    try {
      const resp = await fetch('/api/media/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
        body: JSON.stringify({
          session_id: currentSession.id,
          action: 'next_track'
        })
      });
      const data = await resp.json();

      if (data.success && data.session) {
        // Load next video
        currentSession = data.session;
        if (youtubePlayer && youtubePlayer.loadVideoById) {
          youtubePlayer.loadVideoById(data.session.youtube_video_id);
        }
        showNotification(`Now playing: ${data.session.youtube_title || 'Next track'}`, 'info');
      } else {
        // End of playlist
        showNotification('Playlist finished', 'info');
        sendControlAction('end');
      }
    } catch (e) {
      console.error('[MediaSync] Playlist advance error:', e);
      sendControlAction('end');
    }
  }

  // Viewer state change - mainly for sync status
  function onViewerStateChange(event) {
    // Viewers don't control playback, but we can log for debugging
  }

  async function sendControlAction(action, extra) {
    extra = extra || {};
    if (!currentSession) return;

    await fetch('/api/media/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
      body: JSON.stringify({
        session_id: currentSession.id,
        action: action,
        ...extra
      })
    });
  }

  // Host control functions
  function ytPlay() {
    if (!youtubePlayer) return;
    youtubePlayer.playVideo();
  }

  function ytPause() {
    if (!youtubePlayer) return;
    youtubePlayer.pauseVideo();
  }

  function ytSeek(percent) {
    if (!youtubePlayer || !currentSession) return;
    const duration = currentSession.youtube_duration || youtubePlayer.getDuration();
    const position = (percent / 100) * duration;
    youtubePlayer.seekTo(position, true);
    sendControlAction('seek', { position: position });
  }

  function updateTimeDisplay() {
    if (!youtubePlayer || !youtubePlayer.getCurrentTime) return;

    const current = Math.floor(youtubePlayer.getCurrentTime());
    const duration = Math.floor(youtubePlayer.getDuration() || 0);

    const formatTime = (s) => {
      const mins = Math.floor(s / 60);
      const secs = s % 60;
      return `${mins}:${secs.toString().padStart(2, '0')}`;
    };

    const display = document.getElementById('ytTimeDisplay');
    if (display) {
      display.textContent = `${formatTime(current)} / ${formatTime(duration)}`;
    }

    const seekBar = document.getElementById('ytSeekBar');
    if (seekBar && duration > 0 && isHost) {
      seekBar.value = (current / duration) * 100;
    }
  }

  function closeYouTube() {
    // Remember this session so polling doesn't auto-rejoin it
    if (currentSession) {
      dismissedSessionId = currentSession.id;

      // End session on server BEFORE cleanup nulls currentSession
      if (isHost) {
        fetch('/api/media/control', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': getCsrfToken() },
          body: JSON.stringify({ session_id: currentSession.id, action: 'end' })
        }).catch(e => console.warn('[MediaSync] Error ending session:', e));
      }
    }
    cleanup();
    hideYouTubePlayer();
  }

  function hideYouTubePlayer() {
    const container = document.getElementById('youtubeSyncPlayer');
    if (container) {
      container.remove();
    }
    if (youtubePlayer) {
      youtubePlayer.destroy();
      youtubePlayer = null;
    }
    stopTimeDisplayUpdates();
    restoreBattleMap();
  }

  // Apply the current media size class to lobserve
  function applyMediaSize(lobserve) {
    if (!lobserve) lobserve = document.getElementById('lobserve');
    if (!lobserve) return;
    lobserve.classList.remove('media-size-small', 'media-size-large');
    lobserve.classList.add(mediaSize === 'large' ? 'media-size-large' : 'media-size-small');
    // Update toggle button icon
    const btn = document.getElementById('mediaSizeToggle');
    if (btn) btn.innerHTML = mediaSize === 'small' ? '&#9650;' : '&#9660;';
  }

  function toggleSize() {
    mediaSize = mediaSize === 'small' ? 'large' : 'small';
    applyMediaSize();
  }

  // Make the lobserve panel visible for media content
  function showLobserveForMedia(lobserve) {
    if (!lobserve) return;
    // Hide the observe-specific header (title + close button)
    const header = lobserve.querySelector('.lobserve-header');
    if (header) header.style.display = 'none';
    const content = lobserve.querySelector('.lobserve-content');
    if (content) content.style.display = 'none';

    lobserve.classList.add('visible');
    lobserve.classList.add('media-active');
    applyMediaSize(lobserve);
  }

  // Hide the lobserve panel when media is done
  function hideLobserveForMedia() {
    const lobserve = document.getElementById('lobserve');
    if (!lobserve) return;

    lobserve.classList.remove('media-active', 'media-size-small', 'media-size-large');

    // Only hide lobserve entirely if there's no other observe content active
    const hasObserveContent = lobserve.querySelector('.lobserve-content')?.innerHTML?.trim();
    if (!hasObserveContent) {
      lobserve.classList.remove('visible');
    } else {
      // Restore the observe header
      const header = lobserve.querySelector('.lobserve-header');
      if (header) header.style.display = '';
      const content = lobserve.querySelector('.lobserve-content');
      if (content) content.style.display = '';
    }
  }

  function restoreBattleMap() {
    // Hide lobserve media state
    hideLobserveForMedia();

    // Re-show battle map if a fight is active
    const battleMap = document.getElementById('battle-map-container');
    const battleSvg = document.getElementById('battle-map');
    if (battleMap && battleSvg && !battleSvg.classList.contains('hidden')) {
      battleMap.classList.remove('hidden');
    }
  }

  // ========================================
  // Polling for Session Updates
  // ========================================

  function startMediaPoll() {
    pollInterval = setInterval(async () => {
      try {
        // Get current session
        const sessionRes = await fetch('/api/media/session');
        const sessionData = await sessionRes.json();

        if (sessionData.success && sessionData.session) {
          handleSessionUpdate(sessionData.session);
        } else if (currentSession) {
          // Session gone from server — clean up regardless of host status
          handleSessionEnded();
        }

        // Get events
        const eventsRes = await fetch(`/api/media/events?since=${lastEventTimestamp || ''}`);
        const eventsData = await eventsRes.json();

        if (eventsData.success && eventsData.events) {
          eventsData.events.forEach(handleMediaEvent);
          lastEventTimestamp = eventsData.timestamp;
        }

      } catch (error) {
        // Silently fail - polling will retry
      }
    }, POLL_INTERVAL);
  }

  function handleSessionUpdate(session) {
    // Update media toolbar button visibility
    updateMediaButtonVisibility(!!session);

    // Check if we're the host of this session (e.g. started from popout)
    const myInstanceId = getCharacterInstanceId();
    const amHost = session && myInstanceId && session.host_id === myInstanceId;

    // If user dismissed this session, don't auto-rejoin
    // (the "Open Player" button uses media_open_player event to force-reopen)
    if (session && dismissedSessionId === session.id) {
      return;
    }

    // Clear dismissed state if a genuinely different session has started
    if (session && dismissedSessionId && dismissedSessionId !== session.id) {
      dismissedSessionId = null;
    }

    // New session started?
    if (!currentSession && session) {
      if (amHost) {
        // We started this session (from popout or command) — take host role
        isHost = true;
        currentSession = session;
        showYouTubePlayer(session.youtube_video_id, true, session);
        startHeartbeat();
      } else {
        currentSession = session;
        showSessionNotification(session);
      }
      return;
    }

    // Update current session data
    if (currentSession && session && currentSession.id === session.id) {
      currentSession = session;

      // Update header text dynamically (fixes "Someone Video" after reload)
      updatePlayerHeader(session);

      // Sync playback for YouTube viewers only — never for host
      if (!isHost && session.type === 'youtube' && youtubePlayer) {
        syncYouTubePlayback(session);
      }

      // Update viewer count
      const countEl = document.getElementById('ytViewerCount') || document.getElementById('shareViewerCount');
      if (countEl) {
        countEl.textContent = `${session.viewer_count} viewer${session.viewer_count !== 1 ? 's' : ''}`;
      }
    }
  }

  // Update player header text from session data
  function updatePlayerHeader(session) {
    if (!session) return;
    const container = document.getElementById('youtubeSyncPlayer') || document.getElementById('screenShareViewer');
    if (!container) return;

    const hostNameEl = container.querySelector('.host-name');
    const titleEl = container.querySelector('.media-title');

    if (hostNameEl && session.host_name) {
      hostNameEl.textContent = session.host_name;
    }
    if (titleEl && session.youtube_title) {
      titleEl.textContent = session.youtube_title;
      titleEl.title = session.youtube_title;
    }
  }

  function showSessionNotification(session) {
    // Don't auto-join a session the user already dismissed
    if (session && dismissedSessionId === session.id) {
      return;
    }

    // Check auto-join preference
    const wrapper = document.getElementById('clientwrapper');
    const autoplay = wrapper && wrapper.dataset.mediaAutoplay !== 'false';

    if (autoplay) {
      // Auto-join the session
      if (session.type === 'youtube') {
        showYouTubePlayer(session.youtube_video_id, false, session);
        showNotification(`Auto-joined ${session.host_name || 'someone'}'s watch party`, 'info');
      } else {
        showNotification(`${session.host_name || 'Someone'} is sharing their screen. Type "join video" to watch.`, 'info');
      }
    } else {
      if (session.type === 'youtube') {
        showNotification(`Watch party started by ${session.host_name || 'someone'}! Type "join video" to watch.`, 'info');
      } else {
        showNotification(`${session.host_name || 'Someone'} is sharing their screen.`, 'info');
      }
    }
  }

  function syncYouTubePlayback(session) {
    // Double-check: NEVER sync for hosts — host controls their own player
    if (isHost) return;
    if (!youtubePlayer || !youtubePlayer.getPlayerState) return;

    const playerState = youtubePlayer.getPlayerState();

    // Handle buffering state from host
    if (session.is_buffering) {
      showBufferingIndicator(true);
      if (playerState === YT.PlayerState.PLAYING) {
        youtubePlayer.pauseVideo();
      }
      return;
    }

    showBufferingIndicator(false);

    // Sync playback rate first
    const targetRate = session.playback_rate || 1;
    const currentRate = youtubePlayer.getPlaybackRate();
    if (currentRate !== targetRate) {
      youtubePlayer.setPlaybackRate(targetRate);
    }

    // Calculate expected position accounting for server timestamp and rate
    const targetTime = calculateExpectedPosition(session);
    const currentTime = youtubePlayer.getCurrentTime();

    // Sync if drift > threshold
    if (Math.abs(currentTime - targetTime) > SYNC_THRESHOLD) {
      youtubePlayer.seekTo(targetTime, true);
    }

    // Sync play/pause state
    if (session.is_playing && playerState !== YT.PlayerState.PLAYING) {
      youtubePlayer.playVideo();
    } else if (!session.is_playing && playerState === YT.PlayerState.PLAYING) {
      youtubePlayer.pauseVideo();
    }

  }

  // Show/hide buffering indicator overlay
  function showBufferingIndicator(show) {
    let indicator = document.getElementById('ytBufferingIndicator');

    if (show && !indicator) {
      indicator = document.createElement('div');
      indicator.id = 'ytBufferingIndicator';
      indicator.className = 'yt-buffering-indicator';
      indicator.innerHTML = '<span class="spinner"></span> Host buffering...';
      const container = document.getElementById('youtubeSyncPlayer');
      if (container) {
        container.appendChild(indicator);
      }
    } else if (!show && indicator) {
      indicator.remove();
    }
  }

  function handleSessionEnded() {
    cleanup();
    hideScreenShareViewer();
    hideYouTubePlayer();
    hideHostControls();
    showNotification('Media session ended', 'info');
  }

  function handleMediaEvent(event) {

    switch (event.type) {
      case 'media_session_started':
        if (!currentSession && event.session) {
          // Check if we're the host (started from popout)
          const myId = getCharacterInstanceId();
          const amEventHost = myId && event.session.host_id === myId;

          // Hosts bypass dismissedSessionId; viewers respect it
          if (!amEventHost && dismissedSessionId === event.session.id) break;

          if (amEventHost) {
            isHost = true;
            currentSession = event.session;
            dismissedSessionId = null;
            if (event.session.type === 'youtube') {
              showYouTubePlayer(event.session.youtube_video_id, true, event.session);
              startHeartbeat();
            }
          } else {
            currentSession = event.session;
            showSessionNotification(event.session);
          }
        }
        break;
      case 'media_session_ended':
        handleSessionEnded();
        break;
      case 'media_playback_update':
        if (!isHost && currentSession) {
          handleSessionUpdate(event.session);
        }
        break;
      case 'media_open_player':
        // Backend signal to open the player for everyone in the room
        if (event.session) {
          dismissedSessionId = null;  // Force clear any dismissal
          const myId = getCharacterInstanceId();
          const amOpenHost = myId && event.session.host_id === myId;

          if (!currentSession || currentSession.id !== event.session.id) {
            // Not currently tracking this session — join it
            currentSession = event.session;
            if (amOpenHost) {
              isHost = true;
              startHeartbeat();
            }
          }

          // Open the player if not already visible
          if (!document.getElementById('youtubeSyncPlayer') && event.session.type === 'youtube') {
            showYouTubePlayer(event.session.youtube_video_id, amOpenHost, event.session);
          }
          if (!document.getElementById('screenShareViewer') && event.session.type !== 'youtube') {
            joinScreenShare(event.session);
          }
        }
        break;
      case 'share_requested': {
        // Popout requested a screen/tab share — only the requester's webclient should act.
        // getDisplayMedia requires transient user activation, so we show a prompt
        // that the user clicks to provide the gesture.
        const myShareId = getCharacterInstanceId();
        if (myShareId && event.requester_id === myShareId) {
          showSharePrompt(event.share_type, event.request_audio);
        }
        break;
      }
    }
  }

  // ========================================
  // Heartbeat
  // ========================================

  function startHeartbeat() {
    if (heartbeatInterval) return;
    heartbeatInterval = setInterval(() => {
      fetch('/api/media/heartbeat', { method: 'POST', headers: { 'X-CSRF-Token': getCsrfToken() } })
        .catch(() => {});
    }, HEARTBEAT_INTERVAL);
  }

  // ========================================
  // Host UI
  // ========================================

  function showHostControls() {
    let controls = document.getElementById('shareHostControls');
    if (!controls) {
      controls = document.createElement('div');
      controls.id = 'shareHostControls';
      controls.className = 'share-host-controls';
      controls.innerHTML = `
        <span class="shc-badge">SHARING</span>
        <span id="shareViewerCount">0 viewers</span>
        <button onclick="MediaSync.stopSharing()" class="shc-stop">Stop</button>
      `;
      document.body.appendChild(controls);
    }
    controls.style.display = 'flex';
  }

  function hideHostControls() {
    const controls = document.getElementById('shareHostControls');
    if (controls) controls.style.display = 'none';
  }

  function updateViewerCount() {
    const count = connections.size;
    const el = document.getElementById('shareViewerCount');
    if (el) el.textContent = `${count} viewer${count !== 1 ? 's' : ''}`;
  }

  // ========================================
  // Notifications
  // ========================================

  function showSharePrompt(shareType, requestAudio) {
    // getDisplayMedia requires transient user activation (a real click).
    // Show a dialog the user clicks to provide that gesture.
    const label = shareType === 'tab' ? 'Browser Tab' : 'Screen';
    const existing = document.getElementById('sharePromptOverlay');
    if (existing) existing.remove();

    const overlay = document.createElement('div');
    overlay.id = 'sharePromptOverlay';
    overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.7);z-index:99999;display:flex;align-items:center;justify-content:center;';
    overlay.innerHTML = `
      <div style="background:#1d232a;border:1px solid rgba(255,255,255,0.15);border-radius:12px;padding:2rem;text-align:center;max-width:360px;">
        <i class="bi bi-display" style="font-size:2.5rem;color:#36d399;"></i>
        <h3 style="color:#fff;margin:1rem 0 0.5rem;">Share ${label}</h3>
        <p style="color:#a6adbb;font-size:0.9rem;margin-bottom:1.5rem;">Click the button below to choose what to share. Your browser will ask for permission.</p>
        <button id="sharePromptBtn" style="background:#36d399;color:#000;border:none;padding:0.6rem 1.5rem;border-radius:8px;font-weight:600;cursor:pointer;font-size:1rem;">
          Start Sharing
        </button>
        <button id="sharePromptCancel" style="background:transparent;color:#a6adbb;border:1px solid rgba(255,255,255,0.15);padding:0.6rem 1.5rem;border-radius:8px;cursor:pointer;font-size:0.9rem;margin-left:0.5rem;">
          Cancel
        </button>
      </div>
    `;
    document.body.appendChild(overlay);

    document.getElementById('sharePromptBtn').addEventListener('click', () => {
      overlay.remove();
      startScreenShare(shareType, requestAudio);
    });
    document.getElementById('sharePromptCancel').addEventListener('click', () => {
      overlay.remove();
    });
  }

  function showNotification(message, type) {
    // Use showImprint if available (Firefly webclient)
    if (typeof showImprint === 'function') {
      const icon = type === 'error' ? '!' : type === 'success' ? '+' : '*';
      showImprint(message, 3000, icon);
    } else {
    }
  }

  // ========================================
  // Command Response Handler
  // ========================================

  function handleMediaAction(data) {
    if (!data || !data.action) return;

    switch (data.action) {
      case 'start_screen_share':
        startScreenShare(data.share_type, false);
        break;
      case 'start_tab_share':
        startScreenShare('tab', data.request_audio);
        break;
      case 'start_youtube_sync':
        if (data.is_host) {
          currentSession = data.session;
          isHost = true;
          updateMediaButtonVisibility(true);
          showYouTubePlayer(data.video_id, true, data.session);
          startHeartbeat();
        }
        break;
      case 'stop_share':
        cleanup();
        hideHostControls();
        break;
    }
  }

  // ========================================
  // Join Session (for viewers)
  // ========================================

  async function joinSession() {
    if (!currentSession) {
      // Check for active session
      const response = await fetch('/api/media/session');
      const data = await response.json();

      if (!data.success || !data.session) {
        showNotification('No active session to join', 'error');
        return;
      }

      currentSession = data.session;
    }

    // Clear dismissed state so the player stays open
    dismissedSessionId = null;

    // Detect if we're the host
    const myInstanceId = getCharacterInstanceId();
    const amHost = myInstanceId && currentSession.host_id === myInstanceId;
    if (amHost) {
      isHost = true;
      startHeartbeat();
    }

    if (currentSession.type === 'youtube') {
      showYouTubePlayer(currentSession.youtube_video_id, amHost, currentSession);
    } else {
      await joinScreenShare(currentSession);
    }
  }

  // ========================================
  // Public API
  // ========================================

  return {
    init: init,
    startScreenShare: startScreenShare,
    startScreenShareWithStream: startScreenShareWithStream,
    startYouTubeSync: startYouTubeSync,
    stopSharing: stopSharing,
    joinScreenShare: joinScreenShare,
    joinSession: joinSession,
    leaveViewer: leaveViewer,
    closeYouTube: closeYouTube,
    ytPlay: ytPlay,
    ytPause: ytPause,
    ytSeek: ytSeek,
    handleMediaAction: handleMediaAction,
    toggleSize: toggleSize,
    getCurrentSession: function() { return currentSession; },
    isHost: function() { return isHost; },
    destroy: destroy
  };
})();

// Initialize when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', MediaSync.init);
} else {
  MediaSync.init();
}
