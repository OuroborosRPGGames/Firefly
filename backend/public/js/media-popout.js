/**
 * MediaPopout - Media control popout window manager
 *
 * Pure API client: manages YouTube video queue, playlists, library,
 * room sessions, and user preferences via backend API calls.
 * The webclient discovers session changes through its existing polling.
 */
class MediaPopout {
  constructor(container, characterId, options = {}) {
    this.container = container;
    this.characterId = characterId;
    this.characterInstanceId = parseInt(container.dataset.characterInstanceId) || null;
    this.options = { popout: false, ...options };

    this.queue = [];
    this.playlists = [];
    this.library = [];
    this.currentPreview = null;
    this.roomPollInterval = null;
    this._shareSessionId = null;

    this.init();
  }

  async init() {
    this.loadInitialData();
    this.loadYouTubeAPI();
    this.bindTabs();
    this.bindYouTubeTab();
    this.bindShareTab();
    this.bindPlaylistsTab();
    this.bindRoomTab();
    this.bindSettingsTab();
    this.loadLibrary();
  }

  // Build API URL with character_instance_id for multi-character support
  apiUrl(path) {
    const sep = path.includes('?') ? '&' : '?';
    return this.characterInstanceId
      ? `${path}${sep}character_instance_id=${this.characterInstanceId}`
      : path;
  }

  // Fetch wrapper that includes character_instance_id in query string
  // (request.params only reads query string, not JSON body)
  apiFetch(path, options = {}) {
    const method = (options.method || 'GET').toUpperCase();
    if (method !== 'GET' && method !== 'HEAD') {
      options.headers = { ...options.headers, 'X-CSRF-Token': getCsrfToken() };
    }
    return fetch(this.apiUrl(path), options);
  }

  loadYouTubeAPI() {
    if (window.YT) return;
    const tag = document.createElement('script');
    tag.src = 'https://www.youtube.com/iframe_api';
    const firstScript = document.getElementsByTagName('script')[0];
    firstScript.parentNode.insertBefore(tag, firstScript);
  }

  // ========================================
  // Data Loading
  // ========================================

  loadInitialData() {
    try {
      const raw = this.container.dataset.playlists;
      this.playlists = raw ? JSON.parse(raw) : [];
    } catch (e) {
      this.playlists = [];
    }
  }

  // ========================================
  // Tab Switching
  // ========================================

  bindTabs() {
    const tabs = this.container.querySelectorAll('#mediaTabs .tab');
    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('tab-active'));
        tab.classList.add('tab-active');

