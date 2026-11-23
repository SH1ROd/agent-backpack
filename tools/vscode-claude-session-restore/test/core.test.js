'use strict';

const assert = require('assert');
const core = require('../core');

const UUID_A = '1309e739-dc45-45f2-bf2f-b588f8738b22';
const UUID_B = '4cc238f2-bc23-4650-a315-38541a6fdbec';
const UUID_C = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

const sample = JSON.stringify([
  {
    pid: 100,
    cwd: 'E:\\Desktop\\agent-backpack',
    kind: 'interactive',
    startedAt: '2026-11-24T00:00:00Z',
    sessionId: UUID_A,
    name: 'main',
    status: 'busy'
  },
  {
    pid: 200,
    cwd: 'E:/Desktop/agent-backpack/',
    kind: 'interactive',
    startedAt: '2026-11-24T00:01:00Z',
    sessionId: UUID_B,
    name: 'new-main',
    status: 'idle'
  },
  {
    pid: 300,
    cwd: 'E:\\Desktop\\other-project',
    kind: 'interactive',
    startedAt: '2026-11-24T00:02:00Z',
    sessionId: UUID_C,
    name: 'other',
    status: 'idle'
  },
  {
    pid: 400,
    cwd: 'E:\\Desktop\\agent-backpack',
    sessionId: 'not-a-uuid',
    name: 'invalid'
  }
]);

const parsed = core.parseAgentsJson(sample);
assert.strictEqual(parsed.length, 3, 'invalid session ids must be filtered');
assert.strictEqual(core.parseAgentsJson('').length, 0);
assert.strictEqual(core.parseAgentsJson('[]').length, 0);

const forFolder = core.sessionsForFolder(parsed, 'e:\\desktop\\agent-backpack\\');
assert.strictEqual(forFolder.length, 2, 'path normalization should match slash/case variants');
assert.deepStrictEqual(
  forFolder.map(session => session.sessionId).sort(),
  [UUID_A, UUID_B].sort()
);

const snapshot = core.buildSnapshot(forFolder, 1);
assert.strictEqual(snapshot.length, 1);
assert.strictEqual(snapshot[0].sessionId, UUID_A);
assert.ok(snapshot[0].savedAt);

const deduped = core.buildSnapshot([forFolder[0], forFolder[0], forFolder[1]], 8);
assert.strictEqual(deduped.length, 2);

assert.strictEqual(core.terminalName({ sessionId: UUID_A, name: 'main' }), 'Claude: main [1309e739]');
assert.strictEqual(core.terminalName({ sessionId: UUID_A, name: '' }), 'Claude: 1309e739 [1309e739]');
assert.strictEqual(core.sanitizeName('a\nb\tc'), 'a b c');

assert.strictEqual(
  core.buildResumeCommand('claude', UUID_A, []),
  'claude --resume ' + UUID_A
);
assert.strictEqual(
  core.buildResumeCommand('claude', UUID_A, ['--dangerously-skip-permissions']),
  'claude --resume ' + UUID_A + ' --dangerously-skip-permissions'
);
assert.strictEqual(
  core.buildResumeCommand('C:\\Program Files\\PowerShell\\7\\pwsh.exe', UUID_A, []),
  '"C:\\Program Files\\PowerShell\\7\\pwsh.exe" --resume ' + UUID_A
);
assert.throws(() => core.buildResumeCommand('claude', 'bad-id', []), /Invalid Claude session id/);

assert.ok(core.isUuid(UUID_A));
assert.ok(!core.isUuid('not-a-uuid'));

const executable = core.findClaudeExecutable('claude');
assert.strictEqual(typeof executable, 'string');
assert.ok(executable.length > 0);

console.log('core tests passed');
