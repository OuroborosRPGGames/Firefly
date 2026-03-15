/**
 * Stat Allocation Manager
 * Handles point allocation for character creation stat blocks.
 * Supports single-type (one pool) and paired-type (two category) blocks.
 */
class StatAllocationManager {
  constructor() {
    this.blocks = new Map();  // blockId -> { config, stats, pointsSpent }
    this.init();
  }

  init() {
    // Find all stat block cards and initialize them
    document.querySelectorAll('.stat-block-card').forEach(card => {
      const blockId = parseInt(card.dataset.blockId);
      const config = {
        id: blockId,
        type: card.dataset.blockType,
        totalPoints: parseInt(card.dataset.totalPoints),
        secondaryPoints: parseInt(card.dataset.secondaryPoints) || 0,
        minValue: parseInt(card.dataset.minValue),
        maxValue: parseInt(card.dataset.maxValue),
        costFormula: card.dataset.costFormula
      };

      // Initialize stats tracking
      const stats = new Map();
      card.querySelectorAll('.stat-row').forEach(row => {
        const statId = parseInt(row.dataset.statId);
        const category = row.dataset.category;
        stats.set(statId, {
          id: statId,
          category: category,
          value: config.minValue
        });
      });

      // Calculate initial cost (min value for all stats)
      const primarySpent = this.calculateCategorySpent(config, stats, 'primary');
      const secondarySpent = this.calculateCategorySpent(config, stats, 'secondary');

      this.blocks.set(blockId, {
        config,
        stats,
        primarySpent,
        secondarySpent
      });

      // Update displays
      this.updatePointsDisplay(blockId);
      this.updateAllButtons(blockId);
    });

    // Bind event handlers
    this.bindEvents();
  }

  bindEvents() {
    // Increase buttons
    document.querySelectorAll('.stat-increase').forEach(btn => {
      btn.addEventListener('click', (e) => {
        const blockId = parseInt(btn.dataset.blockId);
        const statId = parseInt(btn.dataset.statId);
        this.incrementStat(blockId, statId);
      });
    });

    // Decrease buttons
    document.querySelectorAll('.stat-decrease').forEach(btn => {
      btn.addEventListener('click', (e) => {
        const blockId = parseInt(btn.dataset.blockId);
        const statId = parseInt(btn.dataset.statId);
        this.decrementStat(blockId, statId);
      });
    });
  }

  /**
   * Calculate point cost for a specific level based on cost formula
   */
  calculateCostForLevel(level, formula) {
    if (level <= 0) return 0;

    switch (formula) {
      case 'doubling_every_other':
        // 1,1,2,2,3,3,4,4,5,5
        return Math.ceil((level + 1) / 2);
      case 'linear_increasing':
        // 1,2,3,4,5
        return level;
      default:
        return level;
    }
  }

  /**
   * Calculate total cost to reach a level from 0
   */
  calculateTotalCost(level, formula) {
    let total = 0;
    for (let l = 1; l <= level; l++) {
      total += this.calculateCostForLevel(l, formula);
    }
    return total;
  }

  /**
   * Calculate points spent in a category
   */
  calculateCategorySpent(config, stats, category) {
    let spent = 0;
    stats.forEach((stat, statId) => {
      if (category === null || stat.category === category) {
        spent += this.calculateTotalCost(stat.value, config.costFormula);
      }
    });
    return spent;
  }

  /**
   * Get points remaining for a block/category
   */
  getPointsRemaining(blockId, category = null) {
    const block = this.blocks.get(blockId);
    if (!block) return 0;

    if (block.config.type === 'paired') {
      if (category === 'secondary') {
        return block.config.secondaryPoints - block.secondarySpent;
      } else {
        return block.config.totalPoints - block.primarySpent;
      }
    } else {
      // Single type - sum all categories
      const totalSpent = this.calculateCategorySpent(block.config, block.stats, null);
      return block.config.totalPoints - totalSpent;
    }
  }

  /**
   * Increment a stat value
   */
  incrementStat(blockId, statId) {
    const block = this.blocks.get(blockId);
    if (!block) return;

    const stat = block.stats.get(statId);
    if (!stat) return;

    const currentValue = stat.value;
    const newValue = currentValue + 1;

    // Check max value
    if (newValue > block.config.maxValue) return;

    // Calculate cost of this level
    const cost = this.calculateCostForLevel(newValue, block.config.costFormula);

    // Check if enough points
    const category = block.config.type === 'paired' ? stat.category : null;
    const remaining = this.getPointsRemaining(blockId, category);
    if (cost > remaining) return;

    // Update stat
    stat.value = newValue;

    // Update spent tracking
    if (block.config.type === 'paired') {
      if (stat.category === 'secondary') {
        block.secondarySpent += cost;
      } else {
        block.primarySpent += cost;
      }
    }

    // Update UI
    this.updateStatDisplay(blockId, statId);
    this.updatePointsDisplay(blockId);
    this.updateAllButtons(blockId);
  }