        this.container.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
        const panel = this.container.querySelector(`#panel-${tab.dataset.tab}`);
        if (panel) panel.classList.add('active');
      });
    });
  }

  // ========================================
  // YouTube Tab
  // ========================================

  bindYouTubeTab() {
    const urlInput = document.getElementById('youtubeUrlInput');
    const addBtn = document.getElementById('addVideoBtn');
    const clearBtn = document.getElementById('clearQueueBtn');
    const playBtn = document.getElementById('playQueueBtn');
    const discardBtn = document.getElementById('previewDiscard');
    const saveLibBtn = document.getElementById('previewSaveLibrary');

    addBtn.addEventListener('click', () => this.lookupVideo(urlInput.value));
    urlInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') this.lookupVideo(urlInput.value);
    });

    clearBtn.addEventListener('click', () => {
      this.queue = [];
      this.renderQueue();
    });

    playBtn.addEventListener('click', () => this.playQueue());

    discardBtn.addEventListener('click', () => {
      this.currentPreview = null;
      document.getElementById('videoPreview').classList.add('hidden');
    });

    saveLibBtn.addEventListener('click', () => {
      if (this.currentPreview) this.saveToLibrary(this.currentPreview);
    });
  }

  async lookupVideo(url) {
    if (!url || !url.trim()) return;

    const addBtn = document.getElementById('addVideoBtn');
    const origHtml = addBtn.innerHTML;
    addBtn.innerHTML = '<span class="media-loading"></span>';
    addBtn.disabled = true;

    try {
      const resp = await this.apiFetch('/api/media/youtube/info', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url.trim() })
      });
      if (!resp.ok) {
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();

      if (!data.success) {
        this.showToast(data.error || 'Could not fetch video info', 'danger');
        return;
      }

      // Test embeddability with a hidden YouTube player
      const embedResult = await this.testEmbeddability(data.video.video_id);
      data.video.is_embeddable = embedResult;

      this.currentPreview = data.video;
      this.showPreview(data.video);

      if (!embedResult) {
        this.showToast('This video cannot be embedded — the owner has restricted playback on other sites.', 'warning');
        // Don't add to queue
        return;
      }

      // Add to queue immediately
      this.addToQueue(data.video);

      document.getElementById('youtubeUrlInput').value = '';
    } catch (err) {
      this.showToast('Error looking up video', 'danger');
    } finally {
      addBtn.innerHTML = origHtml;
      addBtn.disabled = false;
    }
  }

  /**
   * Test if a YouTube video can be embedded by creating a tiny hidden player.
   * Returns true if embeddable, false if restricted (error codes 101/150).
   *
   * YouTube's onReady fires when the iframe loads (before video loads),
   * so we must wait for either onError or onStateChange to confirm playability.
   */
  testEmbeddability(videoId) {
    return new Promise((resolve) => {
      const tryTest = () => {
        let testDiv = document.getElementById('embedTestContainer');
        if (!testDiv) {
          testDiv = document.createElement('div');
          testDiv.id = 'embedTestContainer';
          testDiv.style.cssText = 'position:absolute;left:-9999px;top:-9999px;width:1px;height:1px;overflow:hidden;';
          document.body.appendChild(testDiv);
        }

        const playerDiv = document.createElement('div');
        playerDiv.id = 'embedTestPlayer_' + Date.now();
        testDiv.innerHTML = '';
        testDiv.appendChild(playerDiv);

        let resolved = false;
        let testPlayer;

        // Timeout: assume embeddable if no error fires within 4 seconds
        const timeout = setTimeout(() => {
          if (!resolved) {
            resolved = true;
            cleanupTestPlayer();
            resolve(true);
          }
        }, 4000);

        const cleanupTestPlayer = () => {
          clearTimeout(timeout);
          try {
            if (testPlayer && testPlayer.destroy) testPlayer.destroy();
          } catch (e) { /* ignore */ }
          if (testDiv) testDiv.innerHTML = '';
        };

        try {
          testPlayer = new YT.Player(playerDiv.id, {
            height: '1',
            width: '1',
            videoId: videoId,
            playerVars: { autoplay: 1, controls: 0, mute: 1 },
            events: {
              onStateChange: (event) => {
                // PLAYING or BUFFERING means the video loaded — it's embeddable
                if (!resolved && (event.data === YT.PlayerState.PLAYING || event.data === YT.PlayerState.BUFFERING)) {
                  resolved = true;
                  cleanupTestPlayer();
                  resolve(true);
                }
              },
              onError: (event) => {
                if (!resolved) {
                  resolved = true;
                  cleanupTestPlayer();
                  // 101 and 150 = embedding restricted, 100 = not found
                  resolve(event.data !== 101 && event.data !== 150 && event.data !== 100);
                }
              }
            }
          });
        } catch (e) {
          if (!resolved) {
            resolved = true;
            resolve(true);
          }
        }
      };

      if (window.YT && window.YT.Player) {
        tryTest();
      } else {
        const origCallback = window.onYouTubeIframeAPIReady;
        window.onYouTubeIframeAPIReady = () => {
          if (origCallback) origCallback();
          tryTest();
        };
      }
    });
  }

  showPreview(video) {
    const el = document.getElementById('videoPreview');
    el.classList.remove('hidden');

    document.getElementById('previewThumb').src =
      video.thumbnail_url || `https://img.youtube.com/vi/${video.video_id}/mqdefault.jpg`;
    document.getElementById('previewTitle').textContent = video.title || 'Untitled';
    document.getElementById('previewDuration').textContent = this.formatDuration(video.duration_seconds);
    document.getElementById('previewVideoId').textContent = video.video_id;

    const embedBadge = document.getElementById('previewEmbed');
    if (video.is_embeddable) {
      embedBadge.className = 'badge badge-sm badge-success';
      embedBadge.innerHTML = '<i class="bi bi-check-lg mr-1"></i>Embeddable';
    } else {
      embedBadge.className = 'badge badge-sm badge-error';
      embedBadge.innerHTML = '<i class="bi bi-x-lg mr-1"></i>Not embeddable';
    }
  }

  // ========================================
  // Queue Management
  // ========================================

  addToQueue(video) {
    this.queue.push({
      youtube_video_id: video.video_id,
      title: video.title || 'Untitled',
      thumbnail_url: video.thumbnail_url || `https://img.youtube.com/vi/${video.video_id}/mqdefault.jpg`,
      duration_seconds: video.duration_seconds,
      is_embeddable: video.is_embeddable !== false
    });
    this.renderQueue();
  }

  removeFromQueue(index) {
    this.queue.splice(index, 1);
    this.renderQueue();
  }

  renderQueue() {
    const list = document.getElementById('queueList');
    const countBadge = document.getElementById('queueCount');
    const playBtn = document.getElementById('playQueueBtn');

    countBadge.textContent = this.queue.length;
    playBtn.disabled = this.queue.length === 0;

    if (this.queue.length === 0) {
      list.innerHTML = `
        <div class="media-queue-empty text-center py-8 text-base-content/30">
          <i class="bi bi-collection-play text-3xl mb-2 block"></i>
          <p class="text-sm">Queue is empty. Add videos above.</p>
        </div>`;
      return;
    }

    list.innerHTML = this.queue.map((item, i) => `
      <div class="media-queue-item" data-index="${i}">
        <span class="queue-pos">${i + 1}</span>
        <img class="queue-thumb" src="${this.escapeAttr(item.thumbnail_url)}" alt="" loading="lazy" />
        <div class="queue-info">
          <div class="queue-title">${escapeHtml(item.title)}</div>
          <div class="queue-duration">${this.formatDuration(item.duration_seconds)}</div>
        </div>
        <div class="queue-actions">
          <button class="btn btn-xs btn-ghost" onclick="mediaPopout.saveToLibrary(mediaPopout.queue[${i}])" title="Save to library">
            <i class="bi bi-bookmark-plus"></i>
          </button>
          <button class="btn btn-xs btn-ghost text-error" onclick="mediaPopout.removeFromQueue(${i})" title="Remove">
            <i class="bi bi-x-lg"></i>
          </button>
        </div>
      </div>
    `).join('');
  }

  async playQueue() {
    if (this.queue.length === 0) return;

    try {
      if (this.queue.length === 1) {
        // Single video — create session via API
        const video = this.queue[0];
        const resp = await this.apiFetch('/api/media/youtube', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            video_id: video.youtube_video_id,
            title: video.title,
            duration: video.duration_seconds
          })
        });
        if (!resp.ok) throw new Error(`API error: ${resp.status}`);
        const data = await resp.json();
        if (!data.success) throw new Error(data.error || 'Failed to start playback');
        this.showToast('Playing in room!', 'success');
      } else {
        // Multiple videos — create playlist then play
        const playlistName = `Queue ${new Date().toLocaleTimeString()}`;
        const createResp = await this.apiFetch('/api/media/playlists', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: playlistName })
        });
        if (!createResp.ok) throw new Error(`API error: ${createResp.status}`);
        const createData = await createResp.json();
        if (!createData.success) throw new Error(createData.error);

        const playlistId = createData.playlist.id;

        for (const item of this.queue) {
          await this.apiFetch(`/api/media/playlists/${playlistId}/items`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(item)
          });
        }

        const playResp = await this.apiFetch(`/api/media/playlists/${playlistId}/play`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' }
        });
        if (!playResp.ok) throw new Error(`API error: ${playResp.status}`);
        const playData = await playResp.json();
        if (!playData.success) throw new Error(playData.error);

        this.showToast(`Playing playlist (${this.queue.length} videos)!`, 'success');
      }

      // Refresh Room tab to show new session
      this.refreshRoomSession();
    } catch (e) {
      this.showToast(`Failed: ${e.message}`, 'danger');
    }
  }

  // ========================================
  // Share Tab
  // ========================================

  bindShareTab() {
    document.getElementById('shareScreenBtn').addEventListener('click', () => {
      this.requestShare('screen', false);
    });

    document.getElementById('shareTabBtn').addEventListener('click', () => {
      this.requestShare('tab', true);
    });
  }

  async requestShare(shareType, requestAudio) {
    // getDisplayMedia must be called in the window where the user clicked.
    // We capture the stream here, init PeerJS here, and register with the server.
    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
        this.showToast('Screen sharing requires HTTPS. Ask the server admin to enable SSL.', 'danger');
        return;
      }

      const constraints = {
        video: {
          cursor: 'always',
          displaySurface: shareType === 'tab' ? 'browser' : 'monitor'
        },
        audio: requestAudio
      };

      const stream = await navigator.mediaDevices.getDisplayMedia(constraints);

      if (!stream || stream.getTracks().length === 0) {
        this.showToast('Share cancelled', 'info');
        return;
      }

      this.showToast('Starting share...', 'info');

      const hasAudio = stream.getAudioTracks().length > 0;

      // Initialize PeerJS in this window
      const peer = new Peer(undefined, {
        debug: 1,
        config: {
          iceServers: [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' }
          ]
        }
      });

      const peerId = await new Promise((resolve, reject) => {
        peer.on('open', resolve);
        peer.on('error', reject);
      });

      // Register the share session with the server
      const resp = await this.apiFetch('/api/media/register_share', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          peer_id: peerId,
          share_type: shareType,
          has_audio: hasAudio
        })
      });
      if (!resp.ok) {
        peer.destroy();
        stream.getTracks().forEach(t => t.stop());
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();

      if (!data.success) {
        peer.destroy();
        stream.getTracks().forEach(t => t.stop());
        this.showToast(data.error || 'Failed to register share', 'danger');
        return;
      }

      // Store state for cleanup
      this._sharePeer = peer;
      this._shareStream = stream;
      this._shareConnections = new Map();
      this._shareSessionId = data.session && data.session.id ? data.session.id : null;

      // Handle incoming viewer connections
      peer.on('call', (call) => {
        call.answer(stream);
        this._shareConnections.set(call.peer, call);
        call.on('close', () => this._shareConnections.delete(call.peer));
      });

      // Handle stream end (user clicks "Stop sharing" in browser chrome)
      stream.getVideoTracks()[0].onended = () => {
        this.stopShare();
      };

      // Start heartbeat to keep session alive
      this._shareHeartbeatInterval = setInterval(() => {
        this.apiFetch('/api/media/heartbeat', { method: 'POST' }).catch(() => {});
      }, 30000);

      this.showToast('Screen share started!', 'success');
      this.refreshRoomSession();

    } catch (e) {
      if (e.name === 'NotAllowedError') {
        this.showToast('Share cancelled or permission denied', 'info');
      } else {
        this.showToast(`Share failed: ${e.message}`, 'danger');
      }
    }
  }

  stopShare() {
    if (this._shareSessionId) {
      this.apiFetch('/api/media/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session_id: this._shareSessionId, action: 'end' })
      }).catch(() => {});
      this._shareSessionId = null;
    }

    if (this._shareStream) {
      this._shareStream.getTracks().forEach(t => t.stop());
      this._shareStream = null;
    }
    if (this._shareConnections) {
      this._shareConnections.forEach(c => c.close());
      this._shareConnections.clear();
    }
    if (this._sharePeer) {
      this._sharePeer.destroy();
      this._sharePeer = null;
    }
    if (this._shareHeartbeatInterval) {
      clearInterval(this._shareHeartbeatInterval);
      this._shareHeartbeatInterval = null;
    }
    this.refreshRoomSession();
  }

  // ========================================
  // Playlists Tab
  // ========================================

  bindPlaylistsTab() {
    const select = document.getElementById('playlistSelect');
    const deleteBtn = document.getElementById('deletePlaylistBtn');
    const loadBtn = document.getElementById('loadPlaylistBtn');
    const saveBtn = document.getElementById('saveToPlaylistBtn');
    const newBtn = document.getElementById('newPlaylistBtn');

    select.addEventListener('change', () => {
      const id = select.value;
      deleteBtn.disabled = !id;
      loadBtn.disabled = !id;
      if (id) this.previewPlaylist(id);
      else document.getElementById('playlistItemsPreview').innerHTML =
        '<p class="text-center text-base-content/30 text-sm py-4">Select a playlist to preview</p>';
    });

    deleteBtn.addEventListener('click', () => {
      if (select.value) this.deletePlaylist(select.value);
    });

    loadBtn.addEventListener('click', () => {
      if (select.value) this.loadPlaylistIntoQueue(select.value);
    });

    saveBtn.addEventListener('click', () => {
      document.getElementById('savePlaylistModal').showModal();
    });

    // Enable save button when queue has items
    const updateSaveBtn = () => { saveBtn.disabled = this.queue.length === 0; };
    const origRender = this.renderQueue.bind(this);
    this.renderQueue = () => { origRender(); updateSaveBtn(); };

    newBtn.addEventListener('click', () => {
      document.getElementById('newPlaylistModal').showModal();
      document.getElementById('newPlaylistName').value = '';
      document.getElementById('newPlaylistName').focus();
    });

    document.getElementById('createPlaylistConfirm').addEventListener('click', () => {
      const name = document.getElementById('newPlaylistName').value.trim();
      if (name) this.createPlaylist(name);
      document.getElementById('newPlaylistModal').close();
    });

    document.getElementById('savePlaylistConfirm').addEventListener('click', () => {
      const name = document.getElementById('savePlaylistName').value.trim();
      if (name) this.saveQueueAsPlaylist(name);
      document.getElementById('savePlaylistModal').close();
    });
  }

  async loadPlaylists() {
    try {
      const resp = await this.apiFetch('/api/media/playlists');
      if (!resp.ok) {
        console.error('Error loading playlists:', resp.status);
        return;
      }
      const data = await resp.json();
      if (data.success) {
        this.playlists = data.playlists;
        this.renderPlaylistSelect();
      }
    } catch (e) {
      console.error('Error loading playlists:', e);
    }
  }

  renderPlaylistSelect() {
    const select = document.getElementById('playlistSelect');
    const current = select.value;
    select.innerHTML = '<option value="">-- Select Playlist --</option>' +
      this.playlists.map(pl =>
        `<option value="${pl.id}">${escapeHtml(pl.name)} (${pl.item_count})</option>`
      ).join('');
    if (current) select.value = current;
  }

  async previewPlaylist(playlistId) {
    const pl = this.playlists.find(p => p.id === parseInt(playlistId));
    const container = document.getElementById('playlistItemsPreview');

    if (!pl || !pl.items || pl.items.length === 0) {
      container.innerHTML = '<p class="text-center text-base-content/30 text-sm py-4">Playlist is empty</p>';
      return;
    }

    container.innerHTML = pl.items.map((item, i) => `
      <div class="playlist-preview-item">
        <span class="pp-pos">${i + 1}</span>
        <span class="pp-title">${escapeHtml(item.title || 'Untitled')}</span>
        <span class="pp-duration">${this.formatDuration(item.duration_seconds)}</span>
      </div>
    `).join('');
  }

  async createPlaylist(name) {
    try {
      const resp = await this.apiFetch('/api/media/playlists', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      });
      if (!resp.ok) {
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();
      if (data.success) {
        this.showToast('Playlist created', 'success');
        await this.loadPlaylists();
      } else {
        this.showToast(data.error || 'Failed to create playlist', 'danger');
      }
    } catch (e) {
      this.showToast('Error creating playlist', 'danger');
    }
  }

  async deletePlaylist(playlistId) {
    if (!confirm('Delete this playlist?')) return;
    try {
      const resp = await this.apiFetch(`/api/media/playlists/${playlistId}`, { method: 'DELETE' });
      if (!resp.ok) {
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();
      if (data.success) {
        this.showToast('Playlist deleted', 'success');
        await this.loadPlaylists();
        document.getElementById('playlistItemsPreview').innerHTML =
          '<p class="text-center text-base-content/30 text-sm py-4">Select a playlist to preview</p>';
      }
    } catch (e) {
      this.showToast('Error deleting playlist', 'danger');
    }
  }

  async loadPlaylistIntoQueue(playlistId) {
    const pl = this.playlists.find(p => p.id === parseInt(playlistId));
    if (!pl || !pl.items) return;

    pl.items.forEach(item => {
      this.queue.push({
        youtube_video_id: item.youtube_video_id,
        title: item.title || 'Untitled',
        thumbnail_url: item.thumbnail_url || `https://img.youtube.com/vi/${item.youtube_video_id}/mqdefault.jpg`,
        duration_seconds: item.duration_seconds,
        is_embeddable: item.is_embeddable !== false
      });
    });

    this.renderQueue();
    this.showToast(`Loaded ${pl.items.length} videos into queue`, 'success');

    // Switch to YouTube tab
    document.querySelector('#mediaTabs [data-tab="youtube"]').click();
  }

  async saveQueueAsPlaylist(name) {
    if (this.queue.length === 0) return;
    try {
      const createResp = await this.apiFetch('/api/media/playlists', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      });
      if (!createResp.ok) throw new Error(`API error: ${createResp.status}`);
      const createData = await createResp.json();
      if (!createData.success) throw new Error(createData.error);

      const playlistId = createData.playlist.id;
      for (const item of this.queue) {
        await this.apiFetch(`/api/media/playlists/${playlistId}/items`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(item)
        });
      }

      this.showToast(`Saved ${this.queue.length} videos to "${name}"`, 'success');
      await this.loadPlaylists();
    } catch (e) {
      this.showToast(`Failed: ${e.message}`, 'danger');
    }
  }

  // ========================================
  // Library (Saved Videos)
  // ========================================

  async loadLibrary() {
    try {
      const resp = await this.apiFetch('/api/media/library');
      if (!resp.ok) {
        console.error('Error loading library:', resp.status);
        return;
      }
      const data = await resp.json();
      if (data.success) {
        this.library = data.videos;
        this.renderLibrary();
      }
    } catch (e) {
      console.error('Error loading library:', e);
    }
  }

  renderLibrary() {
    const container = document.getElementById('libraryList');
    if (this.library.length === 0) {
      container.innerHTML = `
        <p class="text-center text-base-content/30 text-sm py-4">
          <i class="bi bi-bookmark block text-2xl mb-1"></i>
          No saved videos yet
        </p>`;
      return;
    }

    container.innerHTML = this.library.map(v => `
      <div class="media-library-item">
        <i class="bi bi-youtube text-error"></i>
        <span class="lib-name">${escapeHtml(v.name)}</span>
        <div class="lib-actions">
          <button class="btn btn-xs btn-ghost" onclick="mediaPopout.addLibraryToQueue('${this.escapeAttr(v.youtube_video_id)}', '${this.escapeAttr(v.name)}')" title="Add to queue">
            <i class="bi bi-plus-lg"></i>
          </button>
          <button class="btn btn-xs btn-ghost text-error" onclick="mediaPopout.removeFromLibrary(${v.id})" title="Remove">
            <i class="bi bi-trash3"></i>
          </button>
        </div>
      </div>
    `).join('');
  }

  addLibraryToQueue(videoId, name) {
    this.addToQueue({
      video_id: videoId,
      youtube_video_id: videoId,
      title: name,
      thumbnail_url: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
      duration_seconds: null,
      is_embeddable: true
    });
    this.showToast('Added to queue', 'success');
    document.querySelector('#mediaTabs [data-tab="youtube"]').click();
  }

  async saveToLibrary(video) {
    try {
      const resp = await this.apiFetch('/api/media/library', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: video.title || video.name || 'Untitled',
          youtube_video_id: video.youtube_video_id || video.video_id
        })
      });
      if (!resp.ok) {
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();
      if (data.success) {
        this.showToast('Saved to library', 'success');
        await this.loadLibrary();
      } else {
        this.showToast(data.error || 'Failed to save', 'danger');
      }
    } catch (e) {
      this.showToast('Error saving to library', 'danger');
    }
  }

  async removeFromLibrary(id) {
    try {
      const resp = await this.apiFetch(`/api/media/library/${id}`, { method: 'DELETE' });
      if (!resp.ok) {
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();
      if (data.success) {
        this.showToast('Removed from library', 'success');
        await this.loadLibrary();
      }
    } catch (e) {
      this.showToast('Error removing from library', 'danger');
    }
  }

  // ========================================
  // Room Tab
  // ========================================

  bindRoomTab() {
    // Room tab is informational — shows current session status.
    // The webclient handles join/leave via its own polling + MediaSync.
    // We poll the API to keep the Room tab display up-to-date.
    this.refreshRoomSession();
    this.roomPollInterval = setInterval(() => this.refreshRoomSession(), 3000);
  }

  async refreshRoomSession() {
    const container = document.getElementById('roomSessionInfo');
    if (!container) return;

    try {
      const resp = await this.apiFetch('/api/media/session');
      if (!resp.ok) return;
      const data = await resp.json();

      if (data.success && data.session) {
        const s = data.session;
        const isHost = s.host_id === this.characterInstanceId;
        const typeBadge = s.type === 'youtube'
          ? '<span class="badge badge-sm badge-error"><i class="bi bi-youtube"></i> YouTube</span>'
          : '<span class="badge badge-sm badge-info"><i class="bi bi-display"></i> Screen Share</span>';

        const title = s.youtube_title || s.share_type || 'Media';
        const host = s.host_name || 'Unknown';
        const viewers = s.viewer_count || 0;
        const status = s.is_playing ? 'Playing' : 'Paused';
        const hostBadge = isHost ? '<span class="badge badge-sm badge-primary">HOST</span>' : '';

        // Open player button — sends signal via backend to all clients in room
        const openBtn = `<button class="btn btn-sm btn-accent" onclick="mediaPopout.openPlayerForRoom()"><i class="bi bi-display mr-1"></i>Open Player</button>`;

        // Host controls: play/pause, end session
        let controls = '';
        if (isHost && s.type === 'youtube') {
          const playPauseBtn = s.is_playing
            ? `<button class="btn btn-sm btn-ghost" onclick="mediaPopout.sessionControl('pause')"><i class="bi bi-pause-fill mr-1"></i>Pause</button>`
            : `<button class="btn btn-sm btn-primary" onclick="mediaPopout.sessionControl('play')"><i class="bi bi-play-fill mr-1"></i>Play</button>`;
          controls = `
            <div class="flex gap-2 mt-3">
              ${openBtn}
              ${playPauseBtn}
              <button class="btn btn-sm btn-error btn-outline" onclick="mediaPopout.sessionControl('end')">
                <i class="bi bi-stop-fill mr-1"></i>End Session
              </button>
            </div>
          `;
        } else if (isHost) {
          controls = `
            <div class="flex gap-2 mt-3">
              ${openBtn}
              <button class="btn btn-sm btn-error btn-outline" onclick="mediaPopout.sessionControl('end')">
                <i class="bi bi-stop-fill mr-1"></i>Stop Sharing
              </button>
            </div>
          `;
        } else {
          // Viewer
          controls = `
            <div class="flex gap-2 mt-3">
              ${openBtn}
            </div>
          `;
        }

        container.innerHTML = `
          <div class="card bg-base-300 shadow-sm">
            <div class="card-body p-4 gap-3">
              <div class="flex items-center gap-2">
                ${typeBadge}
                ${hostBadge}
                <span class="badge badge-sm badge-ghost">${escapeHtml(status)}</span>
              </div>
              <h3 class="font-bold text-base">${escapeHtml(title)}</h3>
              <div class="text-sm text-base-content/60 space-y-1">
                <div><i class="bi bi-person-fill mr-1"></i>Hosted by <strong>${escapeHtml(host)}</strong></div>
                <div><i class="bi bi-people-fill mr-1"></i>${viewers} viewer${viewers !== 1 ? 's' : ''}</div>
              </div>
              ${controls}
            </div>
          </div>
        `;

        this._currentSessionId = s.id;
      } else {
        this._currentSessionId = null;
        container.innerHTML = `
          <div class="text-center py-8 text-base-content/30">
            <i class="bi bi-broadcast block text-3xl mb-2"></i>
            <p class="text-sm">No active session in this room.</p>
            <p class="text-xs mt-1">Use the YouTube tab to start playing something.</p>
          </div>
        `;
      }
    } catch (e) {
      // Silently fail — will retry on next poll
    }
  }

  async openPlayerForRoom() {
    try {
      const resp = await this.apiFetch('/api/media/open_player', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });
      if (!resp.ok) {
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();
      if (data.success) {
        this.showToast('Sent open signal to all clients in room', 'success');
      } else {
        this.showToast(data.error || 'Failed to open player', 'danger');
      }
    } catch (e) {
      this.showToast('Error sending open signal', 'danger');
    }
  }

  async sessionControl(action) {
    if (!this._currentSessionId) return;

    try {
      const resp = await this.apiFetch('/api/media/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session_id: this._currentSessionId, action })
      });
      if (!resp.ok) {
        this.showToast(`API error: ${resp.status}`, 'danger');
        return;
      }
      const data = await resp.json();

      if (data.success) {
        if (action === 'end') {
          this.showToast('Session ended', 'success');
        }
        // Refresh immediately to update controls
        this.refreshRoomSession();
      } else {
        this.showToast(data.error || `Failed to ${action}`, 'danger');
      }
    } catch (e) {
      this.showToast(`Error: ${e.message}`, 'danger');
    }
  }

  // ========================================
  // Settings Tab
  // ========================================

  bindSettingsTab() {
    const autoplayToggle = document.getElementById('settingAutoplay');
    const mutedToggle = document.getElementById('settingStartMuted');

    autoplayToggle.addEventListener('change', () => {
      this.updatePreference('autoplay', autoplayToggle.checked);
    });

    mutedToggle.addEventListener('change', () => {
      this.updatePreference('start_muted', mutedToggle.checked);
    });
  }

  async updatePreference(key, value) {
    try {
      await this.apiFetch('/api/media/preferences', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ [key]: value })
      });
      this.showToast('Preference saved', 'success');
    } catch (e) {
      this.showToast('Failed to save preference', 'danger');
    }
  }

  // ========================================
  // Utilities
  // ========================================

  formatDuration(seconds) {
    if (!seconds) return '--:--';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
    return `${m}:${String(s).padStart(2, '0')}`;
  }

  escapeAttr(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;');
  }

  destroy() {
    if (this.roomPollInterval) {
      clearInterval(this.roomPollInterval);
      this.roomPollInterval = null;
    }
    if (this._shareHeartbeatInterval) {
      clearInterval(this._shareHeartbeatInterval);
      this._shareHeartbeatInterval = null;
    }
    this.stopShare();
  }

  showToast(message, type = 'info') {
    const container = document.getElementById('mediaToasts');
    if (!container) return;

    const alertClass = type === 'success' ? 'alert-success' :
                       type === 'danger' ? 'alert-error' :
                       type === 'warning' ? 'alert-warning' : 'alert-info';

    const toast = document.createElement('div');
    toast.className = `alert ${alertClass} text-sm py-2 px-3`;
    toast.innerHTML = `
      <span>${escapeHtml(message)}</span>
      <button type="button" class="btn btn-ghost btn-xs" onclick="this.closest('.alert').remove()">
        <i class="bi bi-x-lg"></i>
      </button>
    `;
    container.appendChild(toast);
    setTimeout(() => toast.remove(), 4000);
  }
}