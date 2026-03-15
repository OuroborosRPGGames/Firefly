/**
 * Round Nodes - SVG rendering for activity round nodes
 */
class RoundNodeRenderer {
  constructor(svg, config = {}) {
    this.svg = svg;
    this.nodesLayer = svg.querySelector('#nodes-layer');
    this.connectionsLayer = svg.querySelector('#connections-layer');

    this.config = {
      nodeWidth: 140,
      nodeHeight: 60,
      nodeSpacingX: 200,
      nodeSpacingY: 100,
      startX: 100,
      startY: 80,
      ...config
    };

    // Round type styling
    this.typeStyles = {
      standard: { color: '#4a90d9', icon: 'play-circle', shape: 'rect' },
      combat: { color: '#ef4444', icon: 'sword', shape: 'octagon' },
      branch: { color: '#8b5cf6', icon: 'signpost-split', shape: 'diamond' },
      mysterybranch: { color: '#8b5cf6', icon: 'search', shape: 'diamond' },
      reflex: { color: '#f59e0b', icon: 'lightning', shape: 'diamond' },
      group_check: { color: '#10b981', icon: 'people', shape: 'hexagon' },
      free_roll: { color: '#06b6d4', icon: 'dice-6', shape: 'rect' },
      persuade: { color: '#ec4899', icon: 'chat-heart', shape: 'ellipse' },
      rest: { color: '#22c55e', icon: 'cup-hot', shape: 'rect' },
      mystery: { color: '#6b7280', icon: 'search', shape: 'rect' }
    };

    this.selectedRoundId = null;
    this.onNodeClick = null;
    this.onNodeDelete = null;
    this.rounds = [];
    this.wasDragged = false;
  }

  // Set click handler
  setNodeClickHandler(handler) {
    this.onNodeClick = handler;
  }

  // Set delete handler
  setNodeDeleteHandler(handler) {
    this.onNodeDelete = handler;
  }

  // Clear all nodes and connections
  clear() {
    this.nodesLayer.innerHTML = '';
    this.connectionsLayer.innerHTML = '';
  }

  // Render all rounds
  render(rounds) {
    this.rounds = rounds;
    this.clear();

    if (rounds.length === 0) return;

    // Auto-layout rounds if they don't have positions
    this.autoLayoutRounds(rounds);

    // Draw connections first (below nodes)
    this.renderConnections(rounds);

    // Draw nodes
    rounds.forEach(round => this.renderNode(round));

    // Update count display
    const countEl = document.getElementById('round-count');
    if (countEl) {
      countEl.textContent = `${rounds.length} round${rounds.length !== 1 ? 's' : ''}`;
    }

    // Toggle empty state
    const emptyEl = document.getElementById('canvas-empty');
    if (emptyEl) {
      emptyEl.style.display = rounds.length === 0 ? 'flex' : 'none';
    }
  }

  // Auto-layout rounds in a flow
  autoLayoutRounds(rounds) {
    // Group by branch
    const branches = {};
    rounds.forEach(round => {
      const b = round.branch || 0;
      if (!branches[b]) branches[b] = [];
      branches[b].push(round);
    });

    // Sort each branch by round number
    Object.values(branches).forEach(branchRounds => {
      branchRounds.sort((a, b) => a.round_number - b.round_number);
    });

    // Layout main branch (0) horizontally
    const mainBranch = (branches[0] || []).slice().sort((a, b) => a.round_number - b.round_number);
    mainBranch.forEach((round, idx) => {
      if (round.canvas_x === 0 && round.canvas_y === 0) {
        round.canvas_x = this.config.startX + idx * this.config.nodeSpacingX;
        round.canvas_y = this.config.startY;
      }
    });

    // Build a lookup: round_number → canvas_x for main branch (for branch placement)
    // This gives us the x-anchor to position branch rounds near their entry point.
    const mainXByRoundNumber = {};
    mainBranch.forEach(r => { mainXByRoundNumber[r.round_number] = r.canvas_x; });

    // Helper: find x of the closest preceding main-branch round for a given round_number
    const branchEntryX = (roundNumber) => {
      let best = null;
      for (const rn of Object.keys(mainXByRoundNumber).map(Number).sort((a, b) => a - b)) {
        if (rn < roundNumber) best = mainXByRoundNumber[rn];
        else break;
      }
      // If no preceding round found, use startX; offset half a spacing to sit between nodes
      return (best !== null ? best : this.config.startX) + this.config.nodeSpacingX / 2;
    };

    // Layout other branches below — x anchored to their round_number in the main flow
    Object.keys(branches).filter(b => b !== '0').forEach((branchId, branchIdx) => {
      const branchRounds = branches[branchId];
      branchRounds.forEach((round, idx) => {
        if (round.canvas_x === 0 && round.canvas_y === 0) {
          round.canvas_x = branchEntryX(round.round_number) + idx * this.config.nodeSpacingX;
          round.canvas_y = this.config.startY + (branchIdx + 1) * this.config.nodeSpacingY;
        }
      });
    });
  }

