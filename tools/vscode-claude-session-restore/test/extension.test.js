'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');
const core = require('../core');

const projectDir = path.resolve(__dirname, '..', '..', '..');
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-session-restore-test-'));
const fakeSessionId = '11111111-2222-4333-8444-555555555555';
const fakeSessionId2 = '99999999-8888-4777-8666-555555555555';
const commands = [];
const terminals = [];

const config = {
  enabled: true,
  autoRestore: true,
  allowUntrustedWorkspaces: false,
  snapshotIntervalSeconds: 0,
  maxSessions: 4,
  revealTerminals: true,
  claudeCommand: 'claude',
  extraArgs: ['--dangerously-skip-permissions'],
  clearSnapshotWhenNoSessions: true,
  diagnostics: true,
  launchMode: 'shell',
  restoreDelayMs: 0,
  staggerMs: 0
};

const fakeVscode = {
  version: '1.100.0',
  env: {
    sessionId: 'test-window-session'
  },
  Uri: {
    joinPath(base, ...parts) {
      return { fsPath: path.join(base.fsPath, ...parts), scheme: 'file' };
    },
    file(fsPath) {
      return { fsPath, scheme: 'file' };
    }
  },
  workspace: {
    isTrusted: true,
    workspaceFolders: [
      {
        name: 'agent-backpack',
        uri: { fsPath: projectDir, scheme: 'file' }
      }
    ],
    getConfiguration() {
      return {
        get(key) {
          return config[key];
        }
      };
    },
    onDidChangeConfiguration() {
      return { dispose() {} };
    },
    onWillSaveState() {
      return { dispose() {} };
    }
  },
  window: {
    terminals,
    createOutputChannel() {
      return { appendLine() {}, dispose() {} };
    },
    createTerminal(options) {
      const terminal = {
        name: options.name,
        show() {},
        sendText(command) {
          commands.push(command);
        }
      };
      terminals.push(terminal);
      return terminal;
    },
    showInformationMessage() {}
  },
  commands: {
    registerCommand(name, callback) {
      assert.strictEqual(typeof callback, 'function');
      return { dispose() {} };
    }
  }
};

const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (request === 'vscode') {
    return fakeVscode;
  }
  return originalLoad.call(this, request, parent, isMain);
};

const memento = new Map();
const context = {
  storageUri: { fsPath: tempDir },
  globalStorageUri: { fsPath: tempDir },
  workspaceState: {
    get(key) {
      return memento.get(key);
    },
    update(key, value) {
      memento.set(key, value);
      return Promise.resolve();
    }
  },
  subscriptions: []
};

const normalizedProject = core.normalizePath(projectDir);
const snapshot = {
  version: 1,
  folders: {
    [normalizedProject]: {
      savedAt: new Date().toISOString(),
      sessions: [
        {
          sessionId: fakeSessionId,
          name: 'mock-main',
          kind: 'interactive',
          status: 'idle',
          cwd: projectDir
        },
        {
          sessionId: fakeSessionId2,
          name: 'mock-test',
          kind: 'interactive',
          status: 'idle',
          cwd: projectDir
        }
      ]
    }
  }
};
fs.writeFileSync(path.join(tempDir, 'claude-sessions.json'), JSON.stringify(snapshot, null, 2), 'utf8');

async function main() {
  const extension = require('../extension');
  extension.activate(context);

  // Automatic restore waits 1500 ms after activation.
  await new Promise(resolve => setTimeout(resolve, 2600));

  assert.strictEqual(commands.length, 2, 'expected one restored terminal per session');
  const joinedCommands = commands.join('\n');
  assert.ok(joinedCommands.includes('--resume ' + fakeSessionId), 'first session id must be resumed');
  assert.ok(joinedCommands.includes('--resume ' + fakeSessionId2), 'second session id must be resumed');
  assert.ok(
    joinedCommands.includes('--dangerously-skip-permissions'),
    'configured extra arguments must be passed through'
  );
  assert.strictEqual(terminals.length, 2);
  assert.ok(terminals[0].name.startsWith(core.TERMINAL_PREFIX));

  extension.deactivate();
  Module._load = originalLoad;
  fs.rmSync(tempDir, { recursive: true, force: true });
  console.log('extension activation test passed');
}

main().catch(error => {
  Module._load = originalLoad;
  try {
    fs.rmSync(tempDir, { recursive: true, force: true });
  } catch (_) {
    // ignore cleanup failure
  }
  console.error(error);
  process.exit(1);
});
