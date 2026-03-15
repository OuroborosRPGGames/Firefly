/**
 * Modal System Controller
 * Handles opening, closing, focus management, and keyboard navigation for modals
 */
class ModalManager {
  constructor() {
    this.activeModal = null;
    this.previousFocus = null;
    this.init();
  }

  init() {
    // Delegate click handlers
    document.addEventListener('click', (e) => {
      const openTrigger = e.target.closest('[data-modal-open]');
      const closeTrigger = e.target.closest('[data-modal-close]');

      if (openTrigger) {
        e.preventDefault();
        this.open(openTrigger.dataset.modalOpen);
      }

      if (closeTrigger && this.activeModal) {
        // Only close if clicking overlay/container directly, not modal content
        if (closeTrigger.classList.contains('modal-overlay') ||
            closeTrigger.classList.contains('modal-container') ||
            closeTrigger.classList.contains('modal-close')) {
          this.close();
        }
      }
    });

    // Keyboard handling
    document.addEventListener('keydown', (e) => {
      if (!this.activeModal) return;

      if (e.key === 'Escape') {
        this.close();
      }

      if (e.key === 'Tab') {
        this.trapFocus(e);
      }
    });
  }

  open(modalId) {
    const overlay = document.getElementById(`${modalId}-overlay`);
    if (!overlay) return;

    // Store previous focus for restoration
    this.previousFocus = document.activeElement;
    this.activeModal = modalId;

    // Show and animate
    overlay.style.display = 'block';
    const dialog = overlay.querySelector('.modal-dialog');

    requestAnimationFrame(() => {
      overlay.classList.add('animate__fadeIn');
      dialog.classList.add('modal-dialog--elegant-enter');
    });

    // Focus first input or close button
    const focusTarget = dialog.querySelector('input, textarea, select, .modal-close');
    if (focusTarget) focusTarget.focus();

    // Prevent body scroll
    document.body.style.overflow = 'hidden';

    // Dispatch custom event
    overlay.dispatchEvent(new CustomEvent('modal:open', { bubbles: true }));
  }

  close() {
    if (!this.activeModal) return;

    const overlay = document.getElementById(`${this.activeModal}-overlay`);
    if (!overlay) return;

    const dialog = overlay.querySelector('.modal-dialog');

    // Animate out
    overlay.classList.remove('animate__fadeIn');
    overlay.classList.add('animate__fadeOut');
    dialog.classList.remove('modal-dialog--elegant-enter');
    dialog.classList.add('modal-dialog--elegant-exit');

    // Clean up after animation
    const modalId = this.activeModal;
    setTimeout(() => {
      overlay.style.display = 'none';
      overlay.classList.remove('animate__fadeOut');
      dialog.classList.remove('modal-dialog--elegant-exit');
      document.body.style.overflow = '';

      // Restore focus
      if (this.previousFocus) this.previousFocus.focus();
      this.activeModal = null;

      // Dispatch custom event
      overlay.dispatchEvent(new CustomEvent('modal:close', { bubbles: true }));
    }, 200);
  }

  trapFocus(e) {
    const overlay = document.getElementById(`${this.activeModal}-overlay`);
    if (!overlay) return;

    const focusable = overlay.querySelectorAll(
      'button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'
    );

    if (focusable.length === 0) return;

    const first = focusable[0];
    const last = focusable[focusable.length - 1];

    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }
}

// Initialize on DOM ready
document.addEventListener('DOMContentLoaded', () => {
  window.modalManager = new ModalManager();
});

/**
 * Bootstrap Modal Compatibility Shim
 * Provides a bootstrap.Modal compatible API for DaisyUI dialogs
 */
class BootstrapModalShim {
  constructor(element, options = {}) {
    this.element = typeof element === 'string' ? document.querySelector(element) : element;
    this.options = options;
    this._isShown = false;

    // Check if this is a DaisyUI dialog (has <dialog> tag or .modal class with checkbox)
    this.dialog = this.element.tagName === 'DIALOG' ? this.element : this.element.querySelector('dialog');
    this.checkbox = this.element.querySelector('input[type="checkbox"]');

    // Store instance on element
    if (this.element) {
      this.element._bsModal = this;
    }
  }

  show() {
    if (this.dialog) {
      this.dialog.showModal();
    } else if (this.checkbox) {
      this.checkbox.checked = true;
    } else if (this.element.classList.contains('modal')) {
      // Fallback: add 'modal-open' class approach
      this.element.classList.add('modal-open');
    }
    this._isShown = true;
    this.element.dispatchEvent(new CustomEvent('shown.bs.modal'));
  }

  hide() {
    if (this.dialog) {
      this.dialog.close();
    } else if (this.checkbox) {
      this.checkbox.checked = false;
    } else if (this.element.classList.contains('modal')) {
      this.element.classList.remove('modal-open');
    }
    this._isShown = false;
    this.element.dispatchEvent(new CustomEvent('hidden.bs.modal'));
  }

