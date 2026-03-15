/**
 * Firefly Main JavaScript
 * Handles scroll-to-top button, flash message auto-dismiss, and other UI interactions
 * Updated for DaisyUI - no Bootstrap dependencies
 */

(function() {
  'use strict';

  // ================================
  // Scroll to Top Button
  // ================================
  const scrollToTopBtn = document.getElementById('scrollToTop');

  function toggleScrollToTopButton() {
    if (!scrollToTopBtn) return;

    if (window.scrollY > 300) {
      scrollToTopBtn.style.display = 'flex';
      scrollToTopBtn.classList.add('visible');
    } else {
      scrollToTopBtn.classList.remove('visible');
      // Keep display:flex but hide via opacity/visibility in CSS
    }
  }

  function scrollToTop() {
    window.scrollTo({
      top: 0,
      behavior: 'smooth'
    });
  }

  if (scrollToTopBtn) {
    window.addEventListener('scroll', toggleScrollToTopButton, { passive: true });
    scrollToTopBtn.addEventListener('click', scrollToTop);
    // Initial check
    toggleScrollToTopButton();
  }

  // ================================
  // Flash Message Auto-dismiss
  // ================================
  const alerts = document.querySelectorAll('.alert');
  alerts.forEach(function(alert) {
    // Auto-dismiss after 5 seconds
    setTimeout(function() {
      alert.style.transition = 'opacity 0.3s ease-out';
      alert.style.opacity = '0';
      setTimeout(() => alert.remove(), 300);
    }, 5000);
  });

  // ================================
  // Smooth Scroll for Anchor Links
  // ================================
  document.querySelectorAll('a[href^="#"]').forEach(function(anchor) {
    anchor.addEventListener('click', function(e) {
      const targetId = this.getAttribute('href');
      if (targetId === '#') return;

      const target = document.querySelector(targetId);
      if (target) {
        e.preventDefault();
        target.scrollIntoView({
          behavior: 'smooth',
          block: 'start'
        });
      }
    });
  });

  // ================================
  // DaisyUI Tooltip Support
  // (DaisyUI tooltips work via data-tip attribute, no JS needed)
  // For any legacy data-bs-toggle="tooltip" elements, convert them
  // ================================
  const legacyTooltips = document.querySelectorAll('[data-bs-toggle="tooltip"]');
  legacyTooltips.forEach(function(el) {
    const title = el.getAttribute('title') || el.getAttribute('data-bs-title');
    if (title) {
      el.setAttribute('data-tip', title);
      el.classList.add('tooltip');
      el.removeAttribute('title'); // Prevent browser default tooltip
    }
  });

  // ================================
  // Form Validation Styling
  // ================================
  const forms = document.querySelectorAll('.needs-validation');
  forms.forEach(function(form) {
    form.addEventListener('submit', function(event) {
      if (!form.checkValidity()) {
        event.preventDefault();
        event.stopPropagation();
      }
      form.classList.add('was-validated');
    }, false);
  });

  // ================================
  // Mobile Drawer Close on Link Click
  // (For DaisyUI drawer navigation)
  // ================================
  const drawerToggle = document.getElementById('mobile-drawer');
  const drawerLinks = document.querySelectorAll('.drawer-side a');

  drawerLinks.forEach(function(link) {
    link.addEventListener('click', function() {
      if (drawerToggle && drawerToggle.checked) {
        drawerToggle.checked = false;
      }
    });
  });

  // ================================
  // Close DaisyUI dropdowns on click outside
  // ================================
  document.addEventListener('click', function(e) {
    const openDetails = document.querySelectorAll('details[open]');
    openDetails.forEach(function(details) {
      if (!details.contains(e.target)) {
        details.removeAttribute('open');
      }
    });
  });

})();
