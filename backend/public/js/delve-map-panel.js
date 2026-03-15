/**
 * DelveMapPanel - Interactive SVG map for dungeon delves.
 *
 * Receives server-rendered SVG strings from DelveMapPanelService and displays
 * them with pan (mouse drag + touch), zoom (scroll wheel + pinch), auto-center
 * on the current room, click-to-move popups, and connection feature info.
 *
 * Public API:
 *   DelveMapPanel.init(containerEl)    - Initialize the panel on a container element
 *   DelveMapPanel.updateMap(svgString) - Replace the map SVG content
 *   DelveMapPanel.centerOnCurrentRoom() - Pan/zoom to center on the current room marker
 *   DelveMapPanel.destroy()            - Clean up event listeners and state
 */
(function () {
  'use strict';

  // ── State ──────────────────────────────────────────────────────────

  var containerEl = null;
  var svgEl = null;
  var viewBox = { x: 0, y: 0, w: 0, h: 0 };
  var isPanning = false;
  var didPan = false;       // true if mouse actually moved during drag
  var panStart = { x: 0, y: 0 };
  var panViewBoxStart = { x: 0, y: 0 };
  var currentPopup = null;
  var popupTimeout = null;

  // Zoom limits
  var MIN_ZOOM = 0.5;
  var MAX_ZOOM = 8.0;
  var ZOOM_STEP = 0.15;
  var currentZoom = 1.0;
  var baseViewBox = { x: 0, y: 0, w: 0, h: 0 };

  // Touch pinch state
  var lastPinchDistance = 0;
  var isTouchPanning = false;
  var touchStartPoint = { x: 0, y: 0 };

  // ── Init / Destroy ─────────────────────────────────────────────────

  function init(el) {
    if (!el) return;
    containerEl = el;
    containerEl.style.overflow = 'hidden';
    containerEl.style.position = 'relative';
    containerEl.style.background = '#0d1117';
    containerEl.style.cursor = 'grab';
    containerEl.style.touchAction = 'none';

    // Attach container-level events
    containerEl.addEventListener('wheel', onWheel, { passive: false });
    containerEl.addEventListener('mousedown', onMouseDown);
    containerEl.addEventListener('touchstart', onTouchStart, { passive: false });

    // Window-level events for drag release outside the container
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
    window.addEventListener('touchmove', onTouchMove, { passive: false });
    window.addEventListener('touchend', onTouchEnd);
  }

  function destroy() {
    removePopup();

    if (containerEl) {
      containerEl.removeEventListener('wheel', onWheel);
      containerEl.removeEventListener('mousedown', onMouseDown);
      containerEl.removeEventListener('touchstart', onTouchStart);
    }

    window.removeEventListener('mousemove', onMouseMove);
    window.removeEventListener('mouseup', onMouseUp);
    window.removeEventListener('touchmove', onTouchMove);
    window.removeEventListener('touchend', onTouchEnd);

    if (containerEl) {
      containerEl.innerHTML = '';
    }

    containerEl = null;
    svgEl = null;
    currentZoom = 1.0;
    isPanning = false;
    isTouchPanning = false;
  }

  // ── Update Map ─────────────────────────────────────────────────────

  function updateMap(svgString, preserveView) {
    if (!containerEl || !svgString) return;

    removePopup();

    // Save current view state for soft updates
    var hadPreviousView = preserveView && svgEl && currentZoom > 0;
    var savedViewBox = hadPreviousView ? { x: viewBox.x, y: viewBox.y, w: viewBox.w, h: viewBox.h } : null;
    var savedZoom = hadPreviousView ? currentZoom : 0;
    var savedBaseViewBox = hadPreviousView ? { x: baseViewBox.x, y: baseViewBox.y, w: baseViewBox.w, h: baseViewBox.h } : null;

    // Inject SVG string into container
    containerEl.innerHTML = svgString;
    svgEl = containerEl.querySelector('svg');
    if (!svgEl) return;

    // Make SVG fill the container
    svgEl.style.width = '100%';
    svgEl.style.height = '100%';
    svgEl.style.display = 'block';

    // Parse the original viewBox
    var vb = svgEl.getAttribute('viewBox');
    if (vb) {
      var parts = vb.split(/[\s,]+/).map(Number);
      if (parts.length === 4) {
        baseViewBox = { x: parts[0], y: parts[1], w: parts[2], h: parts[3] };
      }
    }

    // Remove fixed width/height so it scales to container
    svgEl.removeAttribute('width');
    svgEl.removeAttribute('height');

    // Pad baseViewBox to match container aspect ratio so there's no letterboxing
    var cRect = containerEl.getBoundingClientRect();
    if (cRect.width > 0 && cRect.height > 0) {
      var containerAspect = cRect.width / cRect.height;
      var mapAspect = baseViewBox.w / baseViewBox.h;

      if (containerAspect > mapAspect) {
        // Container is wider than map — expand baseViewBox width
        var newW = baseViewBox.h * containerAspect;
        baseViewBox.x -= (newW - baseViewBox.w) / 2;
        baseViewBox.w = newW;
      } else {
        // Container is taller than map — expand baseViewBox height
        var newH = baseViewBox.w / containerAspect;
        baseViewBox.y -= (newH - baseViewBox.h) / 2;
        baseViewBox.h = newH;
      }
    }

    // Since we manage viewBox aspect ratio ourselves, disable SVG's own aspect correction
    svgEl.setAttribute('preserveAspectRatio', 'none');

    // Add click listeners for room popups and connection features
    attachRoomClickListeners();

    if (hadPreviousView && savedBaseViewBox) {
      // Soft update: restore previous view position and zoom
      baseViewBox = savedBaseViewBox;
      currentZoom = savedZoom;
      viewBox = savedViewBox;
      applyViewBox();
    } else {
      // Initial load: set zoom to show ~6 rooms of vertical space
      var roomSpacing = 40; // matches CELL_SIZE in DelveMapPanelService
      var idealViewH = roomSpacing * 7;
      currentZoom = Math.max(1.0, baseViewBox.h / idealViewH);

      viewBox = { x: baseViewBox.x, y: baseViewBox.y, w: baseViewBox.w, h: baseViewBox.h };

      // Auto-center on current room
      centerOnCurrentRoom();
    }
  }

  // ── Center on Current Room ─────────────────────────────────────────

  function centerOnCurrentRoom() {
    if (!svgEl || !containerEl) return;

    // Find the current-room cell (amber-glowing room)
    var marker = svgEl.querySelector('.current-room');
    if (!marker) return;

    var cx, cy;
    if (marker.tagName === 'rect') {
      cx = parseFloat(marker.getAttribute('x')) + parseFloat(marker.getAttribute('width')) / 2;
      cy = parseFloat(marker.getAttribute('y')) + parseFloat(marker.getAttribute('height')) / 2;
    } else {
      return;
    }

    // Calculate viewBox to center on cx,cy at current zoom
    // Use baseViewBox (already aspect-ratio-adjusted) for uniform zoom
    var zoomedW = baseViewBox.w / currentZoom;
    var zoomedH = baseViewBox.h / currentZoom;

    viewBox.w = zoomedW;
    viewBox.h = zoomedH;
    viewBox.x = cx - zoomedW / 2;
    viewBox.y = cy - zoomedH / 2;

    applyViewBox();
  }

  // ── ViewBox helpers ────────────────────────────────────────────────

  function applyViewBox() {
    if (!svgEl) return;
    svgEl.setAttribute('viewBox',
      viewBox.x + ' ' + viewBox.y + ' ' + viewBox.w + ' ' + viewBox.h
    );
  }

  function screenToSvg(screenX, screenY) {
    if (!svgEl || !containerEl) return { x: 0, y: 0 };
    var rect = containerEl.getBoundingClientRect();
    var ratioX = viewBox.w / rect.width;
    var ratioY = viewBox.h / rect.height;
    return {
      x: viewBox.x + (screenX - rect.left) * ratioX,
      y: viewBox.y + (screenY - rect.top) * ratioY
    };
  }

  // ── Mouse pan ──────────────────────────────────────────────────────

  function onMouseDown(e) {
    if (e.button !== 0) return; // left button only
    isPanning = true;
    didPan = false;
    panStart.x = e.clientX;
    panStart.y = e.clientY;
    panViewBoxStart.x = viewBox.x;
    panViewBoxStart.y = viewBox.y;
    if (containerEl) containerEl.style.cursor = 'grabbing';
    removePopup();
  }

  function onMouseMove(e) {
    if (!isPanning || !containerEl) return;
    var dx = e.clientX - panStart.x;
    var dy = e.clientY - panStart.y;
    // Only start panning after a minimum drag threshold (3px)
    if (!didPan && Math.abs(dx) < 3 && Math.abs(dy) < 3) return;
    didPan = true;
    var rect = containerEl.getBoundingClientRect();
    var svgDx = dx * (viewBox.w / rect.width);
    var svgDy = dy * (viewBox.h / rect.height);
    viewBox.x = panViewBoxStart.x - svgDx;
    viewBox.y = panViewBoxStart.y - svgDy;
    applyViewBox();
  }

  function onMouseUp() {
    if (isPanning) {
      isPanning = false;
      if (containerEl) containerEl.style.cursor = 'grab';
    }
  }

  // ── Scroll zoom ────────────────────────────────────────────────────

  function onWheel(e) {
    e.preventDefault();
    if (!svgEl || !containerEl) return;

    // Get mouse position in SVG coordinates before zoom
    var svgPoint = screenToSvg(e.clientX, e.clientY);

    // Determine zoom direction (multiplicative for smoother feel)
    var zoomFactor = e.deltaY > 0 ? 0.85 : 1.18;
    var newZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, currentZoom * zoomFactor));
    if (newZoom === currentZoom) return;

    var scale = currentZoom / newZoom;
    currentZoom = newZoom;

    // Zoom toward the mouse position
    var newW = baseViewBox.w / currentZoom;
    var newH = baseViewBox.h / currentZoom;

    viewBox.x = svgPoint.x - (svgPoint.x - viewBox.x) * scale;
    viewBox.y = svgPoint.y - (svgPoint.y - viewBox.y) * scale;
    viewBox.w = newW;
    viewBox.h = newH;

    applyViewBox();
  }

  // ── Touch pan + pinch zoom ─────────────────────────────────────────

  function onTouchStart(e) {
    removePopup();

    if (e.touches.length === 1) {
      // Single touch: pan
      isTouchPanning = true;
      touchStartPoint.x = e.touches[0].clientX;
      touchStartPoint.y = e.touches[0].clientY;
      panViewBoxStart.x = viewBox.x;
      panViewBoxStart.y = viewBox.y;
      e.preventDefault();
    } else if (e.touches.length === 2) {
      // Two touches: pinch zoom
      isTouchPanning = false;
      lastPinchDistance = pinchDistance(e.touches);
      e.preventDefault();
    }
  }

  function onTouchMove(e) {
    if (!containerEl) return;

    if (e.touches.length === 1 && isTouchPanning) {
      var rect = containerEl.getBoundingClientRect();
      var dx = (e.touches[0].clientX - touchStartPoint.x) * (viewBox.w / rect.width);
      var dy = (e.touches[0].clientY - touchStartPoint.y) * (viewBox.h / rect.height);
      viewBox.x = panViewBoxStart.x - dx;
      viewBox.y = panViewBoxStart.y - dy;
      applyViewBox();
      e.preventDefault();
    } else if (e.touches.length === 2) {
      var newDist = pinchDistance(e.touches);
      if (lastPinchDistance > 0) {
        var pinchScale = newDist / lastPinchDistance;
        var newZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, currentZoom * pinchScale));

        if (newZoom !== currentZoom) {
          // Pinch center in SVG coords
          var midX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
          var midY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
          var svgMid = screenToSvg(midX, midY);

          var scale = currentZoom / newZoom;
          currentZoom = newZoom;

          var newW = baseViewBox.w / currentZoom;
          var newH = baseViewBox.h / currentZoom;

          viewBox.x = svgMid.x - (svgMid.x - viewBox.x) * scale;
          viewBox.y = svgMid.y - (svgMid.y - viewBox.y) * scale;
          viewBox.w = newW;
          viewBox.h = newH;

          applyViewBox();
        }
      }
      lastPinchDistance = newDist;
      e.preventDefault();
    }
  }

  function onTouchEnd(e) {
    if (e.touches.length === 0) {
      isTouchPanning = false;
      lastPinchDistance = 0;
    } else if (e.touches.length === 1) {
      // Switched from pinch back to single touch: restart pan
      isTouchPanning = true;
      touchStartPoint.x = e.touches[0].clientX;
      touchStartPoint.y = e.touches[0].clientY;
      panViewBoxStart.x = viewBox.x;
      panViewBoxStart.y = viewBox.y;
      lastPinchDistance = 0;
    }
  }

  function pinchDistance(touches) {
    var dx = touches[0].clientX - touches[1].clientX;
    var dy = touches[0].clientY - touches[1].clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  // ── Room click popups ────────────────────────────────────────────

  function attachRoomClickListeners() {
    if (!svgEl) return;

    // Room cells
    var cells = svgEl.querySelectorAll('rect[data-room-id]');
    for (var i = 0; i < cells.length; i++) {
      cells[i].addEventListener('click', onRoomClick);
      cells[i].style.cursor = 'pointer';
    }

    // Connection feature icons (traps and blockers on passages)
    var connIcons = svgEl.querySelectorAll('.trap-conn-icon, .blocker-conn-icon, .puzzle-conn-icon');
    for (var j = 0; j < connIcons.length; j++) {
      connIcons[j].addEventListener('click', onConnectionFeatureClick);
    }
  }

  function onRoomClick(e) {
    e.stopPropagation();

    // Don't show popup if we just finished panning (actual drag, not just a click)
    if (didPan) return;

    var cell = e.currentTarget;
    var vis = cell.getAttribute('data-vis') || '';
    var gridX = parseInt(cell.getAttribute('data-grid-x'), 10);
    var gridY = parseInt(cell.getAttribute('data-grid-y'), 10);

    // Find current room to determine adjacency
    var curCell = svgEl ? svgEl.querySelector('.current-room') : null;
    var curX = curCell ? parseInt(curCell.getAttribute('data-grid-x'), 10) : NaN;
    var curY = curCell ? parseInt(curCell.getAttribute('data-grid-y'), 10) : NaN;

    // Build popup element
    var popup = document.createElement('div');
    popup.className = 'delve-map-popup';

    // Find content icons near this cell
    var icons = findContentIconsNear(cell);

    // Check for monster data on the cell
    var monstersData = cell.getAttribute('data-monsters');
    var monsterDetailNodes = [];
    if (monstersData) {
      try {
        var monsters = JSON.parse(monstersData);
        var dirArrows = { north: '\u2191', south: '\u2193', east: '\u2192', west: '\u2190' };
        for (var mi = 0; mi < monsters.length; mi++) {
          var m = monsters[mi];
          var arrow = dirArrows[m.direction] || '';
          var mDiv = document.createElement('div');
          mDiv.style.marginTop = '4px';
          var strong = document.createElement('strong');
          strong.textContent = m.name;
          mDiv.appendChild(strong);
          mDiv.appendChild(document.createTextNode(' ' + arrow + ' '));
          var diffSpan = document.createElement('span');
          diffSpan.style.opacity = '0.7';
          diffSpan.style.fontSize = '11px';
          diffSpan.textContent = '(' + m.difficulty + ')';
          mDiv.appendChild(diffSpan);
          var hpDiv = document.createElement('div');
          hpDiv.style.fontSize = '11px';
          hpDiv.style.opacity = '0.8';
          hpDiv.textContent = 'HP: ' + m.hp + '/' + m.max_hp;
          mDiv.appendChild(hpDiv);
          monsterDetailNodes.push(mDiv);
        }
      } catch (e) { /* ignore parse errors */ }
    }

    if (gridX === curX && gridY === curY) {
      // Current room
      popup.innerHTML = '<div class="popup-title">You are here</div>';
      var content = document.createElement('div');
      content.className = 'popup-content';
      for (var mni = 0; mni < monsterDetailNodes.length; mni++) {
        content.appendChild(monsterDetailNodes[mni]);
      }
      for (var i = 0; i < icons.length; i++) {
        if (monsterDetailNodes.length > 0 && icons[i] === 'Monster') continue; // skip generic "Monster" line
        var line = document.createElement('div');
        line.textContent = icons[i];
        content.appendChild(line);
      }
      if (content.childNodes.length > 0) {
        popup.appendChild(content);
      }
    } else {
      // Explored room (visible or fog) - check adjacency
      var dx = gridX - curX;
      var dy = gridY - curY;
      var isAdjacent = !isNaN(curX) && !isNaN(curY) &&
                       (Math.abs(dx) + Math.abs(dy) === 1);
      var visLabel = vis === 'visible' ? 'Visible' : (vis === 'memory' ? 'Memory' : 'Room');

      if (isAdjacent) {
        // Determine direction from grid delta
        var dir = '';
        if (dy === -1) dir = 'north';
        else if (dy === 1) dir = 'south';
        else if (dx === 1) dir = 'east';
        else if (dx === -1) dir = 'west';

        popup.innerHTML = '<div class="popup-title">' + visLabel + ' [' + gridX + ',' + gridY + ']</div>';

        var content = document.createElement('div');
        content.className = 'popup-content';

        // Add monster detail lines
        for (var mni2 = 0; mni2 < monsterDetailNodes.length; mni2++) {
          content.appendChild(monsterDetailNodes[mni2]);
        }

        // Add content icon lines
        for (var k = 0; k < icons.length; k++) {
          if (monsterDetailNodes.length > 0 && icons[k] === 'Monster') continue;
          var iconLine = document.createElement('div');
          iconLine.textContent = icons[k];
          content.appendChild(iconLine);
        }

        // Add "Go [Direction]" action button
        var goBtn = document.createElement('div');
        goBtn.className = 'popup-action';
        goBtn.textContent = 'Go ' + dir.charAt(0).toUpperCase() + dir.slice(1);
        goBtn.setAttribute('data-direction', dir);
        goBtn.addEventListener('click', function (evt) {
          var direction = evt.currentTarget.getAttribute('data-direction');
          removePopup();
          if (typeof window.sendCommand === 'function') {
            window.sendCommand('delve ' + direction);
          }
        });
        content.appendChild(goBtn);
        popup.appendChild(content);
      } else {
        // Non-adjacent explored room - info only
        popup.innerHTML = '<div class="popup-title">' + visLabel + ' [' + gridX + ',' + gridY + ']</div>';
        if (icons.length > 0 || monsterDetailNodes.length > 0) {
          var infoContent = document.createElement('div');
          infoContent.className = 'popup-content';
          for (var mni3 = 0; mni3 < monsterDetailNodes.length; mni3++) {
            infoContent.appendChild(monsterDetailNodes[mni3]);
          }
          for (var n = 0; n < icons.length; n++) {
            if (monsterDetailNodes.length > 0 && icons[n] === 'Monster') continue;
            var infoLine = document.createElement('div');
            infoLine.textContent = icons[n];
            infoContent.appendChild(infoLine);
          }
          popup.appendChild(infoContent);
        }
      }
    }

    showPopup(e.clientX, e.clientY, popup);
  }

  function onConnectionFeatureClick(e) {
    e.stopPropagation();

    var icon = e.currentTarget;
    var isTrap = icon.classList.contains('trap-conn-icon');
    var isPuzzle = icon.classList.contains('puzzle-conn-icon');

    var popup = document.createElement('div');
    popup.className = 'delve-map-popup';

    if (isTrap) {
      popup.innerHTML = '<div class="popup-title">Warning: Trap</div>' +
        '<div class="popup-content">' +
        '<div>A trap blocks this passage.</div>' +
        '<div>Use direction buttons or type command to attempt passage.</div>' +
        '</div>';
    } else if (isPuzzle) {
      popup.innerHTML = '<div class="popup-title">Blocked: Puzzle</div>' +
        '<div class="popup-content">' +
        '<div>A puzzle blocks this exit.</div>' +
        '<div>Use \'study puzzle\' to examine it, or \'solve &lt;answer&gt;\' to attempt it.</div>' +
        '</div>';
    } else {
      // Blocker - try to get metadata from data attribute
      var blockerData = null;
      try {
        var raw = icon.getAttribute('data-blocker');
        if (raw) blockerData = JSON.parse(raw);
      } catch (ex) { /* ignore */ }

      var title = 'Blocked: Obstacle';
      var details = '<div>An obstacle blocks this passage.</div>';
      var actions = '';

      if (blockerData) {
        var typeName = (blockerData.type || 'obstacle').replace(/_/g, ' ');
        typeName = typeName.charAt(0).toUpperCase() + typeName.slice(1);
        title = 'Blocked: ' + typeName;
        details = '<div>' + typeName + ' &mdash; ' + blockerData.stat + ' DC ' + blockerData.dc + '</div>';
        var dir = blockerData.direction || '';
        var shortDir = dir.charAt(0);

        actions = '<div class="popup-action" data-cmd="cross ' + shortDir + '" style="margin-top:6px;cursor:pointer;color:#c8a84b;">&#9654; Attempt to Cross</div>' +
          '<div class="popup-action" data-cmd="easier ' + shortDir + '" style="margin-top:4px;cursor:pointer;color:#6a8aaa;">&#9660; Make Easier (DC -1)</div>' +
          '<div class="popup-action" data-cmd="cross ' + shortDir + ' wp" style="margin-top:4px;cursor:pointer;color:#7a6acd;">&#9733; Cross + Willpower</div>';
      } else {
        actions = '<div style="margin-top:4px;opacity:0.7;">Use \'cross\' or \'easier\' commands.</div>';
      }

      popup.innerHTML = '<div class="popup-title">' + title + '</div>' +
        '<div class="popup-content">' + details + actions + '</div>';

      // Attach click handlers to action buttons
      var actionBtns = popup.querySelectorAll('.popup-action[data-cmd]');
      for (var i = 0; i < actionBtns.length; i++) {
        actionBtns[i].addEventListener('click', function (evt) {
          var cmd = evt.currentTarget.getAttribute('data-cmd');
          removePopup();
          if (typeof window.sendCommand === 'function') {
            window.sendCommand(cmd);
          }
        });
      }
    }

    showPopup(e.clientX, e.clientY, popup);
  }

  function findContentIconsNear(cell) {
    var icons = [];
    if (!svgEl) return icons;

    // Icon class to human-readable label mapping
    var iconLabels = {
      'monster-icon': 'Monster',
      'treasure-icon': 'Treasure',
      'puzzle-icon': 'Puzzle',
      'stairs-icon': 'Stairs down',
      'entrance-icon': 'Entrance'
    };

    // Get the cell's center coordinates to find nearby icons
    var cx = parseFloat(cell.getAttribute('x')) + parseFloat(cell.getAttribute('width')) / 2;
    var cy = parseFloat(cell.getAttribute('y')) + parseFloat(cell.getAttribute('height')) / 2;
    var threshold = 30; // pixels in SVG space

    for (var cls in iconLabels) {
      var els = svgEl.querySelectorAll('.' + cls);
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var ix, iy;
        if (el.tagName === 'circle') {
          ix = parseFloat(el.getAttribute('cx'));
          iy = parseFloat(el.getAttribute('cy'));
        } else if (el.tagName === 'text') {
          ix = parseFloat(el.getAttribute('x'));
          iy = parseFloat(el.getAttribute('y'));
        } else if (el.tagName === 'g' || el.tagName === 'polygon' || el.tagName === 'polyline') {
          // Geometric icons wrapped in <g> — use getBBox center
          try {
            var bbox = el.getBBox();
            ix = bbox.x + bbox.width / 2;
            iy = bbox.y + bbox.height / 2;
          } catch (e) {
            continue;
          }
        } else {
          continue;
        }
        var dist = Math.abs(ix - cx) + Math.abs(iy - cy);
        if (dist < threshold) {
          icons.push(iconLabels[cls]);
          break; // Only add each type once
        }
      }
    }

    return icons;
  }

  // ── Popup system ─────────────────────────────────────────────────

  function showPopup(clientX, clientY, popupEl) {
    removePopup();
    popupEl.style.position = 'fixed';
    popupEl.style.left = (clientX + 15) + 'px';
    popupEl.style.top = (clientY - 10) + 'px';
    document.body.appendChild(popupEl);
    currentPopup = popupEl;
    popupTimeout = setTimeout(removePopup, 5000);
    // Dismiss on click outside after a brief delay
    setTimeout(function () {
      document.addEventListener('click', dismissPopupOnClickOutside, { once: true });
    }, 100);
  }

  function dismissPopupOnClickOutside(e) {
    if (currentPopup && !currentPopup.contains(e.target)) {
      removePopup();
    }
  }

  function removePopup() {
    if (currentPopup) {
      currentPopup.remove();
      currentPopup = null;
    }
    if (popupTimeout) {
      clearTimeout(popupTimeout);
      popupTimeout = null;
    }
  }

  // ── Public API ─────────────────────────────────────────────────────

  window.DelveMapPanel = {
    init: init,
    updateMap: updateMap,
    softUpdateMap: function (svgString) { updateMap(svgString, true); },
    centerOnCurrentRoom: centerOnCurrentRoom,
    destroy: destroy
  };
})();