  toggle() {
    if (this._isShown) {
      this.hide();
    } else {
      this.show();
    }
  }

  static getInstance(element) {
    const el = typeof element === 'string' ? document.querySelector(element) : element;
    return el?._bsModal || null;
  }

  static getOrCreateInstance(element, options) {
    return BootstrapModalShim.getInstance(element) || new BootstrapModalShim(element, options);
  }
}

// Create global bootstrap namespace if it doesn't exist
window.bootstrap = window.bootstrap || {};
window.bootstrap.Modal = BootstrapModalShim;

/**
 * Bootstrap Collapse Compatibility Shim
 * Works with DaisyUI collapse components
 */
class BootstrapCollapseShim {
  constructor(element, options = {}) {
    this.element = typeof element === 'string' ? document.querySelector(element) : element;
    this.options = options;
    this._isShown = false;

    // Check if this is a DaisyUI collapse (has checkbox input)
    this.checkbox = this.element.closest('.collapse')?.querySelector('input[type="checkbox"]');

    if (this.element) {
      this.element._bsCollapse = this;
    }

    if (options.show) {
      this.show();
    }
  }

  show() {
    if (this.checkbox) {
      this.checkbox.checked = true;
    } else {
      this.element.classList.add('show');
    }
    this._isShown = true;
    this.element.dispatchEvent(new CustomEvent('shown.bs.collapse'));
  }

  hide() {
    if (this.checkbox) {
      this.checkbox.checked = false;
    } else {
      this.element.classList.remove('show');
    }
    this._isShown = false;
    this.element.dispatchEvent(new CustomEvent('hidden.bs.collapse'));
  }

  toggle() {
    if (this._isShown) {
      this.hide();
    } else {
      this.show();
    }
  }

  static getInstance(element) {
    const el = typeof element === 'string' ? document.querySelector(element) : element;
    return el?._bsCollapse || null;
  }
}

window.bootstrap.Collapse = BootstrapCollapseShim;

/**
 * Bootstrap Toast Compatibility Shim
 * Creates DaisyUI-style toast notifications
 */
class BootstrapToastShim {
  constructor(element, options = {}) {
    this.element = typeof element === 'string' ? document.querySelector(element) : element;
    this.options = {
      autohide: true,
      delay: 3000,
      ...options
    };

    if (this.element) {
      this.element._bsToast = this;
    }
  }

  show() {
    if (!this.element) return;

    this.element.style.display = 'block';
    this.element.classList.add('show');
    this.element.dispatchEvent(new CustomEvent('shown.bs.toast'));

    if (this.options.autohide) {
      setTimeout(() => this.hide(), this.options.delay);
    }
  }

  hide() {
    if (!this.element) return;

    this.element.style.transition = 'opacity 0.3s';
    this.element.style.opacity = '0';

    setTimeout(() => {
      this.element.classList.remove('show');
      this.element.style.display = 'none';
      this.element.style.opacity = '';
      this.element.dispatchEvent(new CustomEvent('hidden.bs.toast'));
    }, 300);
  }

  static getInstance(element) {
    const el = typeof element === 'string' ? document.querySelector(element) : element;
    return el?._bsToast || null;
  }
}

window.bootstrap.Toast = BootstrapToastShim;

/**
 * Bootstrap Tab Compatibility Shim
 * Works with custom tab implementations
 */
class BootstrapTabShim {
  constructor(element) {
    this.element = typeof element === 'string' ? document.querySelector(element) : element;

    if (this.element) {
      this.element._bsTab = this;
    }
  }

  show() {
    if (!this.element) return;

    const targetId = this.element.dataset.target || this.element.dataset.bsTarget;
    const tabList = this.element.closest('[role="tablist"]') || this.element.closest('.tabs');

    if (tabList) {
      // Deactivate all tabs
      tabList.querySelectorAll('.tab, .nav-link, [role="tab"]').forEach(t => {
        t.classList.remove('tab-active', 'active');
        t.setAttribute('aria-selected', 'false');
      });

      // Activate this tab
      this.element.classList.add('tab-active', 'active');
      this.element.setAttribute('aria-selected', 'true');
    }

    // Show target panel
    if (targetId) {
      const targetSelector = targetId.startsWith('#') ? targetId : `#${targetId}`;
      const panel = document.querySelector(targetSelector);

      if (panel) {
        // Hide all sibling panels
        const container = panel.parentElement;
        container.querySelectorAll('.tab-pane, .tab-panel, [role="tabpanel"]').forEach(p => {
          p.classList.remove('show', 'active');
          p.classList.add('hidden');
        });

        // Show target panel
        panel.classList.add('show', 'active');
        panel.classList.remove('hidden');
      }
    }

    this.element.dispatchEvent(new CustomEvent('shown.bs.tab'));
  }

  static getInstance(element) {
    const el = typeof element === 'string' ? document.querySelector(element) : element;
    return el?._bsTab || null;
  }
}

window.bootstrap.Tab = BootstrapTabShim;