  /**
   * Decrement a stat value
   */
  decrementStat(blockId, statId) {
    const block = this.blocks.get(blockId);
    if (!block) return;

    const stat = block.stats.get(statId);
    if (!stat) return;

    const currentValue = stat.value;
    const newValue = currentValue - 1;

    // Check min value
    if (newValue < block.config.minValue) return;

    // Calculate refund for this level
    const refund = this.calculateCostForLevel(currentValue, block.config.costFormula);

    // Update stat
    stat.value = newValue;

    // Update spent tracking
    if (block.config.type === 'paired') {
      if (stat.category === 'secondary') {
        block.secondarySpent -= refund;
      } else {
        block.primarySpent -= refund;
      }
    }

    // Update UI
    this.updateStatDisplay(blockId, statId);
    this.updatePointsDisplay(blockId);
    this.updateAllButtons(blockId);
  }

  /**
   * Update the display for a single stat
   */
  updateStatDisplay(blockId, statId) {
    const block = this.blocks.get(blockId);
    if (!block) return;

    const stat = block.stats.get(statId);
    if (!stat) return;

    // Update value display
    const valueEl = document.querySelector(`.stat-value[data-block-id="${blockId}"][data-stat-id="${statId}"]`);
    if (valueEl) {
      valueEl.textContent = stat.value;
    }

    // Update hidden input
    const inputEl = document.querySelector(`.stat-input[data-block-id="${blockId}"][data-stat-id="${statId}"]`);
    if (inputEl) {
      inputEl.value = stat.value;
    }

    // Update cost display
    const costEl = document.querySelector(`.stat-cost[data-block-id="${blockId}"][data-stat-id="${statId}"]`);
    if (costEl) {
      const nextCost = this.calculateCostForLevel(stat.value + 1, block.config.costFormula);
      costEl.textContent = `(${nextCost})`;
    }
  }

  /**
   * Update the points remaining display for a block
   */
  updatePointsDisplay(blockId) {
    const block = this.blocks.get(blockId);
    if (!block) return;

    if (block.config.type === 'paired') {
      // Primary points
      const primaryEl = document.querySelector(`.primary-points-remaining[data-block-id="${blockId}"]`);
      if (primaryEl) {
        primaryEl.textContent = this.getPointsRemaining(blockId, 'primary');
      }

      // Secondary points
      const secondaryEl = document.querySelector(`.secondary-points-remaining[data-block-id="${blockId}"]`);
      if (secondaryEl) {
        secondaryEl.textContent = this.getPointsRemaining(blockId, 'secondary');
      }
    } else {
      // Single type
      const remainingEl = document.querySelector(`.points-remaining[data-block-id="${blockId}"]`);
      if (remainingEl) {
        remainingEl.textContent = this.getPointsRemaining(blockId);
      }
    }
  }

  /**
   * Update all button states for a block
   */
  updateAllButtons(blockId) {
    const block = this.blocks.get(blockId);
    if (!block) return;

    block.stats.forEach((stat, statId) => {
      this.updateButtonStates(blockId, statId);
    });
  }

  /**
   * Update button enabled/disabled states for a stat
   */
  updateButtonStates(blockId, statId) {
    const block = this.blocks.get(blockId);
    if (!block) return;

    const stat = block.stats.get(statId);
    if (!stat) return;

    const decreaseBtn = document.querySelector(`.stat-decrease[data-block-id="${blockId}"][data-stat-id="${statId}"]`);
    const increaseBtn = document.querySelector(`.stat-increase[data-block-id="${blockId}"][data-stat-id="${statId}"]`);

    // Decrease button - disabled if at min
    if (decreaseBtn) {
      decreaseBtn.disabled = stat.value <= block.config.minValue;
    }

    // Increase button - disabled if at max or not enough points
    if (increaseBtn) {
      const category = block.config.type === 'paired' ? stat.category : null;
      const remaining = this.getPointsRemaining(blockId, category);
      const nextCost = this.calculateCostForLevel(stat.value + 1, block.config.costFormula);

      increaseBtn.disabled = stat.value >= block.config.maxValue || nextCost > remaining;
    }
  }

  /**
   * Get all allocations as form data
   */
  getAllocations() {
    const allocations = {};
    this.blocks.forEach((block, blockId) => {
      allocations[blockId] = {};
      block.stats.forEach((stat, statId) => {
        allocations[blockId][statId] = stat.value;
      });
    });
    return allocations;
  }
}

// Export for use in other scripts
if (typeof window !== 'undefined') {
  window.StatAllocationManager = StatAllocationManager;
}
