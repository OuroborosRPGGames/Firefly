/**
 * Grammar Checker Module
 * Provides Grammarly-like inline grammar/spelling feedback.
 * Attaches to contenteditable divs and textareas via data-grammar-check attribute.
 */
class GrammarChecker {
  constructor(element, options = {}) {
    this.element = typeof element === 'string' ? document.querySelector(element) : element;
    if (!this.element) return;

    this.options = {
      minLength: parseInt(this.element.dataset.grammarMinLength) || 30,
      debounceMs: 800,
      apiEndpoint: '/api/grammar/check',
      languagesEndpoint: '/api/grammar/languages',
      ...options
    };

    this.isContentEditable = this.element.isContentEditable;
    this.isTextarea = this.element.tagName === 'TEXTAREA';
    this.errors = [];
    this.lastCheckedText = '';
    this.requestId = 0;
    this.debounceTimer = null;
    this.abortController = null;
    this.enabled = localStorage.getItem('grammarCheckEnabled') !== 'false';
    this.availableLanguages = [];
    this.tooltip = null;
    this.overlay = null;

    this.init();
  }

  async init() {
    try {
      const resp = await fetch(this.options.languagesEndpoint);
      const data = await resp.json();
      this.availableLanguages = data.languages || [];
    } catch (e) {
      return;
    }

    if (this.availableLanguages.length === 0) return;

    this.element.setAttribute('spellcheck', 'false');

    if (this.isTextarea) {
      this.setupTextareaOverlay();
    }

    this.element.addEventListener('input', () => this.onInput());
    this.element.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') this.hideTooltip();
    });

    if (this.isContentEditable) {
      this.element.addEventListener('click', (e) => this.onMarkClick(e));
    }
  }

  onInput() {
    if (!this.enabled) return;
    clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => this.checkText(), this.options.debounceMs);
  }

  getPlainText() {
    if (this.isContentEditable) {
      return this.element.innerText || '';
    }
    return this.element.value || '';
  }

  async checkText() {
    const text = this.getPlainText();

    if (text.length < this.options.minLength) {
      this.clearErrors();
      return;
    }

    if (text === this.lastCheckedText) return;

    if (this.abortController) {
      this.abortController.abort();
    }

    const currentRequestId = ++this.requestId;
    this.abortController = new AbortController();

    try {
      const resp = await fetch(this.options.apiEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, language: this.detectLanguage() }),
        signal: this.abortController.signal
      });

      if (currentRequestId !== this.requestId) return;
      if (resp.status === 429 || !resp.ok) return;

      const data = await resp.json();
      if (!data.success) return;

      // Only mark as checked after successful response
      this.lastCheckedText = text;

      this.errors = (data.matches || []).map((m, i) => ({
        id: i,
        offset: m.offset,
        length: m.length,
        message: m.message,
        replacements: (m.replacements || []).slice(0, 5).map(r => r.value),
        type: this.categorizeError(m)
      }));

      this.renderErrors();
    } catch (e) {
      if (e.name === 'AbortError') return;
    }
  }

  detectLanguage() {
    if (this.availableLanguages.length > 0) {
      const code = this.availableLanguages[0].code;
      if (code === 'en') return 'en-US';
      return code;
    }
    return 'en-US';
  }

  categorizeError(match) {
    const cat = match.rule?.category?.id || '';
    if (cat === 'TYPOS' || cat === 'SPELLING') return 'spelling';
    if (cat === 'STYLE' || cat === 'REDUNDANCY') return 'style';
    return 'grammar';
  }

  clearErrors() {
    this.errors = [];
    if (this.isContentEditable) {
      this.clearContentEditableMarks();
    } else if (this.isTextarea && this.overlay) {
      this.overlay.innerHTML = '';
    }
    this.hideTooltip();
  }

  toggle() {
    this.enabled = !this.enabled;
    localStorage.setItem('grammarCheckEnabled', this.enabled);
    if (!this.enabled) {
      this.clearErrors();
    } else {
      this.lastCheckedText = '';
      this.checkText();
    }
  }

  // === Tooltip ===

  showTooltip(errorData, anchorElement) {
    this.hideTooltip();

    const tooltip = document.createElement('div');
    tooltip.className = 'grammar-tooltip';

    const message = document.createElement('div');
    message.className = 'grammar-tooltip-message';
    message.textContent = errorData.message;
    tooltip.appendChild(message);

    if (errorData.replacements.length > 0) {
      const replacements = document.createElement('div');
      replacements.className = 'grammar-tooltip-replacements';
      errorData.replacements.forEach(replacement => {
        const btn = document.createElement('button');
        btn.className = 'grammar-tooltip-replacement';
        btn.textContent = replacement;
        btn.addEventListener('click', () => {
          this.applyReplacement(errorData, replacement);
          this.hideTooltip();
        });
        replacements.appendChild(btn);
      });
      tooltip.appendChild(replacements);
    }

    const dismiss = document.createElement('button');
    dismiss.className = 'grammar-tooltip-dismiss';
    dismiss.textContent = 'Dismiss';
    dismiss.addEventListener('click', () => {
      this.dismissError(errorData.id);
      this.hideTooltip();
    });
    tooltip.appendChild(dismiss);

    document.body.appendChild(tooltip);
    this.tooltip = tooltip;

    const rect = anchorElement.getBoundingClientRect();
    tooltip.style.left = `${rect.left + window.scrollX}px`;
    tooltip.style.top = `${rect.bottom + window.scrollY + 4}px`;

    setTimeout(() => {
      document.addEventListener('click', this._outsideClickHandler = (e) => {
        if (!tooltip.contains(e.target) && !anchorElement.contains(e.target)) {
          this.hideTooltip();
        }
      });
    }, 0);
  }

  hideTooltip() {
    if (this.tooltip) {
      this.tooltip.remove();
      this.tooltip = null;
    }
    if (this._outsideClickHandler) {
      document.removeEventListener('click', this._outsideClickHandler);
      this._outsideClickHandler = null;
    }
  }

  dismissError(errorId) {
    this.errors = this.errors.filter(e => e.id !== errorId);
    this.renderErrors();
  }

  // === Contenteditable Rendering ===

  onMarkClick(e) {
    const mark = e.target.closest('mark.grammar-error');
    if (!mark) return;
    const errorId = parseInt(mark.dataset.grammarId);
    const error = this.errors.find(err => err.id === errorId);
    if (error) {
      e.preventDefault();
      e.stopPropagation();
      this.showTooltip(error, mark);
    }
  }

  renderErrors() {
    if (this.isContentEditable) {
      this.renderContentEditableErrors();
    } else if (this.isTextarea) {
      this.renderTextareaErrors();
    }
  }

  renderContentEditableErrors() {
    const cursorOffset = this.saveCursorAsTextOffset();
    this.clearContentEditableMarks();

    if (this.errors.length === 0) {
      if (cursorOffset !== null) this.restoreCursorFromTextOffset(cursorOffset);
      return;
    }

    const { textContent, offsetMap } = this.buildContentEditableOffsetMap();
    const sortedErrors = [...this.errors].sort((a, b) => b.offset - a.offset);

    for (const error of sortedErrors) {
      const startOffset = error.offset;
      const endOffset = error.offset + error.length;
      if (startOffset >= textContent.length || endOffset > textContent.length) continue;

      const startPos = this.textOffsetToDomPosition(offsetMap, startOffset);
      const endPos = this.textOffsetToDomPosition(offsetMap, endOffset);
      if (!startPos || !endPos || startPos.node !== endPos.node) continue;

      try {
        const range = document.createRange();
        range.setStart(startPos.node, startPos.offset);
        range.setEnd(endPos.node, endPos.offset);

        const mark = document.createElement('mark');
        mark.className = `grammar-error grammar-error-${error.type}`;
        mark.dataset.grammarId = error.id;
        range.surroundContents(mark);
      } catch (e) {
        // DOM manipulation failed — skip
      }
    }

    if (cursorOffset !== null) {
      this.restoreCursorFromTextOffset(cursorOffset);
    }
  }

  clearContentEditableMarks() {
    const marks = this.element.querySelectorAll('mark.grammar-error');
    marks.forEach(mark => {
      const parent = mark.parentNode;
      while (mark.firstChild) {
        parent.insertBefore(mark.firstChild, mark);
      }
      parent.removeChild(mark);
      parent.normalize();
    });
  }

  saveCursorAsTextOffset() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return null;
    const range = sel.getRangeAt(0);
    if (!this.element.contains(range.startContainer)) return null;

    const walker = document.createTreeWalker(this.element, NodeFilter.SHOW_TEXT);
    let offset = 0;
    let node;
    while ((node = walker.nextNode())) {
      if (node === range.startContainer) return offset + range.startOffset;
      offset += node.textContent.length;
    }
    return null;
  }

  restoreCursorFromTextOffset(targetOffset) {
    try {
      const walker = document.createTreeWalker(this.element, NodeFilter.SHOW_TEXT);
      let offset = 0;
      let node;
      while ((node = walker.nextNode())) {
        const len = node.textContent.length;
        if (offset + len >= targetOffset) {
          const sel = window.getSelection();
          const range = document.createRange();
          range.setStart(node, targetOffset - offset);
          range.collapse(true);
          sel.removeAllRanges();
          sel.addRange(range);
          return;
        }
        offset += len;
      }
    } catch (e) {
      // Cursor restoration failed — do not disrupt typing
    }
  }

  buildContentEditableOffsetMap() {
    const walker = document.createTreeWalker(this.element, NodeFilter.SHOW_TEXT);
    const offsetMap = [];
    let textContent = '';
    let node;
    while ((node = walker.nextNode())) {
      offsetMap.push({ node, start: textContent.length, length: node.textContent.length });
      textContent += node.textContent;
    }
    return { textContent, offsetMap };
  }

  textOffsetToDomPosition(offsetMap, textOffset) {
    for (const entry of offsetMap) {
      if (textOffset >= entry.start && textOffset <= entry.start + entry.length) {
        return { node: entry.node, offset: textOffset - entry.start };
      }
    }
    return null;
  }

  // === Textarea Overlay ===

  setupTextareaOverlay() {
    const wrapper = document.createElement('div');
    wrapper.className = 'grammar-overlay-wrapper';
    this.element.parentNode.insertBefore(wrapper, this.element);
    wrapper.appendChild(this.element);

    this.overlay = document.createElement('div');
    this.overlay.className = 'grammar-overlay';
    wrapper.insertBefore(this.overlay, this.element);

    this.syncOverlayStyles();

    this.resizeObserver = new ResizeObserver(() => this.syncOverlayStyles());
    this.resizeObserver.observe(this.element);

    this.element.addEventListener('scroll', () => {
      this.overlay.scrollTop = this.element.scrollTop;
      this.overlay.scrollLeft = this.element.scrollLeft;
    });

    this.overlay.addEventListener('click', (e) => {
      const mark = e.target.closest('mark.grammar-error');
      if (!mark) return;
      const errorId = parseInt(mark.dataset.grammarId);
      const error = this.errors.find(err => err.id === errorId);
      if (error) this.showTooltip(error, mark);
    });
  }

  syncOverlayStyles() {
    const cs = window.getComputedStyle(this.element);
    const props = [
      'fontFamily', 'fontSize', 'fontWeight', 'lineHeight', 'letterSpacing',
      'wordSpacing', 'textIndent', 'padding', 'paddingTop', 'paddingRight',
      'paddingBottom', 'paddingLeft', 'borderWidth', 'borderTopWidth',
      'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
      'boxSizing', 'width', 'height'
    ];
    for (const prop of props) {
      this.overlay.style[prop] = cs[prop];
    }
    this.overlay.style.borderColor = 'transparent';
  }

  renderTextareaErrors() {
    if (!this.overlay) return;
    const text = this.element.value;

    if (this.errors.length === 0) {
      this.overlay.innerHTML = '';
      return;
    }

    let html = '';
    let lastEnd = 0;
    const sortedErrors = [...this.errors].sort((a, b) => a.offset - b.offset);

    for (const error of sortedErrors) {
      if (error.offset < lastEnd) continue;
      if (error.offset > lastEnd) {
        html += this.escapeHtml(text.substring(lastEnd, error.offset));
      }
      const errorText = text.substring(error.offset, error.offset + error.length);
      html += `<mark class="grammar-error grammar-error-${error.type}" data-grammar-id="${error.id}">${this.escapeHtml(errorText)}</mark>`;
      lastEnd = error.offset + error.length;
    }
    if (lastEnd < text.length) {
      html += this.escapeHtml(text.substring(lastEnd));
    }

    this.overlay.innerHTML = html;
  }

  applyReplacement(errorData, replacement) {
    if (this.isContentEditable) {
      const mark = this.element.querySelector(`mark[data-grammar-id="${errorData.id}"]`);
      if (mark) {
        mark.replaceWith(document.createTextNode(replacement));
        this.element.normalize();
      }
    } else if (this.isTextarea) {
      const text = this.element.value;
      this.element.value =
        text.substring(0, errorData.offset) +
        replacement +
        text.substring(errorData.offset + errorData.length);
      this.element.dispatchEvent(new Event('input', { bubbles: true }));
    }

    this.dismissError(errorData.id);
    this.lastCheckedText = '';
  }

  escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  }
}

// Auto-attach on DOMContentLoaded
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('[data-grammar-check]').forEach(el => {
    new GrammarChecker(el);
  });
});
