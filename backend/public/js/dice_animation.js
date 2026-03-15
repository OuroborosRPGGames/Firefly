/**
 * Dice Animation System
 * Handles animated dice rolls with Ravencroft-style rolling effects.
 *
 * Animation data format (pipe-delimited):
 * - Full roll: "label|||color|||dice_data"
 * - Dice data: "type||delay||result||roll1|roll2|roll3..."
 * - Multiple dice: "dice1(())dice2(())dice3..."
 * - Multiple rollers: "roller1|||||roller2"
 *
 * Options passed via container data attributes:
 * - data-modifier: roll modifier (float)
 * - data-total: roll total (float)
 * - data-character-name: character name to prepend
 * - data-scroll-target: ID of scroll container to keep scrolled
 */
class DiceAnimator {
  constructor(options = {}) {
    this.animationInterval = options.animationInterval || 400;
  }

  // Unique prefix per animation to prevent ID collisions
  static _counter = 0;
  static nextPrefix() {
    return `da${++DiceAnimator._counter}`;
  }

  /**
   * Animate a dice roll in a container element.
   * Reads modifier/total/characterName from container data attributes.
   */
  animate(containerId, animationData) {
    const container = document.getElementById(containerId);
    if (!container) return;

    const parsed = this.parseAnimationData(animationData);
    if (!parsed || parsed.length === 0) return;

    container.innerHTML = '';

    const prefix = DiceAnimator.nextPrefix();
    const modifier = parseFloat(container.dataset.modifier) || 0;
    const total = container.dataset.total;
    const charName = container.dataset.characterName || '';
    const scrollTargetId = container.dataset.scrollTarget;

    const scrollFn = () => {
      const scrollEl = scrollTargetId ? document.getElementById(scrollTargetId) : null;
      if (scrollEl) scrollEl.scrollTop = scrollEl.scrollHeight;
    };

    let maxDuration = 0;
    parsed.forEach((rollData, rollIndex) => {
      const dur = this.animateRoll(container, rollData, rollIndex, prefix, {
        modifier, total, charName, scrollFn
      });
      if (dur > maxDuration) maxDuration = dur;
    });
    return maxDuration;
  }

  parseAnimationData(data) {
    if (!data) return null;
    const rollers = data.split('|||||');
    return rollers.map(rollerData => {
      const parts = rollerData.split('|||');
      if (parts.length < 3) return null;
      const name = parts[0];
      const color = parts[1];
      const diceData = parts[2];
      const dice = diceData.split('(())').map(diceStr => {
        const dp = diceStr.split('||');
        if (dp.length < 4) return null;
        return {
          type: parseInt(dp[0]),
          delay: parseInt(dp[1]),
          result: dp[2],
          rolls: dp[3].split('|')
        };
      }).filter(d => d !== null);
      return { name, color, dice };
    }).filter(r => r !== null);
  }