  // Render a single node
  renderNode(round) {
    const style = this.typeStyles[round.round_type] || this.typeStyles.standard;
    const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    g.setAttribute('class', 'round-node');
    g.setAttribute('data-round-id', round.id);
    g.setAttribute('transform', `translate(${round.canvas_x}, ${round.canvas_y})`);

    // Shape
    const shape = this.createShape(style.shape, style.color, round.id === this.selectedRoundId);
    g.appendChild(shape);

    // Label - use custom name when available
    const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    text.setAttribute('x', this.config.nodeWidth / 2);
    text.setAttribute('y', this.config.nodeHeight / 2 + 5);
    text.setAttribute('text-anchor', 'middle');
    text.setAttribute('fill', 'white');
    text.setAttribute('font-size', '12');
    text.setAttribute('font-weight', '500');
    const label = round.name || round.display_name || `Round ${round.round_number}`;
    // Truncate long labels
    text.textContent = label.length > 18 ? label.substring(0, 16) + '...' : label;
    g.appendChild(text);

    // Type badge
    const badge = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    badge.setAttribute('x', this.config.nodeWidth / 2);
    badge.setAttribute('y', this.config.nodeHeight / 2 - 12);
    badge.setAttribute('text-anchor', 'middle');
    badge.setAttribute('fill', 'rgba(255,255,255,0.7)');
    badge.setAttribute('font-size', '10');
    badge.textContent = round.round_type.replace('_', ' ').toUpperCase();
    g.appendChild(badge);

    // Media icon badge
    if (round.has_media) {
      const mediaIcon = this.createBadgeIcon(this.config.nodeWidth - 20, 5, 'play-circle', '#06b6d4');
      g.appendChild(mediaIcon);
    }

    // Room icon badge
    if (round.has_custom_room) {
      const roomIcon = this.createBadgeIcon(5, 5, 'door-open', '#f59e0b');
      g.appendChild(roomIcon);
    }

    // Finale star badge
    if (round.is_finale) {
      const finaleIcon = this.createBadgeIcon(this.config.nodeWidth / 2 - 6, -12, 'star-fill', '#fcd34d');
      g.appendChild(finaleIcon);
    }

    // Click handler - shows context menu
    g.style.cursor = 'pointer';
    g.addEventListener('click', (e) => {
      e.stopPropagation();
      if (this.wasDragged) {
        this.wasDragged = false;
        return;
      }
      this.selectNode(round.id);
      this.showContextMenu(round, e);
    });

    // Make draggable
    this.makeDraggable(g, round);

    this.nodesLayer.appendChild(g);
  }

  // Create badge icon
  createBadgeIcon(x, y, icon, color) {
    const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    g.setAttribute('transform', `translate(${x}, ${y})`);

    const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    circle.setAttribute('cx', 6);
    circle.setAttribute('cy', 6);
    circle.setAttribute('r', 8);
    circle.setAttribute('fill', color);
    g.appendChild(circle);

    return g;
  }

