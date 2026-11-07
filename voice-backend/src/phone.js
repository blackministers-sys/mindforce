'use strict';

function isE164(value) {
  return typeof value === 'string' && /^\+[1-9]\d{7,14}$/.test(value);
}

function isAllowedDestination(value, prefixes) {
  if (!isE164(value) || !Array.isArray(prefixes) || prefixes.length === 0) return false;
  return prefixes.some((prefix) => typeof prefix === 'string' && prefix.length > 0 && value.startsWith(prefix));
}

module.exports = { isE164, isAllowedDestination };
