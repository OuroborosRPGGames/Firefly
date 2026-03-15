/**
 * Icon Picker - Emoji and Bootstrap Icon selector for Room Builder
 */
class IconPicker {
  constructor() {
    this.callback = null;
    this.modal = null;
    this.activeTab = 'emoji';
    this.createModal();
  }

  createModal() {
    const dialog = document.createElement('dialog');
    dialog.id = 'iconPickerModal';
    dialog.className = 'modal';
    dialog.innerHTML = `
      <div class="modal-box bg-base-200 max-w-lg">
        <div class="flex justify-between items-center mb-3">
          <h3 class="font-bold text-lg">Choose Icon</h3>
          <form method="dialog"><button class="btn btn-sm btn-circle btn-ghost">\u2715</button></form>
        </div>
        <div role="tablist" class="tabs tabs-bordered mb-3">
          <button role="tab" class="tab tab-active" data-tab="emoji">Emoji</button>
          <button role="tab" class="tab" data-tab="bootstrap">Bootstrap Icons</button>
        </div>
        <input type="text" class="input input-bordered input-sm w-full mb-3" id="iconSearchInput" placeholder="Search...">
        <div id="iconGrid" class="grid grid-cols-8 gap-1 max-h-64 overflow-y-auto p-1"></div>
        <div class="modal-action">
          <button class="btn btn-sm btn-ghost" id="iconPickerClear">Clear Icon</button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    `;
    document.body.appendChild(dialog);
    this.modal = dialog;
    this.setupListeners();
  }

  setupListeners() {
    this.modal.querySelectorAll('[data-tab]').forEach(tab => {
      tab.addEventListener('click', () => {
        this.modal.querySelectorAll('[data-tab]').forEach(t => t.classList.remove('tab-active'));
        tab.classList.add('tab-active');
        this.activeTab = tab.dataset.tab;
        document.getElementById('iconSearchInput').value = '';
        this.renderGrid();
      });
    });

    document.getElementById('iconSearchInput')?.addEventListener('input', (e) => {
      this.renderGrid(e.target.value.toLowerCase());
    });

    document.getElementById('iconPickerClear')?.addEventListener('click', () => {
      if (this.callback) this.callback(null);
      this.modal.close();
    });
  }

  show(callback) {
    this.callback = callback;
    this.renderGrid();
    this.modal.showModal();
  }

  renderGrid(filter = '') {
    const grid = document.getElementById('iconGrid');
    if (!grid) return;

    if (this.activeTab === 'emoji') {
      this.renderEmojiGrid(grid, filter);
    } else {
      this.renderBootstrapGrid(grid, filter);
    }
  }

  renderEmojiGrid(grid, filter) {
    const categories = {
      'Furniture': ['\ud83e\ude91', '\ud83d\udecb\ufe0f', '\ud83d\udecf\ufe0f', '\ud83e\ude9e', '\ud83d\udebf', '\ud83d\udec1', '\ud83d\udebd', '\ud83e\udea3', '\ud83e\uddf4'],
      'Food & Drink': ['\ud83c\udf7a', '\ud83c\udf77', '\u2615', '\ud83c\udf7d\ufe0f', '\ud83e\udd58', '\ud83c\udf5e', '\ud83e\uddc1'],
      'Nature': ['\ud83c\udf3f', '\ud83c\udf33', '\ud83c\udf38', '\ud83c\udf0a', '\ud83d\udd25', '\ud83d\udca7', '\u2b50', '\ud83c\udf19', '\u2600\ufe0f'],
      'Objects': ['\ud83d\udddd\ufe0f', '\ud83d\udcdc', '\u2694\ufe0f', '\ud83d\udee1\ufe0f', '\ud83c\udff9', '\ud83d\udc8e', '\ud83d\udc51', '\ud83d\udd14', '\ud83d\udd6f\ufe0f', '\ud83d\udcda', '\ud83c\udfad', '\ud83c\udfb5'],
      'Buildings': ['\ud83c\udfe0', '\ud83c\udff0', '\u26ea', '\ud83c\udfdb\ufe0f', '\ud83c\udffe', '\u26f2', '\ud83d\uddff'],
      'Signs': ['\u26a0\ufe0f', '\ud83d\udeab', '\u2705', '\u274c', '\u2753', '\ud83d\udc80', '\u2620\ufe0f'],
    };

    let html = '';
    for (const [category, items] of Object.entries(categories)) {
      const matchesCategory = !filter || category.toLowerCase().includes(filter);
      const matchingItems = matchesCategory ? items : items.filter(() => false);
      if (matchingItems.length === 0 && !matchesCategory) continue;

      html += `<div class="col-span-8 text-xs text-base-content/50 mt-1 font-semibold">${category}</div>`;
      matchingItems.forEach(emoji => {
        html += `<button class="btn btn-ghost btn-sm text-xl p-0 h-8 min-h-0" data-icon="${emoji}">${emoji}</button>`;
      });
    }
    grid.innerHTML = html || '<div class="col-span-8 text-base-content/50 text-sm">No matches</div>';

    grid.querySelectorAll('[data-icon]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (this.callback) this.callback(btn.dataset.icon);
        this.modal.close();
      });
    });
  }

  renderBootstrapGrid(grid, filter) {
    const icons = [
      'house', 'door-open', 'door-closed', 'window', 'lamp', 'lightbulb',
      'cup-hot', 'basket', 'bag', 'box', 'book', 'bookshelf',
      'music-note', 'brush', 'palette', 'gem', 'shield', 'sword',
      'tree', 'flower1', 'flower2', 'water', 'fire', 'snow',
      'star', 'heart', 'flag', 'bell', 'key', 'lock',
      'person', 'people', 'chat', 'envelope', 'clock', 'calendar',
      'tools', 'wrench', 'hammer', 'scissors', 'pencil', 'trash',
      'camera', 'image', 'map', 'compass', 'globe', 'pin-map',
      'trophy', 'award', 'gift', 'cart', 'shop', 'coin',
    ];

    const filtered = filter ? icons.filter(i => i.includes(filter)) : icons;
    let html = '';
    filtered.forEach(icon => {
      html += `<button class="btn btn-ghost btn-sm text-lg p-0 h-8 min-h-0" data-icon="bi-${icon}" title="${icon}"><i class="bi bi-${icon}"></i></button>`;
    });
    grid.innerHTML = html || '<div class="col-span-8 text-base-content/50 text-sm">No matches</div>';

    grid.querySelectorAll('[data-icon]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (this.callback) this.callback(btn.dataset.icon);
        this.modal.close();
      });
    });
  }
}

document.addEventListener('DOMContentLoaded', () => {
  window.iconPicker = new IconPicker();
});