  // Create node shape based on type
  createShape(shapeType, color, selected = false) {
    const { nodeWidth, nodeHeight } = this.config;
    const strokeWidth = selected ? 3 : 1;
    const strokeColor = selected ? '#fcd34d' : 'rgba(255,255,255,0.3)';

    switch (shapeType) {
      case 'diamond': {
        const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
        const cx = nodeWidth / 2;
        const cy = nodeHeight / 2;
        const rx = nodeWidth / 2 - 5;
        const ry = nodeHeight / 2 - 5;
        polygon.setAttribute('points', `${cx},${cy - ry} ${cx + rx},${cy} ${cx},${cy + ry} ${cx - rx},${cy}`);
        polygon.setAttribute('fill', color);
        polygon.setAttribute('stroke', strokeColor);
        polygon.setAttribute('stroke-width', strokeWidth);
        return polygon;
      }

      case 'octagon': {
        const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
        const x = 5, y = 5;
        const w = nodeWidth - 10, h = nodeHeight - 10;
        const c = 12; // corner cut
        polygon.setAttribute('points', `${x + c},${y} ${x + w - c},${y} ${x + w},${y + c} ${x + w},${y + h - c} ${x + w - c},${y + h} ${x + c},${y + h} ${x},${y + h - c} ${x},${y + c}`);
        polygon.setAttribute('fill', color);
        polygon.setAttribute('stroke', strokeColor);
        polygon.setAttribute('stroke-width', strokeWidth);
        return polygon;
      }

      case 'hexagon': {
        const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
        const cx = nodeWidth / 2;
        const cy = nodeHeight / 2;
        const rx = nodeWidth / 2 - 5;
        const ry = nodeHeight / 2 - 5;
        polygon.setAttribute('points', `${cx - rx},${cy} ${cx - rx / 2},${cy - ry} ${cx + rx / 2},${cy - ry} ${cx + rx},${cy} ${cx + rx / 2},${cy + ry} ${cx - rx / 2},${cy + ry}`);
        polygon.setAttribute('fill', color);
        polygon.setAttribute('stroke', strokeColor);
        polygon.setAttribute('stroke-width', strokeWidth);
        return polygon;
      }

      case 'ellipse': {
        const ellipse = document.createElementNS('http://www.w3.org/2000/svg', 'ellipse');
        ellipse.setAttribute('cx', nodeWidth / 2);
        ellipse.setAttribute('cy', nodeHeight / 2);
        ellipse.setAttribute('rx', nodeWidth / 2 - 5);
        ellipse.setAttribute('ry', nodeHeight / 2 - 5);
        ellipse.setAttribute('fill', color);
        ellipse.setAttribute('stroke', strokeColor);
        ellipse.setAttribute('stroke-width', strokeWidth);
        return ellipse;
      }

      default: { // rect
        const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        rect.setAttribute('x', 5);
        rect.setAttribute('y', 5);
        rect.setAttribute('width', nodeWidth - 10);
        rect.setAttribute('height', nodeHeight - 10);
        rect.setAttribute('rx', 8);
        rect.setAttribute('fill', color);
        rect.setAttribute('stroke', strokeColor);
        rect.setAttribute('stroke-width', strokeWidth);
        return rect;
      }
    }
  }

  // Render connections between rounds
  renderConnections(rounds) {
    // Map rounds by ID
    const roundMap = {};
    rounds.forEach(r => roundMap[r.id] = r);

    // Find sequential connections (main flow)
    const branches = {};
    rounds.forEach(round => {
      const b = round.branch || 0;
      if (!branches[b]) branches[b] = [];
      branches[b].push(round);
    });

    // Main branch (0) sorted by round_number — used for convergence lookup
    const mainBranch = (branches[0] || []).slice().sort((a, b) => a.round_number - b.round_number);

    // Sequential connections within each branch
    // Skip drawing sequential arrows FROM branch/mysterybranch rounds — their
    // connections are drawn explicitly via branch_choices below.
    Object.values(branches).forEach(branchRounds => {
      branchRounds.sort((a, b) => a.round_number - b.round_number);
      for (let i = 0; i < branchRounds.length - 1; i++) {
        const from = branchRounds[i];
        const to = branchRounds[i + 1];
        if (from.round_type === 'branch' || from.round_type === 'mysterybranch') continue;
        this.drawConnection(from, to, 'normal');
      }
    });

    // Branch connections (branch_to / fail_branch_to / branch_choices)
    rounds.forEach(round => {
      if (round.fail_branch_to) {
        const target = roundMap[round.fail_branch_to];
        if (target) {
          this.drawConnection(round, target, 'fail');
        }
      }
      // Branch choices connections (covers branch_to implicitly)
      if (round.branch_choices && Array.isArray(round.branch_choices) && round.branch_choices.length > 0) {
        round.branch_choices.forEach(choice => {
          if (choice.branch_to_round_id) {
            const target = roundMap[choice.branch_to_round_id];
            if (target) {
              this.drawConnection(round, target, 'success');
            }
          }
        });
      } else if (round.branch_to) {
        // Fallback for rounds with branch_to but no branch_choices array
        const target = roundMap[round.branch_to];
        if (target) {
          this.drawConnection(round, target, 'success');
        }
      }
    });

    // Convergence arrows: non-0 branch rounds with no explicit branch_to connect
    // back to the next main-flow round after their round_number.
    rounds.forEach(round => {
      if ((round.branch || 0) === 0) return; // skip main branch
      if (round.branch_to) return; // already has explicit target
      // Find the first main-branch round with round_number > this round's
      const convergenceTarget = mainBranch.find(r => r.round_number > round.round_number);
      if (convergenceTarget) {
        this.drawConnection(round, convergenceTarget, 'normal');
      }
    });
  }

