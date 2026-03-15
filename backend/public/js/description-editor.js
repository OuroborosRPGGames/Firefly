/**
 * Description Editor Component
 * Provides rich text editing with HTML color/styling support
 * Based on webclient patterns using contenteditable and execCommand
 */
class DescriptionEditor {
  constructor(container, options = {}) {
    this.container = typeof container === 'string' ? document.querySelector(container) : container;
    this.options = {
      placeholder: 'Enter your description...',
      maxLength: 5000,
      onChange: null,
      enableGradients: true,
      gradientApiEndpoint: '/api/gradients',
      enableGrammarCheck: false,
      ...options
    };

    this.colorMap = {
      'r': '#ff6b6b',
      'o': '#ff922b',
      'y': '#ffd43b',
      'g': '#51cf66',
      'c': '#66d9ef',
      'b': '#74c0fc',
      'm': '#da77f2',
      'w': '#ffffff'
    };

    this.gradientPicker = null;
    this.savedSelection = null;
    this.currentColor = '#00bcd4';

    // Load recent colors from localStorage
    this.recentColors = this.loadRecentColors();
    this.maxRecentColors = 8;

    this.init();
  }

  loadRecentColors() {
    try {
      const stored = localStorage.getItem('descEditorRecentColors');
      return stored ? JSON.parse(stored) : [];
    } catch {
      return [];
    }
  }

  saveRecentColors() {
    try {
      localStorage.setItem('descEditorRecentColors', JSON.stringify(this.recentColors));
    } catch {
      // Ignore storage errors
    }
  }

  addRecentColor(color) {
    // Normalize color to lowercase hex
    const normalizedColor = color.toLowerCase();

    // Remove if already exists
    this.recentColors = this.recentColors.filter(c => c.toLowerCase() !== normalizedColor);

    // Add to front
    this.recentColors.unshift(normalizedColor);

    // Limit size
    if (this.recentColors.length > this.maxRecentColors) {
      this.recentColors = this.recentColors.slice(0, this.maxRecentColors);
    }

    this.saveRecentColors();
    this.updateRecentColorsDisplay();
  }

  init() {
    this.render();
    this.bindEvents();
    this.initGradientPicker();

    if (this.options.enableGrammarCheck && typeof GrammarChecker !== 'undefined') {
      this.grammarChecker = new GrammarChecker(this.content);
    }
  }

  render() {
    this.container.innerHTML = `
      <div class="desc-editor">
        <div class="desc-editor-toolbar">
          <button type="button" class="desc-editor-btn" data-action="bold" title="Bold (Ctrl+B)"><strong>B</strong></button>
          <button type="button" class="desc-editor-btn" data-action="italic" title="Italic (Ctrl+I)"><em>I</em></button>
          <button type="button" class="desc-editor-btn" data-action="underline" title="Underline (Ctrl+U)"><u>U</u></button>
          <button type="button" class="desc-editor-btn" data-action="strikeThrough" title="Strikethrough"><s>S</s></button>
          <div class="desc-editor-separator"></div>
          <div class="desc-editor-color-picker">
            <button type="button" class="desc-editor-btn desc-editor-color-btn" title="Text Color (click to apply current, hold for picker)">
              A<span class="color-indicator" style="background:#00bcd4"></span>
            </button>
            <div class="desc-editor-color-popup">
              <div class="color-section">
                <div class="color-section-title">Pick Color</div>
                <div class="color-picker-row">
                  <input type="color" class="custom-color-input" value="#00bcd4">
                  <button type="button" class="color-apply-btn" title="Apply to selection">Apply</button>
                </div>
              </div>
              <div class="color-section color-recent-section">
                <div class="color-section-title">Recent</div>
                <div class="color-grid color-recent-grid"></div>
              </div>
              <div class="color-section">
                <div class="color-section-title">Presets</div>
                <div class="color-grid">
                  <button type="button" class="color-swatch" style="background:#ff6b6b" data-color="#ff6b6b" title="Red"></button>
                  <button type="button" class="color-swatch" style="background:#ff922b" data-color="#ff922b" title="Orange"></button>
                  <button type="button" class="color-swatch" style="background:#ffd43b" data-color="#ffd43b" title="Yellow"></button>
                  <button type="button" class="color-swatch" style="background:#51cf66" data-color="#51cf66" title="Green"></button>
                  <button type="button" class="color-swatch" style="background:#66d9ef" data-color="#66d9ef" title="Cyan"></button>
                  <button type="button" class="color-swatch" style="background:#74c0fc" data-color="#74c0fc" title="Blue"></button>
                  <button type="button" class="color-swatch" style="background:#da77f2" data-color="#da77f2" title="Magenta"></button>
                  <button type="button" class="color-swatch" style="background:#ffffff" data-color="#ffffff" title="White"></button>
                </div>
              </div>
            </div>
          </div>
          <div class="desc-editor-gradient-picker"></div>
        </div>
        <div class="desc-editor-content" contenteditable="true" data-placeholder="${this.options.placeholder}"></div>
        <div class="desc-editor-footer">
          <span class="char-count">0 / ${this.options.maxLength}</span>
        </div>
      </div>
    `;

    this.toolbar = this.container.querySelector('.desc-editor-toolbar');
    this.content = this.container.querySelector('.desc-editor-content');
    this.colorBtn = this.container.querySelector('.desc-editor-color-btn');
    this.colorPopup = this.container.querySelector('.desc-editor-color-popup');
    this.colorIndicator = this.container.querySelector('.color-indicator');
    this.customColorInput = this.container.querySelector('.custom-color-input');
    this.colorApplyBtn = this.container.querySelector('.color-apply-btn');
    this.recentColorsGrid = this.container.querySelector('.color-recent-grid');
    this.charCount = this.container.querySelector('.char-count');

    // Initialize recent colors display
    this.updateRecentColorsDisplay();
  }

