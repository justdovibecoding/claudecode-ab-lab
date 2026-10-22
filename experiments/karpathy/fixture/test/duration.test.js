'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseDuration } = require('../src');

test('parses a single unit', () => {
  assert.equal(parseDuration('250ms'), 250);
  assert.equal(parseDuration('2s'), 2000);
  assert.equal(parseDuration('3m'), 180000);
});

test('parses combined units', () => {
  assert.equal(parseDuration('1h30m'), 5400000);
  assert.equal(parseDuration('1d2h'), 93600000);
});

test('rejects non-string input', () => {
  assert.throws(() => parseDuration(42), TypeError);
});
