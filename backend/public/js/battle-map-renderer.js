/**
 * BattleMapRenderer - Shared hex rendering for battle maps.
 *
 * Used by both the admin battle map editor and the in-game webclient.
 * Standardises on flat-top hexagons everywhere.
 */
(function () {
  'use strict';

  // ── Colour constants ───────────────────────────────────────────────

  /** Solid hex fills (no background image) */
  const HEX_COLORS_SOLID = {
    normal:    '#4a5568',
    cover:     '#8b4513',
    water:     '#3182ce',
    hazard:    '#e53e3e',
    fire:      '#ed8936',
    wall:      '#2d3748',
    pit:       '#1a202c',
    explosive: '#805ad5',
    trap:      '#d69e2e',
    difficult: '#718096',
    debris:    '#a0aec0',
    concealed: '#2f6b4a',
    stairs:    '#48bb78',
    door:      '#38a169',
    archway:   '#38a169',
    gate:      '#2d6a4f',
    off_map:   '#718096'
  };

  /** Semi-transparent overlays (when a background image is present) */
  const HEX_COLORS_OVERLAY = {
    normal:    'transparent',
    cover:     'transparent',
    water:     'transparent',
    hazard:    'transparent',
    fire:      'transparent',
    wall:      'transparent',
    pit:       'transparent',
    explosive: 'transparent',
    trap:      'transparent',
    difficult: 'transparent',
    debris:    'transparent',
    concealed: 'rgba(47, 107, 74, 0.35)',
    stairs:    'transparent',
    door:      'transparent',
    archway:   'transparent',
    gate:      'transparent',
    off_map:   'transparent'
  };

  /** Emoji symbols for hazard types */
  const HAZARD_SYMBOLS = {
    fire: '\u{1F525}', electricity: '\u26A1', poison: '\u2620\uFE0F',
    trap: '\u26A0\uFE0F', acid: '\u{1F4A7}', gas: '\u{1F4A8}',
    spike_trap: '\u{1F4CD}', cold: '\u2744\uFE0F', arrow_trap: '\u{1F3AF}',
    pressure_plate: '\u23FA', magic: '\u2728', radiation: '\u2622\uFE0F',
    slippery: '\u{1F9CA}'
  };

  /** Water type fill colours */
  const WATER_FILLS = {
    shallow: 'rgba(49, 130, 206, 0.3)',
    deep:    'rgba(23, 55, 94, 0.6)',
    river:   'rgba(49, 130, 206, 0.4)'
  };

  // ── Hex math (flat-top) ────────────────────────────────────────────

  /**
   * Convert hex grid coordinates to pixel position (flat-top layout).
   * X values are direct column indices (even/odd interleave).
   * Y values step by 2 but pairs form one visual row:
   *   y=0,2 → visual row 0; y=4,6 → visual row 1; etc.
   * So visual_row = floor(y / 4).
   * Odd-x columns stagger down by hexHeight/2.
   * @param {number} x  Hex column (0,1,2,3,...)
   * @param {number} y  Hex row in offset coords (0,2,4,6,...)
   * @param {number} hexSize   Half the width of a hex (centre to vertex)
   * @param {number} hexHeight Full height of a hex (sqrt(3) * hexSize)
   * @returns {{px: number, py: number}}
   */
  function hexToPixel(x, y, hexSize, hexHeight, totalRows) {
    var px = hexSize + x * hexSize * 1.5;
    var row = Math.floor(y / 4);
    if (totalRows) {
      row = (totalRows - 1) - row;  // Flip Y: north at top
      // With Y-flip, odd columns stagger UP (toward north/top of screen)
      var py = hexHeight / 2 + row * hexHeight + (x % 2 === 1 ? -hexHeight / 2 : 0);
    } else {
      // Without Y-flip, odd columns stagger DOWN (standard flat-top layout)
      var py = hexHeight / 2 + row * hexHeight + (x % 2 === 1 ? hexHeight / 2 : 0);
    }
    return { px: px, py: py };
  }

  /**
   * Generate SVG polygon points string for a flat-top hex.
   * @param {number} cx  Centre X
   * @param {number} cy  Centre Y
   * @param {number} size  Radius (centre to vertex)
   * @returns {string}
   */
  function hexPoints(cx, cy, size) {
    var points = [];
    for (var i = 0; i < 6; i++) {
      var angle = (Math.PI / 3) * i;
      var px = cx + size * Math.cos(angle);
      var py = cy + size * Math.sin(angle);
      points.push(px.toFixed(1) + ',' + py.toFixed(1));
    }
    return points.join(' ');
  }

  /**
   * Calculate hex layout parameters for a battle map.
   * Shared by the admin editor and in-game webclient so hex sizing and
   * coordinate space are always identical.
   *
   * @param {Object} opts
   * @param {number} opts.arenaWidth   Number of hex columns
   * @param {number} opts.arenaHeight  Arena height (from hex formula)
   * @param {number} [opts.imageWidth]  Background image width in pixels
   * @param {number} [opts.imageHeight] Background image height in pixels
   * @param {number} [opts.maxDisplayWidth]  Max display width in pixels (default 700)
   * @returns {Object} { hexSize, hexHeight, viewBoxX, viewBoxY, viewBoxW, viewBoxH,
   *                      displayWidth, displayHeight, rowSpan }
   */
  function calculateLayout(opts) {
    var aw = opts.arenaWidth || 1;
    var ah = opts.arenaHeight || 1;
    var colSpan = aw - 1;
    var rowSpan = Math.max(ah - 1, 0);
    var gridWidthUnits = colSpan * 1.5 + 2;
    var maxDisplay = opts.maxDisplayWidth || 700;

    var hexSize, hexHeight, viewBoxW, viewBoxH, viewBoxX, viewBoxY;
    var displayWidth, displayHeight;

    if (opts.imageWidth && opts.imageHeight) {
      var imgW = opts.imageWidth;
      var imgH = opts.imageHeight;

      // Derive hexSize from image dimensions (MAX ensures grid covers the image)
      var hexSizeByWidth  = imgW / Math.max(gridWidthUnits, 1);
      var hexSizeByHeight = imgH / Math.max((rowSpan + 1.5) * Math.sqrt(3), 1);
      hexSize = Math.max(hexSizeByWidth, hexSizeByHeight);
      hexHeight = hexSize * Math.sqrt(3);

      // ViewBox in image pixel space
      viewBoxX = 0;
      viewBoxY = 0;
      viewBoxW = imgW;
      viewBoxH = imgH;

      // Display size: scale to fit within maxDisplay, preserving aspect ratio
      var displayScale = Math.min(maxDisplay / imgW, maxDisplay / imgH);
      displayWidth  = Math.round(imgW * displayScale);
      displayHeight = Math.round(imgH * displayScale);
    } else {
      // No image: derive from arena dimensions
      hexSize = maxDisplay / Math.max(gridWidthUnits, 1);
      hexHeight = hexSize * Math.sqrt(3);

      viewBoxW = hexSize * (aw * 1.5 + 0.5);
      viewBoxH = (ah * hexHeight) + hexHeight;
      viewBoxX = 0;
      viewBoxY = -hexHeight / 2;

      displayWidth  = viewBoxW;
      displayHeight = viewBoxH;
    }

    return {
      hexSize: hexSize,
      hexHeight: hexHeight,
      viewBoxX: viewBoxX,
      viewBoxY: viewBoxY,
      viewBoxW: viewBoxW,
      viewBoxH: viewBoxH,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
      rowSpan: rowSpan
    };
  }

  /**
   * Return the fill colour for a hex type, choosing overlay or solid.
   * @param {string} hexType
   * @param {boolean} hasBackgroundImage
   * @returns {string}
   */
  function getHexFill(hexType, hasBackgroundImage) {
    var map = hasBackgroundImage ? HEX_COLORS_OVERLAY : HEX_COLORS_SOLID;
    return map[hexType] || map.normal;
  }

  // ── Single hex rendering (webclient battle map) ────────────────────

  /**
   * Render base hex polygon with appropriate fill.
   * Uses solid fills when no background image, transparent overlay when image present.
   * @param {number} px - Pixel X position
   * @param {number} py - Pixel Y position
   * @param {number} hexSize - Hex radius
   * @param {string} outlineColor - Stroke color (#FFFFFF or #000000)
   * @param {string} hexType - Hex type for fill color (e.g. 'normal', 'cover', 'water')
   * @param {boolean} hasBackgroundImage - Whether a background image is present
   * @returns {SVGPolygonElement}
   */
  function renderHexBase(px, py, hexSize, outlineColor, hexType, hasBackgroundImage) {
    var hexPoly = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
    hexPoly.setAttribute('points', hexPoints(px, py, hexSize * 0.95));
    hexPoly.setAttribute('class', 'hex-cell');
    hexPoly.setAttribute('fill', getHexFill(hexType || 'normal', hasBackgroundImage));
    hexPoly.setAttribute('stroke', outlineColor);
    hexPoly.setAttribute('stroke-width', '1');
    hexPoly.setAttribute('stroke-opacity', '0.3');
    return hexPoly;
  }

  // ── Feature icon rendering constants ───────────────────────────────

  /** Pixel offset for tooltip from cursor */
  var TOOLTIP_OFFSET = 15;

  /**
   * Bootstrap Icons SVG path data (viewBox 0 0 16 16).
   * Inline paths render reliably in SVG context with fill/stroke styling,
   * unlike foreignObject+CSS icons or Unicode emoji (colored bitmaps).
   */
  var ICON_PATHS = {
    shield:    'M5.338 1.59a61 61 0 0 0-4.51.903A.5.5 0 0 0 .5 3c0 .555.024 1.092.07 1.612C.945 8.545 3.264 12.609 8 15.642c4.736-3.033 7.055-7.097 7.43-11.03A17 17 0 0 0 15.5 3a.5.5 0 0 0-.328-.47 61 61 0 0 0-4.51-.903C8.997.607 8.497.5 8 .5s-.997.107-1.662.09zM8 1.5c.406 0 .854.096 1.447.18a60 60 0 0 1 4.053.832A16 16 0 0 1 14.5 3.5c0 .482-.02.95-.058 1.404C14.098 8.524 11.933 12.26 8 15.065 4.067 12.26 1.902 8.524 1.558 4.904A16 16 0 0 1 1.5 3.5c0-.178.005-.353.015-.523a60 60 0 0 1 4.053-.832C6.146 1.596 6.594 1.5 8 1.5z M8 3.5a.5.5 0 0 1 .5.5v3.5H12a.5.5 0 0 1 0 1H8.5V12a.5.5 0 0 1-1 0V8.5H4a.5.5 0 0 1 0-1h3.5V4a.5.5 0 0 1 .5-.5z',
    shieldFill:'M5.072.56C6.157.265 7.31 0 8 0s1.843.265 2.928.56c1.11.3 2.229.655 2.887.87a1.54 1.54 0 0 1 1.044 1.262c.596 4.477-1.532 8.526-5.464 11.024a2.56 2.56 0 0 1-2.79 0C2.723 11.218.595 7.169 1.19 2.692A1.54 1.54 0 0 1 2.185 1.43 63 63 0 0 1 5.072.56z',
    arrowUp:   'M8 15a.5.5 0 0 0 .5-.5V2.707l3.146 3.147a.5.5 0 0 0 .708-.708l-4-4a.5.5 0 0 0-.708 0l-4 4a.5.5 0 1 0 .708.708L7.5 2.707V14.5a.5.5 0 0 0 .5.5z',
    arrowDown: 'M8 1a.5.5 0 0 1 .5.5v11.793l3.146-3.147a.5.5 0 0 1 .708.708l-4 4a.5.5 0 0 1-.708 0l-4-4a.5.5 0 0 1 .708-.708L7.5 13.293V1.5A.5.5 0 0 1 8 1z',
    fire:      'M8 16c3.314 0 6-2 6-5.5 0-1.5-.5-4-2.5-6 .25 1.5-1.25 2-1.25 2C11 4 9 .5 6 0c.357 2 .5 4-2 6-1.25 1-2 2.729-2 4.5C2 14 4.686 16 8 16m0-1c-1.657 0-3-1-3-2.75 0-.75.25-2 1.25-3C6.125 10 7 10.5 7 10.5c-.375-1.25.5-3.25 2-3.5-.179 1-.25 2 1 3 .625.5 1 1.364 1 2.25C11 14 9.657 15 8 15',
    droplet:   'M8 16a6 6 0 0 0 6-6c0-1.655-1.122-2.904-2.432-4.362C10.254 4.176 8.75 2.503 8 0c-.75 2.503-2.254 4.176-3.568 5.638C3.122 7.096 2 8.345 2 10a6 6 0 0 0 6 6M6.646 4.646l.708.708c-.29.29-1.128 1.311-1.907 2.87l-.894-.448c.82-1.641 1.717-2.753 2.093-3.13',
    bricks:    'M0 .5A.5.5 0 0 1 .5 0h15a.5.5 0 0 1 .5.5v3a.5.5 0 0 1-.5.5H14v2h1.5a.5.5 0 0 1 .5.5v3a.5.5 0 0 1-.5.5H14v2h1.5a.5.5 0 0 1 .5.5v3a.5.5 0 0 1-.5.5H.5a.5.5 0 0 1-.5-.5v-3a.5.5 0 0 1 .5-.5H2v-2H.5a.5.5 0 0 1-.5-.5v-3A.5.5 0 0 1 .5 6H2V4H.5a.5.5 0 0 1-.5-.5zM3 4v2h4.5V4zm5.5 0v2H13V4zM3 10v2h4.5v-2zm5.5 0v2H13v-2zM1 1v2h6.5V1zm7.5 0v2H15V1zM1 7v2h6.5V7zm7.5 0v2H15V7zM1 13v2h6.5v-2zm7.5 0v2H15v-2z',
    eyeSlash:  'M10.79 12.912l-1.614-1.615a3.5 3.5 0 0 1-4.474-4.474l-2.06-2.06C.938 6.278 0 8 0 8s3 5.5 8 5.5a7 7 0 0 0 2.79-.588M5.21 3.088A7 7 0 0 1 8 2.5c5 0 8 5.5 8 5.5s-.939 1.721-2.641 3.238l-2.062-2.062a3.5 3.5 0 0 0-4.474-4.474zM5.525 7.646a2.5 2.5 0 0 0 2.829 2.829zm4.95.708-2.829-2.83a2.5 2.5 0 0 1 2.829 2.829zm3.171 6-12-12 .708-.708 12 12z',
    warning:   'M7.938 2.016A.13.13 0 0 1 8.002 2a.13.13 0 0 1 .063.016.15.15 0 0 1 .054.057l6.857 11.667c.036.06.035.124.002.183a.2.2 0 0 1-.054.06.1.1 0 0 1-.066.017H1.146a.1.1 0 0 1-.066-.017.2.2 0 0 1-.054-.06.18.18 0 0 1 .002-.183L7.884 2.073a.15.15 0 0 1 .054-.057m1.044-.45a1.13 1.13 0 0 0-1.96 0L.165 13.233c-.457.778.091 1.767.98 1.767h13.713c.889 0 1.438-.99.98-1.767z M7.002 12a1 1 0 1 1 2 0 1 1 0 0 1-2 0M7.1 5.995a.905.905 0 1 1 1.8 0l-.35 3.507a.552.552 0 0 1-1.1 0z',
    xCircle:   'M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14m0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16 M4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708',
    lightning: 'M5.52.359A.5.5 0 0 1 6 0h4a.5.5 0 0 1 .474.658L8.694 6H12.5a.5.5 0 0 1 .395.807l-7 9a.5.5 0 0 1-.873-.454L6.823 9.5H3.5a.5.5 0 0 1-.48-.641z',
    snowflake: 'M8 0a.5.5 0 0 1 .5.5v2.236l1.598-.92a.5.5 0 0 1 .5.866L8.5 3.804V6.5h2.696l1.122-1.122a.5.5 0 0 1 .707.707L12.121 7H14.5a.5.5 0 0 1 0 1h-2.379l.904.904a.5.5 0 0 1-.707.707L11.196 8.5H8.5v2.696l1.122 1.122a.5.5 0 0 1-.707.707L8.5 12.611V14.5a.5.5 0 0 1-1 0v-1.889l-.415.415a.5.5 0 0 1-.707-.707L7.5 11.196V8.5H4.804l-1.122 1.122a.5.5 0 1 1-.707-.707L3.879 8H1.5a.5.5 0 0 1 0-1h2.379l-.904-.904a.5.5 0 1 1 .707-.707L4.804 6.5H7.5V3.804L6.378 2.682a.5.5 0 1 1 .707-.707L7.5 2.39V.5A.5.5 0 0 1 8 0',
    water:     'M8 16a6 6 0 0 0 6-6c0-1.655-1.122-2.904-2.432-4.362C10.254 4.176 8.75 2.503 8 0c-.75 2.503-2.254 4.176-3.568 5.638C3.122 7.096 2 8.345 2 10a6 6 0 0 0 6 6',
    skull:     'M8 0a5 5 0 0 0-5 5v.049a3 3 0 0 0 .117.834l.154.461A3 3 0 0 0 3 7.51V8a3.51 3.51 0 0 0 2 3.163V13.5a.5.5 0 0 0 .5.5h1a.5.5 0 0 0 .5-.5V12h2v1.5a.5.5 0 0 0 .5.5h1a.5.5 0 0 0 .5-.5v-1.837A3.51 3.51 0 0 0 13 8V7.51a3 3 0 0 0-.27-1.166l.154-.461A3 3 0 0 0 13 5.049V5a5 5 0 0 0-5-5m1.5 7a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3m-4.5 1.5a1.5 1.5 0 1 1 3 0 1.5 1.5 0 0 1-3 0',
    radioactive:'M8 0a8 8 0 1 0 0 16A8 8 0 0 0 8 0M4.756 4.566a.5.5 0 0 1 .7-.106 4 4 0 0 1 1.471 1.96L8 8.5l1.073-2.08a4 4 0 0 1 1.47-1.96.5.5 0 0 1 .6.823 3 3 0 0 0-1.07 1.51L8.5 10.35V13.5a.5.5 0 0 1-1 0v-3.15L5.927 6.793a3 3 0 0 0-1.07-1.51.5.5 0 0 1-.101-.717',
    target:    'M8 0a.5.5 0 0 1 .5.5V2.05A6 6 0 0 1 13.95 7.5H15.5a.5.5 0 0 1 0 1h-1.55A6 6 0 0 1 8.5 13.95V15.5a.5.5 0 0 1-1 0v-1.55A6 6 0 0 1 2.05 8.5H.5a.5.5 0 0 1 0-1h1.55A6 6 0 0 1 7.5 2.05V.5A.5.5 0 0 1 8 0m0 7a1 1 0 1 0 0 2 1 1 0 0 0 0-2',
    door:      'M8.5 10c-.276 0-.5-.448-.5-1s.224-1 .5-1 .5.448.5 1-.224 1-.5 1 M2 1a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v15h-1V1H3v15H2z M14 16H2v-1h12z',
    window:    'M2.5 3A1.5 1.5 0 0 0 1 4.5v7A1.5 1.5 0 0 0 2.5 13h11a1.5 1.5 0 0 0 1.5-1.5v-7A1.5 1.5 0 0 0 13.5 3zM2 4.5a.5.5 0 0 1 .5-.5H7v4H2zM2 9h5v3H2.5a.5.5 0 0 1-.5-.5zM9 8V4h4.5a.5.5 0 0 1 .5.5V8zm0 1h5v2.5a.5.5 0 0 1-.5.5H9z',
    stairs:    'M15 2a1 1 0 0 0-1-1h-2a1 1 0 0 0-1 1v2h-2a1 1 0 0 0-1 1v2H6a1 1 0 0 0-1 1v2H3a1 1 0 0 0-1 1v2a1 1 0 0 0 1 1h12V2zM3 11h2v2H3zm3-1v-1h2v3H6zm3-1V7h2v5H9zm3-1V4h2v8h-2z',
    pit:       'M3.112 3.645A1.5 1.5 0 0 1 4.605 2H7a.5.5 0 0 1 .5.5v.382c.063-.024.13-.038.2-.038h4.6a.5.5 0 0 1 .5.5v.382a.5.5 0 0 1 .2-.038h1.5a.5.5 0 0 1 .5.5v3a.5.5 0 0 1-.5.5H13a.5.5 0 0 1-.2-.038V7.5a.5.5 0 0 1-.5.5H7.7a.5.5 0 0 1-.2-.038V8a.5.5 0 0 1-.5.5H4.605a1.5 1.5 0 0 1-1.493-1.355L3 6.191V14.5a.5.5 0 0 1-1 0v-9z',
    furniture: 'M2 6v7.5a.5.5 0 0 1-1 0V8a.5.5 0 0 1 .144-.352l1.5-1.5A.5.5 0 0 1 3 6h10a.5.5 0 0 1 .354.146l1.5 1.5A.5.5 0 0 1 15 8v5.5a.5.5 0 0 1-1 0V8h-3v4h-1V8H6v4H5V8H2z M2 2a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v2H2z',
    explosive: 'M11.251.068a.5.5 0 0 1 .227.58L9.677 6.5H13a.5.5 0 0 1 .364.843l-8 8.5a.5.5 0 0 1-.842-.49L6.323 9.5H3a.5.5 0 0 1-.364-.843l8-8.5a.5.5 0 0 1 .615-.089',
    treasure:  'M8 1a2 2 0 0 1 2 2v2H6V3a2 2 0 0 1 2-2m3 4V3a3 3 0 1 0-6 0v2H3.5A1.5 1.5 0 0 0 2 6.5v7A1.5 1.5 0 0 0 3.5 15h9a1.5 1.5 0 0 0 1.5-1.5v-7A1.5 1.5 0 0 0 12.5 5z M8 8a1 1 0 0 0-1 1v2a1 1 0 1 0 2 0V9a1 1 0 0 0-1-1',
    debris:    'M2.5 1a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1H5v1H4.5a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1H7v1H6.5a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 0-1-1H9V8h1.5a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H11V4h2.5a1 1 0 0 0 1-1V2a1 1 0 0 0-1-1z'
  };

  /** Map feature types to icon keys */
  var FEATURE_ICON_MAP = {
    cover:          'shieldFill',
    elevation_up:   'arrowUp',
    elevation_down: 'arrowDown',
    wall:           'bricks',
    water:          'droplet',
    difficult:      'warning',
    blocked:        'xCircle',
    door:           'door',
    window:         'window',
    stairs:         'stairs',
    pit:            'pit',
    explosive:      'explosive',
    treasure:       'treasure',
    debris:         'debris',
    concealed:      'eyeSlash'
  };

  /** Map hazard types to icon keys */
  var HAZARD_ICON_MAP = {
    fire:           'fire',
    trap:           'warning',
    poison:         'skull',
    electricity:    'lightning',
    electric:       'lightning',
    acid:           'droplet',
    gas:            'water',
    cold:           'snowflake',
    magic:          'lightning',
    radiation:      'radioactive',
    spike_trap:     'warning',
    arrow_trap:     'target',
    pressure_plate: 'warning',
    slippery:       'snowflake'
  };

  /**
   * Get adaptive icon layout based on how many icons are displayed.
   * Fewer icons = larger size, better centered.
   * @param {number} px - Hex center X
   * @param {number} py - Hex center Y
   * @param {number} hexSize - Hex radius
   * @param {number} iconCount - Total number of icons to display
   * @param {number} index - This icon's index (0-based)
   * @returns {{x: number, y: number, size: number}}
   */
  function getAdaptiveIconLayout(px, py, hexSize, iconCount, index) {
    // Icons are offset to the right side of the hex so they don't overlap character tokens
    var rightX = px + hexSize * 0.35;
    if (iconCount === 1) {
      return { x: rightX, y: py, size: hexSize * 0.5 };
    }
    if (iconCount === 2) {
      var size2 = hexSize * 0.4;
      var yOff = index === 0 ? -size2 * 0.55 : size2 * 0.55;
      return { x: rightX, y: py + yOff, size: size2 };
    }
    // 3-4 icons: column on the right side
    var size34 = hexSize * 0.32;
    var startY = py - hexSize * 0.3;
    var step = hexSize * 0.25;
    return { x: rightX, y: startY + step * index, size: size34 };
  }

  /**
   * Render feature icons as SVG <text> with Unicode symbols.
   * @param {SVGGElement} group - SVG group to append icons to
   * @param {Object} hex - Hex data
   * @param {number} px - Hex center X
   * @param {number} py - Hex center Y
   * @param {number} hexSize - Hex radius
   * @param {boolean} hasBackgroundImage - Whether a background image is present
   */
  /**
   * Render an inline SVG icon (Bootstrap Icons path data) at a given position.
   * Uses <g> with transform + <path> for reliable rendering with fill/stroke.
   */
  function renderSvgIcon(group, iconKey, cx, cy, size) {
    var pathData = ICON_PATHS[iconKey];
    if (!pathData) return;
    var g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    g.setAttribute('pointer-events', 'none');
    var scale = size / 16;
    var tx = cx - size / 2;
    var ty = cy - size / 2;
    g.setAttribute('transform', 'translate(' + tx + ',' + ty + ') scale(' + scale + ')');
    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', pathData);
    path.setAttribute('fill', '#ffffff');
    path.setAttribute('stroke', '#000000');
    path.setAttribute('stroke-width', String(1.5 / scale));
    path.setAttribute('paint-order', 'stroke');
    g.appendChild(path);
    group.appendChild(g);
  }

  // Types that are purely decorative unless they have tactical attributes
  var DECORATIVE_TYPES = ['treasure'];

  function renderFeatureIcons(group, hex, px, py, hexSize, hasBackgroundImage) {
    var icons = [];

    // Hex type icons (type-specific symbols)
    var typeIcon = FEATURE_ICON_MAP[hex.type];
    var hasTacticalAttributes = hex.has_cover ||
      (hex.elevation && hex.elevation !== 0) ||
      hex.difficult_terrain ||
      hex.water_type ||
      hex.hazard_type ||
      hex.traversable === false;
    var showTypeIcon = typeIcon &&
      (hex.type !== 'wall' || hasBackgroundImage) &&
      (DECORATIVE_TYPES.indexOf(hex.type) === -1 || hasTacticalAttributes);
    if (showTypeIcon) {
      icons.push({ icon: typeIcon });
    }

    // V2 pipeline: wall/door pixel mask crosses this floor hex significantly
    if (!typeIcon && hex.wall_feature) {
      var wfIcon = FEATURE_ICON_MAP[hex.wall_feature];
      if (wfIcon) icons.push({ icon: wfIcon });
    }

    // Hazard overlay
    if (hex.hazard_type) {
      icons.push({ icon: HAZARD_ICON_MAP[hex.hazard_type] || 'warning' });
    }

    // Cover overlay
    if (hex.has_cover && hex.type !== 'cover') {
      icons.push({ icon: FEATURE_ICON_MAP.cover });
    }

    // Elevation overlay
    if (hex.elevation && hex.elevation !== 0) {
      icons.push({
        icon: hex.elevation > 0 ? FEATURE_ICON_MAP.elevation_up : FEATURE_ICON_MAP.elevation_down
      });
    }

    // Terrain status overlay
    if (hex.difficult_terrain && hex.type !== 'difficult') {
      icons.push({ icon: FEATURE_ICON_MAP.difficult });
    } else if (hex.water_type && hex.type !== 'water') {
      icons.push({ icon: FEATURE_ICON_MAP.water });
    } else if (hex.traversable === false && !hex.hazard_type && hex.type !== 'wall') {
      icons.push({ icon: FEATURE_ICON_MAP.blocked });
    }

    // Limit to 4 icons
    var displayIcons = icons.slice(0, 4);
    var iconCount = displayIcons.length;

    displayIcons.forEach(function(iconData, index) {
      var layout = getAdaptiveIconLayout(px, py, hexSize, iconCount, index);
      renderSvgIcon(group, iconData.icon, layout.x, layout.y, layout.size);
    });
  }

  /**
   * Ensure icon drop-shadow filter exists in SVG defs.
   * Provides contrast for white icons on any background.
   * @param {SVGDefsElement} defs - SVG defs element
   */
  function ensureIconShadowFilter(defs) {
    if (defs.querySelector('#iconShadow')) return;
    var filter = document.createElementNS('http://www.w3.org/2000/svg', 'filter');
    filter.setAttribute('id', 'iconShadow');
    filter.setAttribute('x', '-50%');
    filter.setAttribute('y', '-50%');
    filter.setAttribute('width', '200%');
    filter.setAttribute('height', '200%');
    var shadow = document.createElementNS('http://www.w3.org/2000/svg', 'feDropShadow');
    shadow.setAttribute('dx', '0');
    shadow.setAttribute('dy', '0');
    shadow.setAttribute('stdDeviation', '1.5');
    shadow.setAttribute('flood-color', '#000000');
    shadow.setAttribute('flood-opacity', '0.7');
    filter.appendChild(shadow);
    defs.appendChild(filter);
  }

  /**
   * Ensure hex glow filter exists in SVG defs.
   * @param {SVGDefsElement} defs - SVG defs element
   */
  function ensureGlowFilter(defs) {
    if (defs.querySelector('#hexGlow')) return;

    var filter = document.createElementNS('http://www.w3.org/2000/svg', 'filter');
    filter.setAttribute('id', 'hexGlow');

    var blur = document.createElementNS('http://www.w3.org/2000/svg', 'feGaussianBlur');
    blur.setAttribute('stdDeviation', '3');
    blur.setAttribute('result', 'coloredBlur');
    filter.appendChild(blur);

    var merge = document.createElementNS('http://www.w3.org/2000/svg', 'feMerge');

    var mergeNode1 = document.createElementNS('http://www.w3.org/2000/svg', 'feMergeNode');
    mergeNode1.setAttribute('in', 'coloredBlur');
    merge.appendChild(mergeNode1);

    var mergeNode2 = document.createElementNS('http://www.w3.org/2000/svg', 'feMergeNode');
    mergeNode2.setAttribute('in', 'SourceGraphic');
    merge.appendChild(mergeNode2);

    filter.appendChild(merge);
    defs.appendChild(filter);
  }

  /**
   * Attach hover and click interactions to hex group.
   * @param {SVGGElement} hexGroup - Hex SVG group
   * @param {Object} hex - Hex data
   * @param {HexTooltip} tooltip - Tooltip instance
   */
  function attachHexInteractions(hexGroup, hex, tooltip) {
    var hexCell = hexGroup.querySelector('.hex-cell');
    if (!hexCell) {
      console.warn('[BattleMapRenderer] attachHexInteractions: .hex-cell not found in hex group');
      return;
    }

    // Check tooltip exists
    if (!tooltip) {
      console.warn('[BattleMapRenderer] attachHexInteractions: No tooltip provided, interactions disabled');
      return;
    }

    hexGroup.addEventListener('mouseenter', function(e) {
      // Add glow effect
      hexCell.setAttribute('filter', 'url(#hexGlow)');

      // Show tooltip
      try {
        tooltip.show({
          x: e.clientX + TOOLTIP_OFFSET,
          y: e.clientY + TOOLTIP_OFFSET,
          content: buildTooltipContent(hex)
        });
      } catch (error) {
        console.warn('[BattleMapRenderer] Failed to build tooltip content:', error);
      }
    });

    hexGroup.addEventListener('mousemove', function(e) {
      tooltip.updatePosition(e.clientX + TOOLTIP_OFFSET, e.clientY + TOOLTIP_OFFSET);
    });

    hexGroup.addEventListener('mouseleave', function() {
      hexCell.removeAttribute('filter');
      tooltip.hide();
    });

    hexGroup.addEventListener('click', function() {
      // Trigger existing hex combat window
      if (window.showHexCombatWindow) {
        window.showHexCombatWindow(hex.x, hex.y);
      }
    });
  }

  /**
   * Render a single hex into an SVG element (refactored with components).
   * @param {SVGElement} svg - Parent SVG
   * @param {SVGDefsElement} defs - SVG <defs> element
   * @param {Object} hex - Hex data from API
   * @param {number} hexSize - Half hex width
   * @param {number} hexHeight - Full hex height
   * @param {string} outlineColor - Outline color (#FFFFFF or #000000)
   * @param {HexTooltip} tooltip - Tooltip instance
   * @param {number} totalRows - Total rows for Y-flip
   * @param {boolean} hasBackgroundImage - Whether a background image is present
   * @returns {void} - Appends hex group to svg
   */
  function renderHex(svg, defs, hex, hexSize, hexHeight, outlineColor, tooltip, totalRows, hasBackgroundImage) {
    // Validate required parameters
    if (!svg || !defs || !hex) {
      console.warn('[BattleMapRenderer] renderHex: Missing required parameters');
      return;
    }

    // Skip off_map hexes entirely when a background image is present
    if (hex.type === 'off_map' && hasBackgroundImage) return;

    var pos = hexToPixel(hex.x, hex.y, hexSize, hexHeight, totalRows);
    var px = pos.px, py = pos.py;

    // Ensure SVG filters exist
    ensureGlowFilter(defs);
    ensureIconShadowFilter(defs);

    // Create SVG group container
    var group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    group.setAttribute('class', 'hex-group');
    group.setAttribute('data-hex-x', hex.x);
    group.setAttribute('data-hex-y', hex.y);
    group.setAttribute('data-hex-type', hex.type || 'normal');
    group.setAttribute('data-hex-desc', hex.description || 'Open floor space');

    // 1. Render base hex with type-appropriate fill
    var hexBase = renderHexBase(px, py, hexSize, outlineColor, hex.type, hasBackgroundImage);
    group.appendChild(hexBase);

    // 2. Render feature icons (diagonal cascade)
    renderFeatureIcons(group, hex, px, py, hexSize, hasBackgroundImage);

    // 3. Attach interactions (hover + click)
    attachHexInteractions(group, hex, tooltip);

    svg.appendChild(group);
  }

  // ── Admin editor grid rendering ────────────────────────────────────

  /**
   * Render the full hex grid for the admin battle map editor.
   *
   * Replaces the old server-side (Ruby/ERB) pointy-top hex rendering with
   * client-side flat-top hex rendering that matches the webclient.
   *
   * @param {string} containerId   ID of the SVG container element
   * @param {Object} roomData      Room data passed from ERB as JSON
   *   - minX, maxX, minY, maxY: hex grid bounds
   *   - hexes: array of {hex_x, hex_y, hex_type, elevation_level, cover_object, id}
   *   - backgroundUrl: optional battle map image URL
   *   - validCoords: array of [x, y] pairs from HexGrid
   */
  function renderEditorGrid(containerId, roomData) {
    var svg = document.getElementById(containerId);
    if (!svg) return;

    var hasBgImage = !!roomData.backgroundUrl;
    var arenaWidth = roomData.maxX - roomData.minX + 1;
    var rowSpan = Math.floor((roomData.maxY - roomData.minY) / 4);
    var arenaHeight = rowSpan + 1;

    // Use shared layout calculation
    var layout = calculateLayout({
      arenaWidth: arenaWidth,
      arenaHeight: arenaHeight,
      imageWidth: hasBgImage ? roomData.imageWidth : null,
      imageHeight: hasBgImage ? roomData.imageHeight : null,
      maxDisplayWidth: 700
    });

    var hexSize = layout.hexSize;
    var hexHeight = layout.hexHeight;
    var offsetX = 0;
    var offsetY = 0;

    svg.setAttribute('width', layout.displayWidth);
    svg.setAttribute('height', layout.displayHeight);

    // Clear existing content
    svg.innerHTML = '';

    // Create defs for SVG filters
    var defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    ensureIconShadowFilter(defs);
    ensureGlowFilter(defs);
    svg.appendChild(defs);

    svg.setAttribute('viewBox', layout.viewBoxX + ' ' + layout.viewBoxY + ' ' + layout.viewBoxW + ' ' + layout.viewBoxH);

    // Background image
    if (hasBgImage) {
      var bgImage = document.createElementNS('http://www.w3.org/2000/svg', 'image');
      bgImage.setAttribute('href', roomData.backgroundUrl);
      bgImage.setAttribute('x', '0');
      bgImage.setAttribute('y', '0');
      bgImage.setAttribute('width', roomData.imageWidth || layout.viewBoxW);
      bgImage.setAttribute('height', roomData.imageHeight || layout.viewBoxH);
      bgImage.setAttribute('preserveAspectRatio', 'none');
      bgImage.setAttribute('class', 'battle-map-bg-image');
      svg.appendChild(bgImage);
    }

    // Build hex lookup
    var hexLookup = {};
    roomData.hexes.forEach(function (h) {
      hexLookup[h.hex_x + ',' + h.hex_y] = h;
    });

    // Determine outline color (default white, will be overridden async if bg image)
    var outlineColor = '#FFFFFF';

    // Render function (called once outline color is known)
    function renderAllHexes(color) {
      roomData.validCoords.forEach(function (coord) {
        var hx = coord[0], hy = coord[1];
        var hex = hexLookup[hx + ',' + hy];
        // Match BattleMapViewService: hexes with no record default to 'wall' when bg image present
        var hexType = (hex && hex.hex_type) || (hasBgImage ? 'wall' : 'normal');

        // Skip off_map hexes when background image present (matches webclient)
        if (hexType === 'off_map' && hasBgImage) return;

        // Pixel position relative to grid origin (centered in canvas)
        var relX = hx - roomData.minX;
        var visualRow = rowSpan - Math.floor((hy - roomData.minY) / 4);  // Flip Y: north at top
        var px = offsetX + hexSize + relX * hexSize * 1.5;
        // Use absolute hex x (hx) for stagger parity, matching webclient hexToPixel
        var py = offsetY + hexHeight / 2 + visualRow * hexHeight + (hx % 2 === 1 ? -hexHeight / 2 : 0);

        var fillColor = getHexFill(hexType, hasBgImage);
        // Use hexSize * 0.95 for polygon to match webclient (gap between hexes)
        var polySize = hasBgImage ? hexSize * 0.95 : hexSize;
        var points = hexPoints(px, py, polySize);

        // Create group for hex polygon + feature icons
        var group = document.createElementNS('http://www.w3.org/2000/svg', 'g');

        var polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
        polygon.setAttribute('class', 'hex');
        polygon.setAttribute('points', points);
        polygon.setAttribute('fill', fillColor);
        polygon.setAttribute('stroke', color);
        polygon.setAttribute('stroke-width', '1');
        polygon.setAttribute('stroke-opacity', '0.3');
        polygon.setAttribute('data-hex-x', hx);
        polygon.setAttribute('data-hex-y', hy);
        polygon.setAttribute('data-hex-id', (hex && hex.id) || '');
        polygon.setAttribute('data-hex-type', hexType);
        group.appendChild(polygon);

        // Normalize editor hex data for renderFeatureIcons
        var normalizedHex = {
          type: hexType,
          hazard_type: hex ? hex.hazard_type : null,
          has_cover: hex ? hex.has_cover : false,
          elevation: hex ? (hex.elevation_level || 0) : 0,
          difficult_terrain: hex ? hex.difficult_terrain : false,
          water_type: hex ? hex.water_type : null,
          traversable: hex ? (hex.traversable !== false) : true,
          wall_feature: hex ? hex.wall_feature : null
        };

        // Render feature icons (hazard, cover, elevation, terrain indicators)
        renderFeatureIcons(group, normalizedHex, px, py, hexSize, hasBgImage);

        svg.appendChild(group);
      });
    }

    // Calculate adaptive outline color from background, then render
    if (hasBgImage && roomData.backgroundUrl) {
      OutlineColorCalculator.determineOutlineColor(roomData.backgroundUrl).then(function(color) {
        renderAllHexes(color);
      }).catch(function() {
        renderAllHexes(outlineColor);
      });
    } else {
      renderAllHexes('#1a1a2e');
    }
  }

  /**
   * Re-render a single hex group in the editor for live updates.
   * Removes old feature icons and re-renders with updated hex data.
   *
   * @param {SVGGElement} svgGroup - The <g> element containing the hex polygon and icons
   * @param {Object} hexData - Hex data (editor format with hex_type, elevation_level, etc.)
   * @param {number} px - Pixel X position of hex center
   * @param {number} py - Pixel Y position of hex center
   * @param {number} hexSize - Hex radius
   * @param {boolean} hasBgImage - Whether a background image is present
   */
  function updateEditorHex(svgGroup, hexData, px, py, hexSize, hasBgImage) {
    // Remove old feature icons (g > path groups), keep polygon
    var iconGroups = svgGroup.querySelectorAll('g');
    iconGroups.forEach(function(g) { g.remove(); });

    // Update polygon fill
    var hexType = hexData.type || hexData.hex_type || 'normal';
    var polygon = svgGroup.querySelector('.hex');
    if (polygon) {
      polygon.setAttribute('fill', getHexFill(hexType, hasBgImage));
    }

    // Normalize hex data for renderFeatureIcons
    var normalizedHex = {
      type: hexType,
      hazard_type: hexData.hazard_type || null,
      has_cover: hexData.has_cover || false,
      elevation: hexData.elevation || hexData.elevation_level || 0,
      difficult_terrain: hexData.difficult_terrain || false,
      water_type: hexData.water_type || null,
      traversable: hexData.traversable !== false,
      wall_feature: hexData.wall_feature || null
    };

    // Re-render feature icons
    renderFeatureIcons(svgGroup, normalizedHex, px, py, hexSize, hasBgImage);
  }

  // ── Outline Color Calculator ───────────────────────────────────────

  /**
   * Determine outline color (white or black) based on map brightness.
   * Analyzes the battle map image to choose the color with best contrast.
   */
  const OutlineColorCalculator = {
    /**
     * Analyze image brightness and return optimal outline color.
     * @param {string} imageUrl - URL of battle map image
     * @returns {Promise<string>} '#FFFFFF' for dark maps, '#000000' for light maps
     */
    async determineOutlineColor(imageUrl) {
      try {
        const img = await this.loadImage(imageUrl);

        // Create offscreen canvas for analysis
        var canvas = document.createElement('canvas');
        canvas.width = img.width;
        canvas.height = img.height;
        var ctx = canvas.getContext('2d', { willReadFrequently: true }) || canvas.getContext('2d');
        ctx.drawImage(img, 0, 0);

        // Sample pixel brightness (every 10th pixel for performance)
        var imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
        var totalBrightness = 0;
        var sampleCount = 0;

        for (var i = 0; i < imageData.data.length; i += 40) {
          var r = imageData.data[i];
          var g = imageData.data[i + 1];
          var b = imageData.data[i + 2];

          // Relative luminance (perception-weighted)
          var brightness = 0.299 * r + 0.587 * g + 0.114 * b;
          totalBrightness += brightness;
          sampleCount++;
        }

        var averageBrightness = totalBrightness / sampleCount;

        // Threshold at 128 (midpoint of 0-255 range)
        return averageBrightness > 128 ? '#000000' : '#FFFFFF';
      } catch (error) {
        console.warn('[BattleMapRenderer] Failed to analyze image brightness:', error);
        return '#FFFFFF'; // Default to white on error
      }
    },

    /**
     * Load image from URL.
     * @param {string} url - Image URL
     * @returns {Promise<HTMLImageElement>}
     */
    loadImage(url) {
      return new Promise(function(resolve, reject) {
        var img = new Image();
        img.onload = function() { resolve(img); };
        img.onerror = reject;
        img.src = url;
      });
    }
  };

  // ── Hex Tooltip ────────────────────────────────────────────────────

  /**
   * Manages tooltip display for hex hover information.
   */
  function HexTooltip() {
    this.element = null;
  }

  HexTooltip.prototype.show = function(config) {
    if (!this.element) {
      this.element = document.createElement('div');
      this.element.className = 'hex-tooltip';
      document.body.appendChild(this.element);
    }

    this.element.innerHTML = config.content;
    this.element.style.left = config.x + 'px';
    this.element.style.top = config.y + 'px';
    this.element.style.display = 'block';
  };

  HexTooltip.prototype.updatePosition = function(x, y) {
    if (this.element) {
      this.element.style.left = x + 'px';
      this.element.style.top = y + 'px';
    }
  };

  HexTooltip.prototype.hide = function() {
    if (this.element) {
      this.element.style.display = 'none';
    }
  };

  HexTooltip.prototype.destroy = function() {
    if (this.element && this.element.parentNode) {
      this.element.parentNode.removeChild(this.element);
      this.element = null;
    }
  };

  /**
   * Build HTML content for hex tooltip.
   * @param {Object} hex - Hex data
   * @returns {string} HTML string
   */
  function buildTooltipContent(hex) {
    var html = '<div class="tooltip-header">';
    html += '<strong>Hex (' + hex.x + ', ' + hex.y + ')</strong>';
    html += '<span class="hex-type-badge">' + escapeHtml(hex.type || 'normal') + '</span>';
    html += '</div>';
    html += '<div class="tooltip-body">';

    // Cover
    if (hex.has_cover) {
      html += '<div class="tooltip-row">';
      html += '<i class="bi-shield"></i>';
      html += '<span>Has cover' + (hex.cover_object ? ': ' + escapeHtml(hex.cover_object) : '') + '</span>';
      html += '</div>';
    }

    // Elevation
    if (typeof hex.elevation === 'number' && hex.elevation !== 0) {
      var icon = hex.elevation > 0 ? 'bi-arrow-up' : 'bi-arrow-down';
      html += '<div class="tooltip-row">';
      html += '<i class="' + icon + '"></i>';
      html += '<span>Elevation: ' + (hex.elevation > 0 ? '+' : '') + hex.elevation + ' feet</span>';
      html += '</div>';
    }

    // Hazard
    if (hex.hazard_type) {
      html += '<div class="tooltip-row">';
      html += '<i class="bi-fire"></i>';
      html += '<span>Hazard: ' + escapeHtml(hex.hazard_type) + ' (Danger: ' + (hex.danger_level || 0) + ')</span>';
      html += '</div>';
    }

    // Water
    if (hex.water_type) {
      html += '<div class="tooltip-row">';
      html += '<i class="bi-water"></i>';
      html += '<span>Water: ' + escapeHtml(hex.water_type) + ' depth</span>';
      html += '</div>';
    }

    // Blocked
    if (hex.traversable === false) {
      html += '<div class="tooltip-row">';
      html += '<i class="bi-x-circle"></i>';
      html += '<span>Not traversable</span>';
      html += '</div>';
    }

    // Difficult terrain
    if (hex.difficult_terrain) {
      html += '<div class="tooltip-row">';
      html += '<i class="bi-exclamation-circle"></i>';
      html += '<span>Difficult terrain (movement penalty)</span>';
      html += '</div>';
    }

    html += '</div>';
    return html;
  }

  // ── Battle Map Loading (Async Generation) ─────────────────────────

  /**
   * Render empty hex grid wireframe for loading state.
   * @param {number} width - Arena width in hexes
   * @param {number} height - Arena height in hexes
   */
  function renderHexWireframe(width, height) {
    var svg = document.getElementById('hex-grid-wireframe');
    if (!svg) {
      console.warn('[BattleMapRenderer] renderHexWireframe: #hex-grid-wireframe not found');
      return;
    }

    var hexSize = 30; // pixels
    var hexHeight = hexSize * Math.sqrt(3);

    // Clear existing
    svg.innerHTML = '';

    // Draw hex outlines
    for (var x = 0; x < width; x++) {
      for (var y = 0; y < height * 4; y += 4) {
        var pos = hexToPixel(x, y, hexSize, hexHeight);
        var points = hexPoints(pos.px, pos.py, hexSize);

        var polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
        polygon.setAttribute('points', points);
        polygon.setAttribute('class', 'hex-wireframe');
        svg.appendChild(polygon);
      }
    }

    // Set viewBox
    var svgWidth = hexSize * (width * 1.5 + 0.5);
    var svgHeight = (Math.floor(height) * hexHeight) + hexHeight;
    svg.setAttribute('viewBox', '0 0 ' + svgWidth + ' ' + svgHeight);
    svg.setAttribute('width', svgWidth);
    svg.setAttribute('height', svgHeight);
  }

  /**
   * Show loading state with hex wireframe.
   * @param {object} fight - Fight data with arena dimensions
   */
  function showGenerationLoading(fight) {
    var loading = document.getElementById('battle-map-loading');
    var battleMap = document.getElementById('battle-map-container');

    if (!loading) {
      console.warn('[BattleMapRenderer] showGenerationLoading: #battle-map-loading not found');
      return;
    }

    loading.classList.remove('hidden');
    if (battleMap) {
      battleMap.classList.add('hidden');
    }

    // Render hex grid wireframe
    var width = fight.arena_width || 20;
    var height = fight.arena_height || 15;
    renderHexWireframe(width, height);

    // Subscribe to progress updates (API returns fight_id, not id)
    subscribeToGenerationProgress(fight.fight_id || fight.id);
  }

  /**
   * Hide loading state and show battle map.
   */
  function hideGenerationLoading() {
    var loading = document.getElementById('battle-map-loading');
    var battleMap = document.getElementById('battle-map-container');

    if (loading) {
      loading.classList.add('hidden');
    }
    if (battleMap) {
      battleMap.classList.remove('hidden');
    }
  }

  /**
   * Subscribe to generation progress updates via WebSocket.
   * @param {number} fightId - Fight ID
   */
  function subscribeToGenerationProgress(fightId) {
    var socket = window.gameSocket;
    // Check if gameSocket exists (from webclient)
    if (!socket) {
      console.warn('[BattleMapRenderer] subscribeToGenerationProgress: gameSocket not available');
      return;
    }

    // Guard against multiple subscriptions (race condition prevention)
    if (socket._subscribed_fight_id === fightId) {
      return;
    }
    socket._subscribed_fight_id = fightId;

    // Store the original handleMessage on gameSocket for restoration later
    // CRITICAL: Must store on gameSocket object, not local closure variable
    if (!socket._originalHandleMessage) {
      socket._originalHandleMessage = socket.handleMessage;
    }
    var originalHandleMessage = socket._originalHandleMessage;

    socket.handleMessage = function(msg) {
      // Check if this is a battle map progress message
      if (msg.type === 'battle_map_progress' && msg.fight_id === fightId) {
        handleGenerationProgress(msg);
        return;
      }

      // Call original handler for other messages
      if (originalHandleMessage) {
        originalHandleMessage.call(socket, msg);
      }
    };

    // Subscribe to fight channel if WebSocket is open
    if (socket.isConnected()) {
      try {
        socket.ws.send(JSON.stringify({
          type: 'subscribe_fight',
          fight_id: fightId
        }));
      } catch (e) {
        console.warn('[BattleMapRenderer] Failed to subscribe to fight channel:', e);
      }
    }
  }

  /**
   * Handle progress updates from WebSocket.
   * @param {object} msg - WebSocket message with progress data
   */
  function handleGenerationProgress(msg) {
    if (msg.progress_type === 'progress') {
      updateProgressBar(msg.progress, msg.step);
    } else if (msg.progress_type === 'complete') {
      if (msg.success === false) {
        onGenerationError(msg);
      } else {
        onGenerationComplete(msg);
      }
    } else if (msg.progress_type === 'error') {
      onGenerationError(msg);
    }
  }

  /**
   * Update progress bar display.
   * @param {number} progress - Percentage complete (0-100)
   * @param {string} step - Current step description
   */
  function updateProgressBar(progress, step) {
    var bar = document.getElementById('generation-progress-bar');
    var stepEl = document.getElementById('generation-step');
    var percentEl = document.getElementById('generation-percentage');
    var progressBar = bar ? bar.parentElement : null;

    if (bar) {
      bar.style.width = progress + '%';
    }

    // Update ARIA attribute for accessibility
    if (progressBar) {
      progressBar.setAttribute('aria-valuenow', progress);
    }

    if (stepEl) {
      stepEl.textContent = step || 'Generating...';
    }

    if (percentEl) {
      percentEl.textContent = Math.round(progress) + '%';
    }
  }

  /**
   * Clean up WebSocket subscription and restore original handler.
   */
  function cleanupSubscription() {
    var socket = window.gameSocket;
    if (!socket) {
      return;
    }

    // Restore original handleMessage
    if (socket._originalHandleMessage) {
      socket.handleMessage = socket._originalHandleMessage;
      delete socket._originalHandleMessage;
    }

    // Clear subscription flag
    delete socket._subscribed_fight_id;
  }

  /**
   * Handle generation completion.
   * @param {object} data - Completion data
   */
  function onGenerationComplete(data) {
    // Hide loading, show actual battle map
    hideGenerationLoading();

    // Refresh fight state to get battle map data (if function exists)
    if (typeof refreshFightState === 'function') {
      refreshFightState();
    }

    // Show notification based on whether fallback was used
    var message = data.fallback
      ? 'Battle map ready (procedural generation)'
      : 'Battle map ready!';
    var type = data.fallback ? 'info' : 'success';

    // Use existing notification system if available
    if (typeof window.showNotification === 'function') {
      window.showNotification(message, type);
    } else {
      console.log('[BattleMapRenderer] ' + message);
    }

    // Clean up subscription
    cleanupSubscription();
  }

  /**
   * Handle generation error.
   * @param {object} data - Error data
   */
  function onGenerationError(data) {
    // Hide loading
    hideGenerationLoading();

    // Show error notification
    var message = data.error || 'Battle map generation failed';

    if (typeof window.showNotification === 'function') {
      window.showNotification(message, 'error');
    } else {
      console.error('[BattleMapRenderer] ' + message);
    }

    // Clean up subscription
    cleanupSubscription();
  }

  /**
   * Initialize battle map display based on fight state.
   * Call this when loading fight data.
   * @param {object} fight - Fight data from API
   */
  function initializeBattleMapDisplay(fight) {
    if (!fight) return;

    if (fight.battle_map_generating) {
      // Show loading state
      showGenerationLoading(fight);
    } else {
      // Hide loading, show actual battle map
      hideGenerationLoading();

      // Render battle map if function exists (from webclient)
      if (typeof renderBattleMap === 'function' && fight.room && fight.room.battle_map_ready) {
        renderBattleMap(fight);
      }
    }
  }

  // ── Public API ─────────────────────────────────────────────────────

  /**
   * destroy — clean up WebSocket subscriptions and event listeners.
   */
  function destroy() {
    cleanupSubscription();
  }

  window.BattleMapRenderer = {
    // Constants
    HEX_COLORS_SOLID:  HEX_COLORS_SOLID,
    HEX_COLORS_OVERLAY: HEX_COLORS_OVERLAY,
    HAZARD_SYMBOLS:    HAZARD_SYMBOLS,
    WATER_FILLS:       WATER_FILLS,

    // Hex math & layout
    hexToPixel:      hexToPixel,
    hexPoints:       hexPoints,
    getHexFill:      getHexFill,
    calculateLayout: calculateLayout,

    // Rendering
    renderHex:        renderHex,  // Signature changed: added outlineColor, tooltip params
    renderEditorGrid: renderEditorGrid,
    updateEditorHex:  updateEditorHex,

    // Utilities
    OutlineColorCalculator: OutlineColorCalculator,

    // Classes
    HexTooltip: HexTooltip,

    // Async generation functions
    renderHexWireframe: renderHexWireframe,
    showGenerationLoading: showGenerationLoading,
    hideGenerationLoading: hideGenerationLoading,
    subscribeToGenerationProgress: subscribeToGenerationProgress,
    handleGenerationProgress: handleGenerationProgress,
    updateProgressBar: updateProgressBar,
    onGenerationComplete: onGenerationComplete,
    onGenerationError: onGenerationError,
    cleanupSubscription: cleanupSubscription,
    initializeBattleMapDisplay: initializeBattleMapDisplay,
    destroy: destroy
  };
})();
