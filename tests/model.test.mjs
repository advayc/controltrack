import test from 'node:test';
import assert from 'node:assert/strict';
import { readSession, countdown, duration, elapsed, groupTotals, lastSevenDays, uniqueGroups } from '../src/lib/model.ts';

test('reads Swift dates and rejects invalid history', () => {
  const session = readSession({ id: 's', name: 'Study', start: 0, plannedEnd: 3600, actualEnd: 1800 });
  assert.equal(session.start, Date.UTC(2001, 0, 1));
  assert.equal(elapsed(session), 1800000);
  assert.equal(readSession({ id: 'bad', name: 'Study', start: '0', plannedEnd: 1 }), null);
});

test('counts time across midnight without double counting', () => {
  const start = new Date(2026, 9, 27, 23, 30);
  const end = new Date(2026, 9, 28, 0, 30);
  const now = new Date(2026, 9, 28, 12);
  const days = lastSevenDays([{ id: 'a', name: 'Math', start: +start, plannedEnd: +end, actualEnd: +end }], now);
  assert.equal(days[5].ms, 30 * 60000);
  assert.equal(days[6].ms, 30 * 60000);
  assert.equal(days.reduce((sum, day) => sum + day.ms, 0), 60 * 60000);
});

test('caps active time at now and at the scheduled end', () => {
  const session = { id: 'a', name: 'Math', start: 0, plannedEnd: 60000 };
  assert.equal(elapsed(session, 30000), 30000);
  assert.equal(elapsed(session, 120000), 60000);
  assert.equal(countdown(15000), '00:00:15');
  assert.equal(countdown(61000), '00:01:01');
  assert.equal(countdown(3601000), '01:00:01');
  assert.equal(countdown(-3), '00:00:00');
  assert.equal(duration(3660000), '1h 1m');
});

test('normalizes groups and combines existing subject totals', () => {
  assert.deepEqual(uniqueGroups(['Math', 'math', ' Calculus ', 'Focus session']), ['Calculus', 'Math']);
  const sessions = [
    { id: 'a', name: 'Math', start: 0, plannedEnd: 60000, actualEnd: 60000 },
    { id: 'b', name: 'math', start: 100000, plannedEnd: 130000, actualEnd: 130000 },
  ];
  assert.deepEqual(groupTotals(sessions), [{ name: 'Math', ms: 90000 }]);
});
