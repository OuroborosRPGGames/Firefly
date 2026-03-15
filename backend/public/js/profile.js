/**
 * Profile Page JavaScript
 * Handles carousels, section editing, and uploads
 */
(function() {
  'use strict';

  const characterId = document.querySelector('.profile-page')?.dataset.characterId;
  if (!characterId) return;

  // API helpers
  const apiBase = `/api/profiles/${characterId}`;

  async function apiCall(path, options = {}) {
    const method = (options.method || 'GET').toUpperCase();
    const csrfHeader = (method !== 'GET' && method !== 'HEAD') ? { 'X-CSRF-Token': getCsrfToken() } : {};
    const response = await fetch(`${apiBase}${path}`, {
      ...options,
      headers: {
        ...options.headers,
        ...csrfHeader,
        ...(options.body instanceof FormData ? {} : { 'Content-Type': 'application/json' })
      }
    });
    if (!response.ok) {
      console.error(`API error: ${response.status} for ${path}`);
      return { success: false, error: `API error: ${response.status}` };
    }
    return response.json();
  }

  // ============================================
  // Picture Carousel
  // ============================================
  function initPictureCarousel() {
    const carousel = document.querySelector('.profile-pictures-carousel');
    if (!carousel) return;

    const slides = carousel.querySelectorAll('.carousel-slide');
    const indicators = carousel.querySelectorAll('.carousel-indicator');
    const prevBtn = carousel.querySelector('.carousel-prev');
    const nextBtn = carousel.querySelector('.carousel-next');
    let currentSlide = 0;

    function showSlide(index) {
      if (slides.length === 0) return;
      currentSlide = (index + slides.length) % slides.length;
      slides.forEach((s, i) => s.classList.toggle('active', i === currentSlide));
      indicators.forEach((ind, i) => ind.classList.toggle('active', i === currentSlide));
    }

    if (prevBtn) prevBtn.addEventListener('click', () => showSlide(currentSlide - 1));
    if (nextBtn) nextBtn.addEventListener('click', () => showSlide(currentSlide + 1));

    indicators.forEach((indicator, i) => {
      indicator.addEventListener('click', () => showSlide(i));
    });

    // Delete picture
    carousel.querySelectorAll('.carousel-delete-btn').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const pictureId = btn.dataset.pictureId;
        if (!confirm('Delete this picture?')) return;

        const result = await apiCall(`/pictures/${pictureId}`, { method: 'DELETE' });
        if (result.success) {
          location.reload();
        } else {
          alert(result.error || 'Failed to delete picture');
        }
      });
    });

    // Add picture
    const addPictureBtn = document.getElementById('addPictureBtn');
    const pictureUpload = document.getElementById('pictureUpload');

    if (addPictureBtn && pictureUpload) {
      addPictureBtn.addEventListener('click', () => pictureUpload.click());

      pictureUpload.addEventListener('change', async (e) => {
        const file = e.target.files[0];
        if (!file) return;

        const formData = new FormData();
        formData.append('file', file);

        addPictureBtn.disabled = true;
        addPictureBtn.innerHTML = '<span class="loading loading-spinner loading-xs mr-1"></span>Uploading...';

        try {
          const result = await apiCall('/pictures', {
            method: 'POST',
            body: formData
          });

          if (result.success) {
            location.reload();
          } else {
            alert(result.error || 'Failed to upload picture');
          }
        } finally {
          addPictureBtn.disabled = false;
          addPictureBtn.innerHTML = '<i class="bi bi-plus-circle mr-1"></i>Add Picture';
          pictureUpload.value = '';
        }
      });
    }
  }

  // ============================================
  // Video Carousel
  // ============================================
  function initVideoCarousel() {
    const carousel = document.querySelector('.video-carousel');
    if (!carousel) return;

    const slides = carousel.querySelectorAll('.video-slide');
    const indicators = carousel.querySelectorAll('.carousel-indicator');
    const prevBtn = carousel.querySelector('.video-prev');
    const nextBtn = carousel.querySelector('.video-next');
    let currentSlide = 0;

    function showSlide(index) {
      if (slides.length === 0) return;
      currentSlide = (index + slides.length) % slides.length;
      slides.forEach((s, i) => s.classList.toggle('active', i === currentSlide));
      indicators.forEach((ind, i) => ind.classList.toggle('active', i === currentSlide));
    }

    if (prevBtn) prevBtn.addEventListener('click', () => showSlide(currentSlide - 1));
    if (nextBtn) nextBtn.addEventListener('click', () => showSlide(currentSlide + 1));

    indicators.forEach((indicator, i) => {
      indicator.addEventListener('click', () => showSlide(i));
    });

    // Delete video
    carousel.querySelectorAll('.video-delete-btn').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const videoId = btn.dataset.videoId;
        if (!confirm('Remove this video?')) return;

        const result = await apiCall(`/videos/${videoId}`, { method: 'DELETE' });
        if (result.success) {
          location.reload();
        } else {
          alert(result.error || 'Failed to remove video');
        }
      });
    });
  }

  // ============================================
  // Add Video Modal
  // ============================================
  function initAddVideo() {
    const addVideoBtn = document.getElementById('addVideoBtn');
    const modal = document.getElementById('addVideoModal');
    const saveBtn = document.getElementById('saveVideoBtn');
    const urlInput = document.getElementById('videoUrl');
    const titleInput = document.getElementById('videoTitle');

    if (!addVideoBtn || !modal) return;

    addVideoBtn.addEventListener('click', () => {
      urlInput.value = '';
      titleInput.value = '';
      if (modal.showModal) modal.showModal();
    });

    saveBtn.addEventListener('click', async () => {
      const url = urlInput.value.trim();
      const title = titleInput.value.trim();

      // Extract YouTube ID from various URL formats
      let youtubeId = url;

      // Try to extract from URL
      const patterns = [
        /(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/)([a-zA-Z0-9_-]{11})/,
        /^([a-zA-Z0-9_-]{11})$/
      ];

      for (const pattern of patterns) {
        const match = url.match(pattern);
        if (match) {
          youtubeId = match[1];
          break;
        }
      }

      if (!/^[a-zA-Z0-9_-]{11}$/.test(youtubeId)) {
        alert('Please enter a valid YouTube URL or video ID');
        return;
      }

      saveBtn.disabled = true;
      saveBtn.innerHTML = '<span class="loading loading-spinner loading-xs mr-1"></span>Adding...';

      try {
        const result = await apiCall('/videos', {
          method: 'POST',
          body: JSON.stringify({ youtube_id: youtubeId, title: title || null })
        });

        if (result.success) {
          location.reload();
        } else {
          alert(result.error || 'Failed to add video');
        }
      } finally {
        saveBtn.disabled = false;
        saveBtn.innerHTML = 'Add Video';
      }
    });
  }

  // ============================================
  // Section Editing
  // ============================================
  function initSectionEditor() {
    const sections = document.getElementById('profileSections');
    const addSectionBtn = document.getElementById('addSectionBtn');
    const modal = document.getElementById('sectionEditorModal');

    if (!sections || !modal) return;

    const sectionIdInput = document.getElementById('editSectionId');
    const titleInput = document.getElementById('sectionTitle');
    const contentEditor = document.getElementById('sectionContentEditor');
    const saveBtn = document.getElementById('saveSectionBtn');

    let isNewSection = false;

    // Make content editor editable
    contentEditor.contentEditable = true;

    function openEditor(sectionId, title = '', content = '') {
      sectionIdInput.value = sectionId || '';
      titleInput.value = title;
      contentEditor.innerHTML = content;
      isNewSection = !sectionId;
      document.getElementById('sectionEditorModalLabel').textContent =
        isNewSection ? 'Add Section' : 'Edit Section';
      if (modal.showModal) modal.showModal();
    }

    // Edit section buttons
    sections.querySelectorAll('.edit-section-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const card = btn.closest('.profile-section');
        const sectionId = card.dataset.sectionId;
        const title = card.querySelector('.section-title').textContent;
        const content = card.querySelector('.section-content').innerHTML;
        openEditor(sectionId, title === 'About' ? '' : title, content);
      });
    });

    // Add section button
    if (addSectionBtn) {
      addSectionBtn.addEventListener('click', () => openEditor(null, '', ''));
    }

    // Save section
    saveBtn.addEventListener('click', async () => {
      const sectionId = sectionIdInput.value;
      const title = titleInput.value.trim();
      const content = contentEditor.innerHTML.trim();

      if (!content) {
        alert('Please enter some content');
        return;
      }

      saveBtn.disabled = true;
      saveBtn.innerHTML = '<span class="loading loading-spinner loading-xs mr-1"></span>Saving...';

      try {
        let result;
        if (isNewSection) {
          result = await apiCall('/sections', {
            method: 'POST',
            body: JSON.stringify({ title: title || null, content })
          });
        } else {
          result = await apiCall(`/sections/${sectionId}`, {
            method: 'PATCH',
            body: JSON.stringify({ title: title || null, content })
          });
        }

        if (result.success) {
          location.reload();
        } else {
          alert(result.error || 'Failed to save section');
        }
      } finally {
        saveBtn.disabled = false;
        saveBtn.innerHTML = 'Save';
      }
    });

    // Delete section buttons
    sections.querySelectorAll('.delete-section-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const sectionId = btn.dataset.sectionId;
        if (!confirm('Delete this section?')) return;

        const result = await apiCall(`/sections/${sectionId}`, { method: 'DELETE' });
        if (result.success) {
          location.reload();
        } else {
          alert(result.error || 'Failed to delete section');
        }
      });
    });
  }

  // ============================================
  // Background Image
  // ============================================
  function initBackgroundControls() {
    const changeBtn = document.getElementById('changeBackgroundBtn');
    const removeBtn = document.getElementById('removeBackgroundBtn');
    const upload = document.getElementById('backgroundUpload');

    if (!changeBtn || !upload) return;

    changeBtn.addEventListener('click', () => upload.click());

    upload.addEventListener('change', async (e) => {
      const file = e.target.files[0];
      if (!file) return;

      const formData = new FormData();
      formData.append('file', file);

      changeBtn.disabled = true;
      changeBtn.innerHTML = '<span class="loading loading-spinner loading-xs mr-1"></span>Uploading...';

      try {
        const result = await apiCall('/settings/background', {
          method: 'POST',
          body: formData
        });

        if (result.success) {
          location.reload();
        } else {
          alert(result.error || 'Failed to upload background');
        }
      } finally {
        changeBtn.disabled = false;
        changeBtn.innerHTML = '<i class="bi bi-image mr-1"></i>Change Background';
        upload.value = '';
      }
    });

    if (removeBtn) {
      removeBtn.addEventListener('click', async () => {
        if (!confirm('Remove background image?')) return;

        const result = await apiCall('/settings/background', { method: 'DELETE' });
        if (result.success) {
          location.reload();
        } else {
          alert(result.error || 'Failed to remove background');
        }
      });
    }
  }

  // ============================================
  // Initialize
  // ============================================
  document.addEventListener('DOMContentLoaded', () => {
    initPictureCarousel();
    initVideoCarousel();
    initAddVideo();
    initSectionEditor();
    initBackgroundControls();
  });
})();
