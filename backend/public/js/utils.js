// Shared utility functions - imported via <script src="/js/utils.js"></script>
// Avoids duplication of common helpers across JS files and ERB views.

/**
 * Escape HTML special characters to prevent XSS.
 */
function escapeHtml(text) {
  if (text === null || text === undefined) return '';
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(String(text)));
  return div.innerHTML;
}

/**
 * Get CSRF token from meta tag.
 */
function getCsrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.content : '';
}

/**
 * Fetch wrapper with CSRF token, response.ok check, and error handling.
 * Usage: const data = await apiFetch('/api/endpoint', { method: 'POST', body: JSON.stringify(payload) });
 */
async function apiFetch(url, options = {}) {
  const method = (options.method || 'GET').toUpperCase();
  const headers = Object.assign({}, options.headers || {});
  if (method !== 'GET' && method !== 'HEAD') {
    headers['X-CSRF-Token'] = getCsrfToken();
    if (!headers['Content-Type'] && options.body && typeof options.body === 'string') {
      headers['Content-Type'] = 'application/json';
    }
  }
  const response = await fetch(url, Object.assign({}, options, { headers }));
  if (!response.ok) {
    const errorText = await response.text().catch(() => 'Unknown error');
    throw new Error(`API error ${response.status}: ${errorText}`);
  }
  const contentType = response.headers.get('content-type');
  if (contentType && contentType.includes('application/json')) {
    return response.json();
  }
  return response.text();
}