  // Draw a connection line between two rounds
  drawConnection(from, to, type = 'normal') {
    const { nodeWidth, nodeHeight } = this.config;

    // Determine connection points on node edges
    const startX = from.canvas_x + nodeWidth;
    const startY = from.canvas_y + nodeHeight / 2;
    const endX = to.canvas_x;
    const endY = to.canvas_y + nodeHeight / 2;

    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');

    // Curved path for better aesthetics
    const midX = (startX + endX) / 2;
    const d = `M ${startX} ${startY} C ${midX} ${startY}, ${midX} ${endY}, ${endX} ${endY}`;
    path.setAttribute('d', d);
    path.setAttribute('fill', 'none');

    switch (type) {
      case 'success':
        path.setAttribute('stroke', '#198754');
        path.setAttribute('marker-end', 'url(#arrowhead-success)');
        break;
      case 'fail':
        path.setAttribute('stroke', '#dc3545');
        path.setAttribute('stroke-dasharray', '5,5');
        path.setAttribute('marker-end', 'url(#arrowhead-fail)');
        break;
      default:
        path.setAttribute('stroke', '#6c757d');
        path.setAttribute('marker-end', 'url(#arrowhead)');
    }

    path.setAttribute('stroke-width', 2);
    this.connectionsLayer.appendChild(path);
  }

  // Select a node
  selectNode(roundId) {
    this.selectedRoundId = roundId;
    // Re-render to show selection
    if (this.rounds.length > 0) {
      this.render(this.rounds);
    }
  }

  // Deselect all
  deselectAll() {
    this.selectedRoundId = null;
    if (this.rounds.length > 0) {
      this.render(this.rounds);
    }
  }

  // Show context menu near the clicked node
  showContextMenu(round, event) {
    const menu = document.getElementById('round-context-menu');
    if (!menu) {
      // Fallback: directly open modal
      if (this.onNodeClick) this.onNodeClick(round);
      return;
    }

    // Position menu near the click
    const container = document.getElementById('canvas-container');
    const containerRect = container.getBoundingClientRect();
    const x = event.clientX - containerRect.left + 4;
    const y = event.clientY - containerRect.top + 4;

    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;
    menu.classList.remove('hidden');

    // Wire up buttons
    const editBtn = document.getElementById('ctx-edit-round');
    const deleteBtn = document.getElementById('ctx-delete-round');

    const closeMenu = () => menu.classList.add('hidden');

    const onEdit = () => {
      closeMenu();
      if (this.onNodeClick) this.onNodeClick(round);
      editBtn.removeEventListener('click', onEdit);
      deleteBtn.removeEventListener('click', onDelete);
    };
    const onDelete = () => {
      closeMenu();
      if (this.onNodeDelete) this.onNodeDelete(round);
      editBtn.removeEventListener('click', onEdit);
      deleteBtn.removeEventListener('click', onDelete);
    };

    editBtn.addEventListener('click', onEdit);
    deleteBtn.addEventListener('click', onDelete);

    // Close on click outside
    const onOutsideClick = (e) => {
      if (!menu.contains(e.target)) {
        closeMenu();
        editBtn.removeEventListener('click', onEdit);
        deleteBtn.removeEventListener('click', onDelete);
        document.removeEventListener('click', onOutsideClick);
      }
    };
    // Defer so this click doesn't immediately close it
    setTimeout(() => document.addEventListener('click', onOutsideClick), 0);
  }

  // Make node draggable
  makeDraggable(element, round) {
    let isDragging = false;
    let hasMoved = false;
    let startX, startY, origX, origY;

    element.addEventListener('mousedown', (e) => {
      if (e.button !== 0) return; // Left click only
      isDragging = true;
      hasMoved = false;
      startX = e.clientX;
      startY = e.clientY;
      origX = round.canvas_x;
      origY = round.canvas_y;
      e.preventDefault();
    });

    document.addEventListener('mousemove', (e) => {
      if (!isDragging) return;

      const dx = e.clientX - startX;
      const dy = e.clientY - startY;

      // Only count as drag if moved more than 5px
      if (Math.abs(dx) > 5 || Math.abs(dy) > 5) {
        hasMoved = true;
      }

      round.canvas_x = origX + dx;
      round.canvas_y = origY + dy;

      element.setAttribute('transform', `translate(${round.canvas_x}, ${round.canvas_y})`);

      // Update connections
      this.connectionsLayer.innerHTML = '';
      this.renderConnections(this.rounds);
    });

    document.addEventListener('mouseup', () => {
      if (isDragging) {
        isDragging = false;
        if (hasMoved) {
          this.wasDragged = true;
          // Emit position change event for saving
          if (this.onPositionChange) {
            this.onPositionChange(round.id, round.canvas_x, round.canvas_y);
          }
        }
      }
    });
  }

  // Set position change handler
  setPositionChangeHandler(handler) {
    this.onPositionChange = handler;
  }
}

// Export
window.RoundNodeRenderer = RoundNodeRenderer;