  updateRecentColorsDisplay() {
    if (!this.recentColorsGrid) return;

    const recentSection = this.container.querySelector('.color-recent-section');

    if (this.recentColors.length === 0) {
      recentSection.style.display = 'none';
      return;
    }

    recentSection.style.display = 'block';
    this.recentColorsGrid.innerHTML = this.recentColors.map(color =>
      `<button type="button" class="color-swatch color-recent" style="background:${color}" data-color="${color}" title="${color}"></button>`
    ).join('');

    // Rebind events for recent colors - use mousedown to prevent selection loss
    this.recentColorsGrid.querySelectorAll('.color-swatch').forEach(swatch => {
      swatch.addEventListener('mousedown', (e) => {
        e.preventDefault(); // Prevent focus shift that loses selection
      });
      swatch.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const color = swatch.dataset.color;
        this.applyColorToSelection(color);
      });
    });
  }

  bindEvents() {
    // Toolbar buttons
    this.toolbar.querySelectorAll('.desc-editor-btn[data-action]').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        const action = btn.dataset.action;
        this.applyFormat(action);
      });
    });

    // Color picker toggle - save selection before opening
    this.colorBtn.addEventListener('mousedown', (e) => {
      // Save selection on mousedown (before focus changes)
      this.saveSelection();
    });

    this.colorBtn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();

      if (this.colorPopup.classList.contains('show')) {
        this.colorPopup.classList.remove('show');
      } else {
        // Update custom color input to current color
        this.customColorInput.value = this.currentColor;
        this.colorPopup.classList.add('show');
      }
    });

    // Preset color swatches - use mousedown to prevent selection loss
    this.colorPopup.querySelectorAll('.color-grid:not(.color-recent-grid) .color-swatch').forEach(swatch => {
      swatch.addEventListener('mousedown', (e) => {
        e.preventDefault(); // Prevent focus shift that loses selection
      });
      swatch.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const color = swatch.dataset.color;
        this.applyColorToSelection(color);
      });
    });

    // Custom color input - update preview live but don't apply until button clicked
    this.customColorInput.addEventListener('input', (e) => {
      // Update the indicator to show preview
      this.colorIndicator.style.background = e.target.value;
    });

    // Apply button for custom color - use mousedown to prevent selection loss
    this.colorApplyBtn.addEventListener('mousedown', (e) => {
      e.preventDefault(); // Prevent focus shift that loses selection
    });
    this.colorApplyBtn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      const color = this.customColorInput.value;
      this.applyColorToSelection(color);
    });

    // Close color popup when clicking outside
    document.addEventListener('click', (e) => {
      if (!this.colorPopup.contains(e.target) && !this.colorBtn.contains(e.target)) {
        this.colorPopup.classList.remove('show');
      }
    });

    // Content input events
    this.content.addEventListener('input', () => {
      this.updateCharCount();
      if (this.options.onChange) {
        this.options.onChange(this.getContent());
      }
    });

    // Keyboard shortcuts
    this.content.addEventListener('keydown', (e) => {
      if (e.ctrlKey || e.metaKey) {
        switch(e.key.toLowerCase()) {
          case 'b':
            e.preventDefault();
            this.applyFormat('bold');
            break;
          case 'i':
            e.preventDefault();
            this.applyFormat('italic');
            break;
          case 'u':
            e.preventDefault();
            this.applyFormat('underline');
            break;
        }
      }
    });

    // Paste as plain text (optional - can be toggled)
    this.content.addEventListener('paste', (e) => {
      // Allow HTML paste for now (users may paste styled content)
    });

  }

  applyFormat(action) {
    this.content.focus();
    document.execCommand(action, false, null);
  }

  applyColor(color) {
    this.content.focus();
    document.execCommand('foreColor', false, color);
  }

  applyColorToSelection(color) {
    // Update current color
    this.currentColor = color;
    this.colorIndicator.style.background = color;

    // Add to recent colors
    this.addRecentColor(color);

    // Close popup
    this.colorPopup.classList.remove('show');

    // Restore selection and apply color
    this.content.focus();
    if (this.restoreSelection()) {
      document.execCommand('foreColor', false, color);
    } else {
      // No selection - just set the color for new typing
      document.execCommand('foreColor', false, color);
    }

    // Trigger change callback
    if (this.options.onChange) {
      this.options.onChange(this.getContent());
    }
  }

  updateCharCount() {
    const text = this.content.textContent || '';
    const count = text.length;
    this.charCount.textContent = `${count} / ${this.options.maxLength}`;

    if (count > this.options.maxLength) {
      this.charCount.classList.add('over-limit');
    } else {
      this.charCount.classList.remove('over-limit');
    }
  }

  getContent() {
    return this.content.innerHTML;
  }

  setContent(html) {
    // Note: innerHTML is intentional here - content comes from the rich text editor
    this.content.innerHTML = html || '';
    this.updateCharCount();
  }

  getText() {
    return this.content.textContent || '';
  }

  clear() {
    this.content.innerHTML = '';
    this.updateCharCount();
  }

  focus() {
    this.content.focus();
  }

  isValid() {
    const text = this.getText();
    return text.length > 0 && text.length <= this.options.maxLength;
  }

  /**
   * Initialize gradient picker if enabled and GradientPicker class is available
   */
  initGradientPicker() {
    if (!this.options.enableGradients) return;
    if (typeof GradientPicker === 'undefined') {
      console.warn('GradientPicker not loaded - gradient features disabled');
      return;
    }

    const container = this.container.querySelector('.desc-editor-gradient-picker');
    if (!container) return;

    this.gradientPicker = new GradientPicker({
      buttonContainer: container,
      apiEndpoint: this.options.gradientApiEndpoint,
      position: 'above',
      onSelect: (gradient) => this.applyGradientToSelection(gradient)
    });

    // Save selection when gradient picker button is clicked
    if (this.gradientPicker.button) {
      this.gradientPicker.button.addEventListener('mousedown', () => {
        this.saveSelection();
      });
    }
  }

  /**
   * Save current selection for restoration after popup interaction
   */
  saveSelection() {
    const selection = window.getSelection();
    if (selection.rangeCount > 0) {
      this.savedSelection = selection.getRangeAt(0).cloneRange();
    }
  }

  /**
   * Restore saved selection
   */
  restoreSelection() {
    if (!this.savedSelection) return false;

    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(this.savedSelection);
    return true;
  }

  /**
   * Apply gradient to selected text
   * @param {Object} gradient - Gradient object with colors and easings
   */
  applyGradientToSelection(gradient) {
    if (!gradient || !gradient.colors || gradient.colors.length < 2) {
      console.warn('Invalid gradient provided');
      return;
    }

    // Focus the editor first
    this.content.focus();

    // Restore selection if saved
    this.restoreSelection();

    const selection = window.getSelection();
    if (!selection.rangeCount) return;

    const range = selection.getRangeAt(0);

    // Check if selection is within our editor
    if (!this.content.contains(range.commonAncestorContainer)) {
      console.warn('Selection is not within the editor');
      return;
    }

    // Get selected text
    const selectedText = range.toString();
    if (!selectedText) {
      console.warn('No text selected for gradient');
      return;
    }

    // Generate gradient HTML using GradientGenerator if available
    let gradientHtml;
    if (typeof GradientGenerator !== 'undefined') {
      gradientHtml = GradientGenerator.applyToText(
        selectedText,
        gradient.colors,
        gradient.easings || []
      );
    } else {
      // Fallback: simple alternating colors
      const chars = selectedText.split('');
      gradientHtml = chars.map((char, i) => {
        if (/\s/.test(char)) return char;
        const colorIndex = Math.floor(i * gradient.colors.length / chars.length);
        const color = gradient.colors[Math.min(colorIndex, gradient.colors.length - 1)];
        return `<span style="color:${color}">${escapeHtml(char)}</span>`;
      }).join('');
    }

    // Delete selected content and insert gradient HTML
    range.deleteContents();

    // Create a temporary container to parse the HTML
    const temp = document.createElement('div');
    temp.innerHTML = gradientHtml;

    // Insert nodes
    const fragment = document.createDocumentFragment();
    while (temp.firstChild) {
      fragment.appendChild(temp.firstChild);
    }

    range.insertNode(fragment);

    // Clear selection
    selection.removeAllRanges();

    // Trigger change
    this.updateCharCount();
    if (this.options.onChange) {
      this.options.onChange(this.getContent());
    }
  }

}

// Export for use in other scripts
if (typeof window !== 'undefined') {
  window.DescriptionEditor = DescriptionEditor;
}
