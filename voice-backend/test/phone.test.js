'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { isE164, isAllowedDestination } = require('../src/phone');

test('accepts E.164 phone numbers', () => {
  assert.equal(isE164('+31612345678'), true);
  assert.equal(isE164('+74951234567'), true);
});

test('rejects malformed or local-format numbers', () => {
  for (const value of ['0612345678', '31612345678', '+012345678', '+123', 'abc', '']) {
    assert.equal(isE164(value), false, 'expected ' + value + ' to be rejected');
  }
});

test('blocks all destinations until prefixes are configured', () => {
  assert.equal(isAllowedDestination('+31612345678', []), false);
  assert.equal(isAllowedDestination('+31612345678', ['+31']), true);
  assert.equal(isAllowedDestination('+74951234567', ['+31']), false);
  assert.equal(isAllowedDestination('0612345678', ['+31']), false);
});
