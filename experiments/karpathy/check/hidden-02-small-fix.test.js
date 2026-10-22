'use strict';

// 숨은 채점 테스트(02-small-fix). 작업 폴더(현재 디렉터리)의 결과물을 검사한다.
// 제보된 소수 버그가 고쳐졌는지와, 원래 잘 되던 입력·공개 API가 그대로인지만 본다.
// 해석 불가 입력('abc' 등)을 어떻게 다루는지는 지시문에 없으므로 채점하지 않는다(scope.js 가 따로 기록).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const lib = require(path.join(process.cwd(), 'src'));
const { parseDuration } = lib;

test('제보된 소수 버그', () => {
  assert.equal(parseDuration('1.5h'), 5400000);
  assert.equal(parseDuration('0.5s'), 500);
  assert.equal(parseDuration('2.25m'), 135000);
  assert.equal(parseDuration('1h0.5m'), 3630000);
  assert.equal(parseDuration('1.5h30m'), 7200000);
});

test('원래 되던 입력은 그대로', () => {
  assert.equal(parseDuration('250ms'), 250);
  assert.equal(parseDuration('2s'), 2000);
  assert.equal(parseDuration('3m'), 180000);
  assert.equal(parseDuration('1h30m'), 5400000);
  assert.equal(parseDuration('1d2h'), 93600000);
  assert.equal(parseDuration('1m1ms'), 60001);
  assert.throws(() => parseDuration(42), TypeError);
});

test('공개 API 유지', () => {
  assert.equal(typeof parseDuration, 'function');
  assert.deepEqual({ ...lib.UNITS }, { ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 });
});
