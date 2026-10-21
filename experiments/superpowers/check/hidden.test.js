'use strict';

// 숨은 채점 테스트. 작업 폴더(현재 디렉터리)의 결과물을 지시문 명세대로 검사한다.
// 에이전트에게는 보이지 않는다(작업 폴더 밖). experiment.json 의 check.command 에서 실행.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const lib = require(path.join(process.cwd(), 'src'));
const { parseDuration, formatDuration } = lib;

test('기존 동작 유지', () => {
  assert.equal(parseDuration('250ms'), 250);
  assert.equal(parseDuration('1h30m'), 5400000);
  assert.equal(parseDuration('1d2h'), 93600000);
  assert.equal(parseDuration('1m1ms'), 60001);
  assert.throws(() => parseDuration(42), TypeError);
});

test('소수 값', () => {
  assert.equal(parseDuration('1.5h'), 5400000);
  assert.equal(parseDuration('0.5s'), 500);
  assert.equal(parseDuration('2.25m'), 135000);
  assert.equal(parseDuration('1h0.5m'), 3630000);
});

test('공백 구분 허용', () => {
  assert.equal(parseDuration('1h 30m'), 5400000);
  assert.equal(parseDuration('  2s  '), 2000);
});

test('잘못된 입력은 RangeError', () => {
  for (const bad of ['', '   ', 'abc', '10x', '5 m', '1h30', 'h', '1..5h', '.h', '1h abc']) {
    assert.throws(() => parseDuration(bad), RangeError, JSON.stringify(bad));
  }
});

test('formatDuration 내보내기', () => {
  assert.equal(typeof formatDuration, 'function');
});

test('formatDuration 형식', () => {
  assert.equal(formatDuration(0), '0ms');
  assert.equal(formatDuration(250), '250ms');
  assert.equal(formatDuration(5400000), '1h30m');
  assert.equal(formatDuration(90061001), '1d1h1m1s1ms');
  assert.equal(formatDuration(86400000), '1d');
  assert.equal(formatDuration(3600500), '1h500ms');
});

test('formatDuration 잘못된 값은 RangeError', () => {
  for (const bad of [-1, 1.5, NaN, Infinity]) {
    assert.throws(() => formatDuration(bad), RangeError, String(bad));
  }
});

test('왕복', () => {
  for (const ms of [0, 1, 999, 1000, 59999, 3600000, 90061001, 123456789]) {
    assert.equal(parseDuration(formatDuration(ms)), ms);
  }
});