  /**
   * Animate one roller's dice in a single row.
   * Shows: [CharName] [label]: [bouncing dice] → modifier → = total
   */
  animateRoll(container, rollData, rollIndex, prefix, opts) {
    const { modifier, total, charName, scrollFn } = opts;
    const rowDiv = document.createElement('div');
    rowDiv.className = 'dice-row';
    rowDiv.id = `${prefix}-row-${rollIndex}`;

    // Character name (personalized, from broadcast data)
    if (charName) {
      const nameSpan = document.createElement('span');
      nameSpan.className = 'dice-character-name';
      nameSpan.textContent = charName + ' ';
      nameSpan.style.color = rollData.color;
      rowDiv.appendChild(nameSpan);
    }

    // Stats/label from animation data (e.g. "rolls STR (6)")
    const labelSpan = document.createElement('span');
    labelSpan.className = 'dice-stats-label';
    labelSpan.textContent = rollData.name + ': ';
    rowDiv.appendChild(labelSpan);

    // Create initial dice for base dice (delay=0)
    rollData.dice.forEach((die, dieIndex) => {
      if (die.delay > 0) return;
      if (dieIndex > 0) {
        const sep = document.createElement('span');
        sep.className = 'dice-separator';
        sep.textContent = '+';
        rowDiv.appendChild(sep);
      }
      const dieDiv = document.createElement('span');
      dieDiv.className = `die die--normal anim_roll_in`;
      dieDiv.id = `${prefix}-d-${rollIndex}-${dieIndex}`;
      dieDiv.textContent = die.rolls[0] || '?';
      rowDiv.appendChild(dieDiv);
    });

    container.appendChild(rowDiv);
    scrollFn();

    const maxFrames = Math.max(...rollData.dice.map(d => d.delay + d.rolls.length));
    let timer = 0;

    // Animation loop: roll_out old → roll_in new for each frame
    for (let k = 1; k < maxFrames; k++) {
      // Phase 1: roll_out
      timer += this.animationInterval;
      ((frameNum) => {
        setTimeout(() => {
          rollData.dice.forEach((die, dieIndex) => {
            const ri = frameNum - 1 - die.delay;
            const ni = frameNum - die.delay;
            if (ri >= 0 && ri < die.rolls.length && ni < die.rolls.length) {
              const el = document.getElementById(`${prefix}-d-${rollIndex}-${dieIndex}`);
              if (el) {
                el.className = `die die--normal anim_roll_out`;
                el.textContent = die.rolls[ri];
              }
            }
          });
          scrollFn();
        }, timer);
      })(k);

      // Phase 2: roll_in
      timer += this.animationInterval;
      ((frameNum) => {
        setTimeout(() => {
          rollData.dice.forEach((die, dieIndex) => {
            const ri = frameNum - die.delay;
            if (ri >= 0 && ri < die.rolls.length) {
              let el = document.getElementById(`${prefix}-d-${rollIndex}-${dieIndex}`);

              // Delayed die first appearance (explosion)
              if (ri === 0 && die.delay > 0) {
                const sep = document.createElement('span');
                sep.className = 'dice-separator';
                sep.textContent = '+';
                rowDiv.appendChild(sep);

                el = document.createElement('span');
                el.id = `${prefix}-d-${rollIndex}-${dieIndex}`;
                el.className = `die die--normal anim_roll_in`;
                el.textContent = die.rolls[0];
                rowDiv.appendChild(el);
              } else if (el) {
                el.className = `die die--normal anim_roll_in`;
                el.textContent = die.rolls[ri];
              }
            }
          });
          scrollFn();
        }, timer);
      })(k);
    }

    // Final reveal: vanish_out old values
    timer += 800;
    setTimeout(() => {
      rollData.dice.forEach((die, dieIndex) => {
        const el = document.getElementById(`${prefix}-d-${rollIndex}-${dieIndex}`);
        if (!el) return;
        const lastRoll = die.rolls[die.rolls.length - 1];
        if (lastRoll !== die.result) {
          el.className = `die ${this.getDieClass(die.type)} anim_vanish_out`;
          el.textContent = lastRoll;
        }
      });
    }, timer);

    // Final reveal: vanish_in results + show modifier/total
    timer += 800;
    setTimeout(() => {
      rollData.dice.forEach((die, dieIndex) => {
        const el = document.getElementById(`${prefix}-d-${rollIndex}-${dieIndex}`);
        if (!el) return;
        el.className = `die ${this.getDieClass(die.type)} anim_vanish_in`;
        el.textContent = die.result;

        if (die.type === 2) {
          if (!el.nextSibling?.classList?.contains('explosion-marker')) {
            const marker = document.createElement('span');
            marker.className = 'explosion-marker';
            marker.textContent = '!';
            el.parentNode.insertBefore(marker, el.nextSibling);
          }
        }
      });

      // Show modifier
      if (modifier && modifier !== 0) {
        const modSpan = document.createElement('span');
        const sign = modifier > 0 ? '+' : '';
        modSpan.className = `dice-modifier ${modifier > 0 ? 'dice-modifier--positive' : 'dice-modifier--negative'} anim_vanish_in`;
        modSpan.textContent = ` ${sign}${Math.round(modifier * 10) / 10}`;
        rowDiv.appendChild(modSpan);
      }

      // Show total
      if (total !== undefined && total !== null) {
        const totalSpan = document.createElement('span');
        totalSpan.className = 'dice-total anim_vanish_in';
        totalSpan.textContent = `= ${Math.round(parseFloat(total) * 10) / 10}`;
        rowDiv.appendChild(totalSpan);
      }

      scrollFn();
    }, timer);

    return timer;
  }

  getDieClass(type) {
    switch (type) {
      case 1: return 'die--success';
      case 2: return 'die--exploded';
      case 3: return 'die--critical';
      case 4: return 'die--willpower';
      default: return 'die--normal';
    }
  }
}

// Static fallback for non-animated display
class SimpleRollDisplay {
  static display(rollResult, characterName, container) {
    const rollDiv = document.createElement('div');
    rollDiv.className = 'dice-roll-container';

    const diceRow = document.createElement('div');
    diceRow.className = 'dice-row';

    const nameSpan = document.createElement('span');
    nameSpan.className = 'dice-character-name';
    nameSpan.textContent = `${characterName} rolls: `;
    diceRow.appendChild(nameSpan);

    rollResult.dice.forEach((value, index) => {
      if (index > 0) {
        const sep = document.createElement('span');
        sep.className = 'dice-separator';
        sep.textContent = '+';
        diceRow.appendChild(sep);
      }

      const dieSpan = document.createElement('span');
      const isExplosion = rollResult.explosions && rollResult.explosions.includes(index);
      dieSpan.className = `die ${isExplosion ? 'die--exploded' : 'die--normal'}`;
      dieSpan.textContent = value;
      diceRow.appendChild(dieSpan);

      if (isExplosion) {
        const marker = document.createElement('span');
        marker.className = 'explosion-marker';
        marker.textContent = '!';
        diceRow.appendChild(marker);
      }
    });

    if (rollResult.modifier && rollResult.modifier !== 0) {
      const modSpan = document.createElement('span');
      const sign = rollResult.modifier > 0 ? '+' : '';
      modSpan.className = `dice-modifier ${rollResult.modifier > 0 ? 'dice-modifier--positive' : 'dice-modifier--negative'}`;
      modSpan.textContent = ` ${sign}${rollResult.modifier}`;
      diceRow.appendChild(modSpan);
    }

    const totalSpan = document.createElement('span');
    totalSpan.className = 'dice-total';
    totalSpan.textContent = `= ${rollResult.total}`;
    diceRow.appendChild(totalSpan);

    rollDiv.appendChild(diceRow);
    container.appendChild(rollDiv);
  }
}

if (typeof window !== 'undefined') {
  window.DiceAnimator = DiceAnimator;
  window.SimpleRollDisplay = SimpleRollDisplay;
}
