'use strict';

const UNITS = {
  ms: 1,
  s: 1000,
  m: 60 * 1000,
  h: 60 * 60 * 1000,
  d: 24 * 60 * 60 * 1000,
};

/**
 * Parse a duration string such as "1h30m" or "250ms" into milliseconds.
 */
function parseDuration(input) {
  if (typeof input !== 'string') {
    throw new TypeError('parseDuration expects a string');
  }
  const re = /(\d+)(ms|s|m|h|d)/g;
  let total = 0;
  let match;
  while ((match = re.exec(input)) !== null) {
    total += Number(match[1]) * UNITS[match[2]];
  }
  return total;
}

module.exports = { parseDuration, UNITS };
