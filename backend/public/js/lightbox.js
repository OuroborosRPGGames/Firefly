/**
 * Shared Image Lightbox
 * Used by webclient and character creator for consistent image viewing
 */

(function() {
  'use strict';

  let lightboxEl = null;
  let escHandler = null;

  function ensureLightboxElement() {
    if (lightboxEl) return lightboxEl;

    // Check if element already exists (webclient pre-creates it)
    lightboxEl = document.getElementById('imageLightbox');
    if (lightboxEl) return lightboxEl;

    // Create the lightbox element
    lightboxEl = document.createElement('div');
    lightboxEl.id = 'imageLightbox';
    lightboxEl.innerHTML = `
      <span class="lightbox-close">&times;</span>
      <img src="" alt="Enlarged image">
    `;
    document.body.appendChild(lightboxEl);

    return lightboxEl;
  }

  function closeLightbox() {
    if (lightboxEl) {
      lightboxEl.classList.remove('visible');
    }
    if (escHandler) {
      document.removeEventListener('keydown', escHandler);
      escHandler = null;
    }
  }

  function openLightbox(imageUrl) {
    const el = ensureLightboxElement();
    const img = el.querySelector('img');
    if (img) img.src = imageUrl;

    el.classList.add('visible');

    // Close on click anywhere
    el.onclick = closeLightbox;

    // Close on Escape
    escHandler = function(e) {
      if (e.key === 'Escape') {
        closeLightbox();
      }
    };
    document.addEventListener('keydown', escHandler);
  }

  // Expose globally
  window.openLightbox = openLightbox;
  window.closeLightbox = closeLightbox;
})();
