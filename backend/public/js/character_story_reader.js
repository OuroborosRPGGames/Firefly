/**
 * Character Story Reader
 * Handles loading and displaying character story content in the dashboard
 */
const CharacterStoryReader = (function() {
  // State
  let currentCharacterId = null;
  let chapters = [];
  let currentChapterIndex = 0;
  let modal = null; // Native dialog element

  /**
   * Initialize the reader by loading summaries for visible characters
   */
  function init() {
    // Get native dialog element (DaisyUI modal uses <dialog>)
    const modalEl = document.getElementById('storyReaderModal');
    if (modalEl) {
      modal = modalEl;

      // Handle keyboard navigation
      modalEl.addEventListener('keydown', handleKeydown);

      // Handle Escape key to close modal (native dialog handles this, but we track state)
      modalEl.addEventListener('close', () => {
        // Modal was closed - cleanup if needed
      });
    }

    // Set up tab switching for story tabs (DaisyUI tabs or custom tabs)
    const tabEls = document.querySelectorAll('#storyTabs button[data-character-id]');
    tabEls.forEach(tabEl => {
      tabEl.addEventListener('click', (e) => {
        const characterId = e.currentTarget.dataset.characterId;

        // Update active state on tabs
        tabEls.forEach(t => t.classList.remove('tab-active', 'active'));
        e.currentTarget.classList.add('tab-active', 'active');

        // Show corresponding tab pane
        const tabPanes = document.querySelectorAll('#storyTabContent > div');
        tabPanes.forEach(pane => {
          pane.classList.add('hidden');
          pane.classList.remove('block');
        });
        const targetPane = document.getElementById(`story-${characterId}`);
        if (targetPane) {
          targetPane.classList.remove('hidden');
          targetPane.classList.add('block');
        }

        // Load summary for this character
        loadSummary(characterId);
      });
    });

    // Load summary for first character (tabbed dashboard view)
    const firstTab = document.querySelector('#storyTabs button.active, #storyTabs button.tab-active');
    if (firstTab) {
      const characterId = firstTab.dataset.characterId;
      loadSummary(characterId);
    } else {
      // Single character profile page (no tabs) - load from the story card button
      const singleBtn = document.querySelector('.read-story-btn[data-character-id]');
      if (singleBtn) {
        loadSummary(singleBtn.dataset.characterId);
      }
    }

    // Set up navigation buttons
    const prevBtn = document.getElementById('prevChapterBtn');
    const nextBtn = document.getElementById('nextChapterBtn');
    const downloadBtn = document.getElementById('readerDownloadBtn');

    if (prevBtn) prevBtn.addEventListener('click', () => navigateChapter(-1));
    if (nextBtn) nextBtn.addEventListener('click', () => navigateChapter(1));
    if (downloadBtn) downloadBtn.addEventListener('click', () => download(currentCharacterId));

    // Set up story card button listeners (replacing inline onclick handlers)
    document.querySelectorAll('[data-character-id]').forEach(btn => {
      if (btn.classList.contains('read-story-btn')) {
        btn.addEventListener('click', () => {
          openReader(parseInt(btn.dataset.characterId, 10));
        });
      } else if (btn.classList.contains('download-story-btn')) {
        btn.addEventListener('click', () => {
          download(parseInt(btn.dataset.characterId, 10));
        });
      }
    });
  }

  /**
   * Load summary statistics for a character
   */
  async function loadSummary(characterId) {
    try {
      const response = await fetch(`/api/character_story/${characterId}/summary`, {
        credentials: 'same-origin'
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = await response.json();

      if (data.success && data.summary) {
        const summary = data.summary;

        // Update UI
        const chaptersEl = document.getElementById(`chapters-count-${characterId}`);
        const wordsEl = document.getElementById(`words-count-${characterId}`);
        const readTimeEl = document.getElementById(`read-time-${characterId}`);
        const readBtn = document.getElementById(`read-btn-${characterId}`);
        const downloadBtn = document.getElementById(`download-btn-${characterId}`);
        const emptyEl = document.getElementById(`story-empty-${characterId}`);

        if (summary.chapter_count > 0) {
          // Show stats
          if (chaptersEl) chaptersEl.textContent = summary.chapter_count;
          if (wordsEl) wordsEl.textContent = formatNumber(summary.total_words);
          if (readTimeEl) readTimeEl.textContent = formatReadingTime(summary.total_words);

          // Enable buttons
          if (readBtn) readBtn.disabled = false;
          if (downloadBtn) downloadBtn.disabled = false;

          // Hide empty state
          if (emptyEl) emptyEl.classList.add('hidden');
        } else {
          // No content - show empty state
          if (chaptersEl) chaptersEl.textContent = '0';
          if (wordsEl) wordsEl.textContent = '0';
          if (readTimeEl) readTimeEl.textContent = '--';

          // Keep buttons disabled
          if (readBtn) readBtn.disabled = true;
          if (downloadBtn) downloadBtn.disabled = true;

          // Show empty state
          if (emptyEl) emptyEl.classList.remove('hidden');
        }
      }
    } catch (error) {
      console.error('Failed to load story summary:', error);
      // Show error state
      const chaptersEl = document.getElementById(`chapters-count-${characterId}`);
      const wordsEl = document.getElementById(`words-count-${characterId}`);
      const readTimeEl = document.getElementById(`read-time-${characterId}`);

      if (chaptersEl) chaptersEl.innerHTML = '<i class="bi bi-exclamation-triangle text-warning"></i>';
      if (wordsEl) wordsEl.innerHTML = '<i class="bi bi-exclamation-triangle text-warning"></i>';
      if (readTimeEl) readTimeEl.innerHTML = '--';
    }
  }

  /**
   * Open the story reader modal
   */
  async function openReader(characterId) {
    currentCharacterId = characterId;
    currentChapterIndex = 0;
    chapters = [];

    // Show modal using native dialog API (DaisyUI)
    if (modal) {
      if (typeof modal.showModal === 'function') {
        modal.showModal();
      } else {
        // Fallback for non-dialog elements (legacy Bootstrap modal)
        modal.classList.add('modal-open');
      }
    }

    // Update modal title
    const modalTitle = document.getElementById('storyReaderModalLabel');
    if (modalTitle) {
      modalTitle.textContent = 'Loading...';
    }

    // Load chapters
    await loadChapters(characterId);
  }

  /**
   * Close the story reader modal
   */
  function closeReader() {
    if (modal) {
      if (typeof modal.close === 'function') {
        modal.close();
      } else {
        // Fallback for non-dialog elements
        modal.classList.remove('modal-open');
      }
    }
  }

  /**
   * Load chapter list for a character
   */
  async function loadChapters(characterId) {
    try {
      const response = await fetch(`/api/character_story/${characterId}/chapters`, {
        credentials: 'same-origin'
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = await response.json();

      if (data.success && data.chapters) {
        chapters = data.chapters;
        renderChapterList();

        // Load first chapter
        if (chapters.length > 0) {
          loadChapter(0);
        }
      }
    } catch (error) {
      console.error('Failed to load chapters:', error);
      showError('Failed to load chapters. Please try again.');
    }
  }

  /**
   * Render the chapter list in the sidebar
   */
  function renderChapterList() {
    const container = document.getElementById('chapterList');
    if (!container) return;

    container.innerHTML = buildChapterListHtml(chapters);
    attachChapterClickListeners(container);

    // Set up search input
    const searchInput = document.getElementById('chapterSearchInput');
    if (searchInput) {
      searchInput.value = '';
      searchInput.addEventListener('input', () => {
        filterChapterList(searchInput.value.trim().toLowerCase());
      });
    }
  }

  /**
   * Build HTML for chapter list items
   */
  function buildChapterListHtml(chapterArray) {
    return chapterArray.map((chapter, index) => {
      const title = chapter.title || `Chapter ${index + 1}`;
      const wordCount = formatNumber(chapter.word_count);
      const date = chapter.start_time ? formatDate(chapter.start_time) : '';
      const location = chapter.location || '';
      const metaParts = [date, `${wordCount} words`, location].filter(Boolean);

      return `
        <div class="chapter-item ${index === currentChapterIndex ? 'active' : ''}"
             data-chapter-index="${index}"
             data-search-text="${escapeHtml((title + ' ' + date + ' ' + location).toLowerCase())}">
          <div class="chapter-item-title">${escapeHtml(title)}</div>
          <div class="chapter-item-date">${date}</div>
          <div class="chapter-item-meta">${metaParts.filter(p => p !== date).join(' &middot; ')}</div>
        </div>
      `;
    }).join('');
  }

  /**
   * Attach click listeners to chapter items
   */
  function attachChapterClickListeners(container) {
    container.querySelectorAll('.chapter-item').forEach(item => {
      item.addEventListener('click', () => {
        const index = parseInt(item.dataset.chapterIndex, 10);
        loadChapter(index);
      });
    });
  }

  /**
   * Filter chapter list by search query
   */
  function filterChapterList(query) {
    const container = document.getElementById('chapterList');
    if (!container) return;

    container.querySelectorAll('.chapter-item').forEach(item => {
      if (!query) {
        item.style.display = '';
      } else {
        const text = item.dataset.searchText || '';
        item.style.display = text.includes(query) ? '' : 'none';
      }
    });
  }

  /**
   * Load a specific chapter's content
   */
  async function loadChapter(index) {
    if (index < 0 || index >= chapters.length) return;

    currentChapterIndex = index;
    const chapter = chapters[index];

    // Update active state in sidebar
    document.querySelectorAll('.chapter-item').forEach((el, i) => {
      el.classList.toggle('active', i === index);
    });

    // Update chapter header
    const titleEl = document.getElementById('currentChapterTitle');
    const metaEl = document.getElementById('currentChapterMeta');
    const progressEl = document.getElementById('chapterProgress');

    if (titleEl) {
      titleEl.textContent = chapter.title || `Chapter ${index + 1}`;
    }
    if (metaEl) {
      const date = chapter.start_time ? formatDate(chapter.start_time) : '';
      const location = chapter.location || '';
      metaEl.textContent = [date, location].filter(Boolean).join(' - ');
    }
    if (progressEl) {
      progressEl.textContent = `Chapter ${index + 1} of ${chapters.length}`;
    }

    // Update navigation buttons
    const prevBtn = document.getElementById('prevChapterBtn');
    const nextBtn = document.getElementById('nextChapterBtn');
    if (prevBtn) prevBtn.disabled = index === 0;
    if (nextBtn) nextBtn.disabled = index === chapters.length - 1;

    // Show loading state (DaisyUI spinner)
    const contentEl = document.getElementById('chapterContent');
    if (contentEl) {
      contentEl.innerHTML = `
        <div class="text-center py-5">
          <span class="loading loading-spinner loading-lg text-primary"></span>
          <span class="sr-only">Loading...</span>
        </div>
      `;
    }

    // Fetch chapter content
    try {
      const response = await fetch(`/api/character_story/${currentCharacterId}/chapter/${index}`, {
        credentials: 'same-origin'
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = await response.json();

      if (data.success && data.logs) {
        renderChapterContent(data.logs);
      }
    } catch (error) {
      console.error('Failed to load chapter content:', error);
      if (contentEl) {
        contentEl.innerHTML = `
          <div class="text-center py-5 text-error">
            <i class="bi bi-exclamation-triangle text-4xl"></i>
            <p class="mt-2">Failed to load chapter. Please try again.</p>
          </div>
        `;
      }
    }
  }

  /**
   * Render chapter content from log entries
   */
  function renderChapterContent(logs) {
    const contentEl = document.getElementById('chapterContent');
    if (!contentEl) return;

    if (!logs || logs.length === 0) {
      contentEl.innerHTML = `
        <div class="text-center py-5 text-base-content/60">
          <p>No content in this chapter.</p>
        </div>
      `;
      return;
    }

    // Render each log entry
    // Content is server-rendered HTML from RpLog - sanitized by the game engine
    // before storage. Using innerHTML is intentional to preserve formatting.
    const html = logs.map(log => {
      const timestamp = log.logged_at ? formatTimestamp(log.logged_at) : '';
      const content = log.content || '';

      return `
        <div class="log-entry">
          ${timestamp ? `<div class="log-timestamp">${timestamp}</div>` : ''}
          <div class="log-content">${content}</div>
        </div>
      `;
    }).join('');

    contentEl.innerHTML = html;

    // Scroll to top
    contentEl.scrollTop = 0;
  }

  /**
   * Navigate to previous/next chapter
   */
  function navigateChapter(direction) {
    const newIndex = currentChapterIndex + direction;
    if (newIndex >= 0 && newIndex < chapters.length) {
      loadChapter(newIndex);
    }
  }

  /**
   * Handle keyboard navigation in the modal
   */
  function handleKeydown(e) {
    switch (e.key) {
      case 'ArrowLeft':
        navigateChapter(-1);
        e.preventDefault();
        break;
      case 'ArrowRight':
        navigateChapter(1);
        e.preventDefault();
        break;
      case 'Escape':
        // Native dialog handles Escape automatically
        // No additional action needed
        break;
    }
  }

  /**
   * Trigger story download
   */
  function download(characterId) {
    if (!characterId) return;
    window.location.href = `/api/character_story/${characterId}/download`;
  }

  /**
   * Show error message in the reader
   */
  function showError(message) {
    const contentEl = document.getElementById('chapterContent');
    if (contentEl) {
      contentEl.innerHTML = `
        <div class="text-center py-5 text-error">
          <i class="bi bi-exclamation-triangle text-4xl"></i>
          <p class="mt-2">${escapeHtml(message)}</p>
        </div>
      `;
    }
  }

  // Utility functions

  function formatNumber(num) {
    if (!num && num !== 0) return '--';
    return num.toLocaleString();
  }

  function formatReadingTime(words) {
    if (!words) return '--';
    // Average reading speed: 200-250 words per minute
    const minutes = Math.ceil(words / 225);
    if (minutes < 60) {
      return `${minutes} min`;
    }
    const hours = Math.floor(minutes / 60);
    const remainingMinutes = minutes % 60;
    if (remainingMinutes === 0) {
      return `${hours} hr`;
    }
    return `${hours} hr ${remainingMinutes} min`;
  }

  function formatDate(dateString) {
    if (!dateString) return '';
    const date = new Date(dateString);
    return date.toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    });
  }

  function formatTimestamp(dateString) {
    if (!dateString) return '';
    const date = new Date(dateString);
    return date.toLocaleString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit'
    });
  }

  // Initialize on DOM ready (or immediately if already loaded)
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  // Public API
  return {
    openReader,
    closeReader,
    loadChapter,
    download,
    navigateChapter
  };
})();
