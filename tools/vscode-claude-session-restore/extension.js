'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const core = require('./core');

const CONFIG_SECTION = 'claudeSessionRestore';
const STATE_FILE = 'claude-sessions.json';
const MEMENTO_KEY = 'claudeSessionRestore.snapshots.v1';

let output;
let timer;
let extensionContext;
let restoreRunning = false;
let snapshotRunning = false;
let lastSyncSnapshotAt = 0;
let lastRestoreAt = 0;
const EXTENSION_VERSION = '0.1.0';

function log(message) {
  try {
    if (output) {
      output.appendLine('[' + new Date().toISOString() + '] ' + message);
    }
  } catch (_) {
    // The output channel may already be disposed during shutdown.
  }
}

function getConfig() {
  return vscode.workspace.getConfiguration(CONFIG_SECTION);
}

function firstWorkspaceFolder() {
  const folders = vscode.workspace.workspaceFolders;
  return folders && folders.length > 0 ? folders[0] : null;
}

function folderKey(folder) {
  return core.normalizePath(folder.uri.fsPath);
}

function snapshotUri(context) {
  const base = context.storageUri || context.globalStorageUri;
  return vscode.Uri.joinPath(base, STATE_FILE);
}

function diagnosticsFile(context) {
  const base = context.storageUri || context.globalStorageUri;
  return vscode.Uri.joinPath(base, 'restore-diagnostics.jsonl').fsPath;
}

function recordDiagnostic(context, event, data) {
  const payload = Object.assign(
    {
      ts: new Date().toISOString(),
      event,
      version: EXTENSION_VERSION,
      vscode: vscode.version,
      windowSessionId: vscode.env.sessionId
    },
    data || {}
  );
  log('[diag] ' + event + ' ' + JSON.stringify(data || {}));
  try {
    if (getConfig().get('diagnostics') === false) {
      return;
    }
    const file = diagnosticsFile(context);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.appendFileSync(file, JSON.stringify(payload) + '\n', 'utf8');
  } catch (error) {
    log('Could not write diagnostics: ' + error.message);
  }
}

function emptySnapshots() {
  return { version: 1, folders: {} };
}

function readSnapshotFile(context) {
  try {
    const filePath = snapshotUri(context).fsPath;
    if (!fs.existsSync(filePath)) {
      return null;
    }
    const parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    if (parsed && parsed.folders && typeof parsed.folders === 'object') {
      return parsed;
    }
  } catch (error) {
    log('Could not read snapshot file: ' + error.message);
  }
  return null;
}

function writeSnapshotFile(context, data) {
  try {
    const filePath = snapshotUri(context).fsPath;
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8');
  } catch (error) {
    log('Could not write snapshot file: ' + error.message);
  }
}

function loadSnapshots(context) {
  const fromFile = readSnapshotFile(context);
  if (fromFile) {
    return fromFile;
  }
  const fromMemento = context.workspaceState.get(MEMENTO_KEY);
  if (fromMemento && fromMemento.folders) {
    return fromMemento;
  }
  return emptySnapshots();
}

function saveSnapshots(context, data) {
  writeSnapshotFile(context, data);
  try {
    const update = context.workspaceState.update(MEMENTO_KEY, data);
    if (update && typeof update.catch === 'function') {
      update.catch(error => log('Could not update workspace state: ' + error.message));
    }
  } catch (error) {
    log('Could not update workspace state: ' + error.message);
  }
}

function mergeSessionLists(existingSessions, activeSessions) {
  const merged = new Map();
  for (const session of existingSessions || []) {
    if (session && session.sessionId) {
      merged.set(session.sessionId, session);
    }
  }
  for (const session of activeSessions || []) {
    if (session && session.sessionId) {
      merged.set(session.sessionId, session);
    }
  }
  return Array.from(merged.values());
}

function updateSnapshotForFolder(context, folder, sessions, clearWhenEmpty, merge) {
  const data = loadSnapshots(context);
  const key = folderKey(folder);
  let nextSessions = sessions || [];
  if (merge) {
    const existing =
      (data.folders[key] && Array.isArray(data.folders[key].sessions)
        ? data.folders[key].sessions
        : []);
    nextSessions = mergeSessionLists(existing, nextSessions);
  } else if (nextSessions.length === 0 && !clearWhenEmpty) {
    return data;
  }
  data.folders[key] = {
    savedAt: new Date().toISOString(),
    sessions: core.buildSnapshot(nextSessions, getConfig().get('maxSessions'))
  };
  saveSnapshots(context, data);
  return data;
}

function querySessionsAsync(folder, claudeCommand) {
  return new Promise(resolve => {
    let executable;
    try {
      executable = core.findClaudeExecutable(claudeCommand);
    } catch (error) {
      resolve({ ok: false, error: error.message });
      return;
    }
    if (process.platform === 'win32' && (!path.isAbsolute(executable) || !/\.exe$/i.test(executable))) {
      resolve({
        ok: false,
        error: 'Claude Code CLI not found. Set claudeSessionRestore.claudeCommand to claude.exe.'
      });
      return;
    }
    execFile(
      executable,
      ['agents', '--json'],
      { cwd: folder.uri.fsPath, encoding: 'utf8', timeout: 8000, windowsHide: true },
      (error, stdout) => {
        if (error) {
          resolve({ ok: false, error: error.message });
          return;
        }
        try {
          resolve({ ok: true, sessions: core.parseAgentsJson(stdout) });
        } catch (parseError) {
          resolve({ ok: false, error: 'Could not parse claude agents output: ' + parseError.message });
        }
      }
    );
  });
}

async function snapshotAll(context, notify) {
  if (snapshotRunning) {
    return false;
  }
  snapshotRunning = true;
  const startedAt = Date.now();
  try {
    const config = getConfig();
    if (!config.get('enabled')) {
      return false;
    }
    recordDiagnostic(context, 'snapshot.start', { trigger: notify ? 'manual' : 'timer' });
    const folders = vscode.workspace.workspaceFolders || [];
    for (const folder of folders) {
      const queryStartedAt = Date.now();
      const result = await querySessionsAsync(folder, config.get('claudeCommand'));
      const queryMs = Date.now() - queryStartedAt;
      if (!result.ok) {
        log('Snapshot skipped for ' + folder.name + ': ' + result.error);
        recordDiagnostic(context, 'snapshot.folder', {
          folder: folder.name,
          queryMs,
          ok: false,
          error: result.error
        });
        continue;
      }
      const sessions = core.sessionsForFolder(result.sessions, folder.uri.fsPath);
      const inGracePeriod = Date.now() - lastRestoreAt < 60000;
      updateSnapshotForFolder(
        context,
        folder,
        sessions,
        config.get('clearSnapshotWhenNoSessions'),
        inGracePeriod
      );
      log(
        (inGracePeriod ? 'Merged snapshot' : 'Snapshotted') +
          ' with ' +
          sessions.length +
          ' active session(s) for ' +
          folder.name +
          (inGracePeriod ? ' (restore grace).' : '.')
      );
      recordDiagnostic(context, 'snapshot.folder', {
        folder: folder.name,
        queryMs,
        ok: true,
        sessions: sessions.length,
        merged: inGracePeriod
      });
    }
    if (notify) {
      vscode.window.showInformationMessage('Claude session snapshot updated.');
    }
    return true;
  } finally {
    recordDiagnostic(context, 'snapshot.done', {
      durationMs: Date.now() - startedAt,
      manual: Boolean(notify)
    });
    snapshotRunning = false;
  }
}

function snapshotAllSync(context) {
  const now = Date.now();
  if (now - lastSyncSnapshotAt < 2000) {
    return;
  }
  lastSyncSnapshotAt = now;
  const config = getConfig();
  if (!config.get('enabled')) {
    return;
  }
  const folders = vscode.workspace.workspaceFolders || [];
  for (const folder of folders) {
    const startedAt = Date.now();
    try {
      const sessions = core.querySessionsSync(folder.uri.fsPath, config.get('claudeCommand'), 3000);
      const filtered = core.sessionsForFolder(sessions, folder.uri.fsPath);
      // Do not clear on shutdown: the terminal processes may already be gone by
      // the time deactivate runs. The periodic snapshot is responsible for
      // clearing when the user really has no active sessions.
      const inGracePeriod = Date.now() - lastRestoreAt < 60000;
      updateSnapshotForFolder(context, folder, filtered, false, inGracePeriod);
      log('Deactivate snapshot: ' + filtered.length + ' session(s) for ' + folder.name + '.');
      recordDiagnostic(context, 'snapshot.sync', {
        folder: folder.name,
        durationMs: Date.now() - startedAt,
        sessions: filtered.length,
        merged: inGracePeriod
      });
    } catch (error) {
      log('Deactivate snapshot failed for ' + folder.name + ': ' + error.message);
      recordDiagnostic(context, 'snapshot.sync', {
        folder: folder.name,
        durationMs: Date.now() - startedAt,
        error: error.message
      });
    }
  }
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function restoreNow(context, manual) {
  if (restoreRunning) {
    return;
  }
  restoreRunning = true;
  try {
    const config = getConfig();
    if (!config.get('enabled')) {
      log('Extension is disabled.');
      return;
    }
    if (!manual && !config.get('autoRestore')) {
      log('autoRestore is disabled.');
      return;
    }
    if (!vscode.workspace.isTrusted && !config.get('allowUntrustedWorkspaces')) {
      log('Workspace is untrusted; automatic restore was skipped.');
      return;
    }
    const folder = firstWorkspaceFolder();
    if (!folder) {
      log('No workspace folder; nothing to restore.');
      return;
    }
    const data = loadSnapshots(context);
    const entry = data.folders[folderKey(folder)];
    if (!entry || !Array.isArray(entry.sessions) || entry.sessions.length === 0) {
      log('No snapshot for ' + folder.name + '.');
      return;
    }

    const restoreStartedAt = Date.now();
    const launchMode = config.get('launchMode') || 'shell';
    const staggerMs = Math.max(0, Number(config.get('staggerMs')) || 0);
    recordDiagnostic(context, 'restore.start', {
      manual,
      launchMode,
      staggerMs,
      maxSessions: config.get('maxSessions'),
      snapshotSessions: entry.sessions.length
    });

    const activeStartedAt = Date.now();
    const activeResult = await querySessionsAsync(folder, config.get('claudeCommand'));
    const activeMs = Date.now() - activeStartedAt;
    const activeIds = new Set();
    if (activeResult.ok) {
      for (const session of core.sessionsForFolder(activeResult.sessions, folder.uri.fsPath)) {
        activeIds.add(session.sessionId);
      }
    } else {
      log('Could not query active sessions; restoring the snapshot anyway: ' + activeResult.error);
    }
    recordDiagnostic(context, 'restore.activeQuery', {
      durationMs: activeMs,
      ok: activeResult.ok,
      activeCount: activeIds.size,
      error: activeResult.error || null
    });

    const maxSessions = config.get('maxSessions');
    const extraArgs = (config.get('extraArgs') || []).map(String);
    const claudeCommand = config.get('claudeCommand') || 'claude';
    const reveal = config.get('revealTerminals');
    let directExecutable = null;
    if (launchMode === 'direct') {
      const candidate = core.findClaudeExecutable(claudeCommand);
      if (path.isAbsolute(candidate) && /\.exe$/i.test(candidate)) {
        directExecutable = candidate;
      } else {
        log('launchMode=direct requested but no native claude.exe was resolved; using shell mode.');
      }
    }
    recordDiagnostic(context, 'restore.launchMode', {
      requested: launchMode,
      effective: directExecutable ? 'direct' : 'shell',
      executable: directExecutable ? path.basename(directExecutable) : null
    });
    let created = 0;

    for (const session of entry.sessions.slice(0, maxSessions)) {
      if (!core.isUuid(session.sessionId)) {
        continue;
      }
      const terminalStartedAt = Date.now();
      const terminalName = core.terminalName(session);
      const existingTerminals = vscode.window.terminals.filter(
        terminal => terminal.name === terminalName
      );

      if (activeIds.has(session.sessionId)) {
        if (existingTerminals.length > 1) {
          // A window reload can leave old terminal tabs behind while the
          // session itself is still active in the newest terminal.
          for (let index = 0; index < existingTerminals.length - 1; index += 1) {
            try {
              existingTerminals[index].dispose();
            } catch (_) {
              // Ignore a terminal that is already gone.
            }
          }
          log(
            'Disposed ' +
              (existingTerminals.length - 1) +
              ' duplicate terminal(s) for active session ' +
              core.shortId(session.sessionId) +
              '.'
          );
          recordDiagnostic(context, 'restore.dedup', {
            id: core.shortId(session.sessionId),
            disposed: existingTerminals.length - 1,
            active: true
          });
        }
        log('Skipped active session ' + core.shortId(session.sessionId) + '.');
        recordDiagnostic(context, 'restore.skipActive', {
          id: core.shortId(session.sessionId)
        });
        continue;
      }

      for (const terminal of existingTerminals) {
        try {
          terminal.dispose();
        } catch (_) {
          // Ignore a terminal that is already gone.
        }
      }
      if (existingTerminals.length > 0) {
        log(
          'Disposed ' +
            existingTerminals.length +
            ' stale terminal(s) for session ' +
            core.shortId(session.sessionId) +
            '.'
        );
        recordDiagnostic(context, 'restore.disposeStale', {
          id: core.shortId(session.sessionId),
          disposed: existingTerminals.length
        });
      }

      let command = null;
      if (!directExecutable) {
        try {
          command = core.buildResumeCommand(claudeCommand, session.sessionId, extraArgs);
        } catch (error) {
          log('Invalid snapshot entry skipped: ' + error.message);
          continue;
        }
      }

      let terminal;
      if (directExecutable) {
        terminal = vscode.window.createTerminal({
          name: terminalName,
          cwd: folder.uri,
          shellPath: directExecutable,
          shellArgs: ['--resume', session.sessionId].concat(extraArgs)
        });
      } else {
        terminal = vscode.window.createTerminal({
          name: terminalName,
          cwd: folder.uri
        });
        terminal.sendText(command, true);
      }
      if (created === 0 && reveal) {
        terminal.show(true);
      }
      created += 1;
      recordDiagnostic(context, 'restore.terminal', {
        id: core.shortId(session.sessionId),
        name: terminalName,
        mode: directExecutable ? 'direct' : 'shell',
        operationMs: Date.now() - terminalStartedAt,
        elapsedMs: Date.now() - restoreStartedAt,
        index: created
      });
      if (staggerMs > 0) {
        await delay(staggerMs);
      }
    }

    if (created > 0) {
      lastRestoreAt = Date.now();
    }
    log('Restore created ' + created + ' terminal(s) for ' + folder.name + '.');
    recordDiagnostic(context, 'restore.done', {
      created,
      durationMs: Date.now() - restoreStartedAt,
      mode: directExecutable ? 'direct' : 'shell'
    });
    if (manual) {
      vscode.window.showInformationMessage(
        'Claude session restore: created ' + created + ' terminal(s).'
      );
    }
    return created;
  } finally {
    restoreRunning = false;
  }
}

function startSnapshotTimer(context) {
  if (timer) {
    clearInterval(timer);
    timer = undefined;
  }
  const seconds = Number(getConfig().get('snapshotIntervalSeconds'));
  if (!Number.isFinite(seconds) || seconds <= 0) {
    return;
  }
  timer = setInterval(() => {
    snapshotAll(context, false).catch(error => log('Periodic snapshot failed: ' + error.message));
  }, seconds * 1000);
}

function activate(context) {
  const activateStartedAt = Date.now();
  extensionContext = context;
  output = vscode.window.createOutputChannel('Claude Session Restore');
  context.subscriptions.push(output);
  recordDiagnostic(context, 'activate.start', {});

  context.subscriptions.push(
    vscode.commands.registerCommand('claudeSessionRestore.snapshotNow', async () => {
      await snapshotAll(context, true);
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('claudeSessionRestore.restoreNow', async () => {
      await restoreNow(context, true);
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('claudeSessionRestore.clearSnapshot', async () => {
      const folder = firstWorkspaceFolder();
      if (!folder) {
        vscode.window.showInformationMessage('Claude session restore: no workspace folder.');
        return;
      }
      const data = loadSnapshots(context);
      delete data.folders[folderKey(folder)];
      saveSnapshots(context, data);
      vscode.window.showInformationMessage('Claude session snapshot cleared for this workspace.');
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration(event => {
      if (event.affectsConfiguration(CONFIG_SECTION)) {
        startSnapshotTimer(context);
      }
    })
  );

  if (typeof vscode.workspace.onWillSaveState === 'function') {
    context.subscriptions.push(
      vscode.workspace.onWillSaveState(() => {
        snapshotAllSync(context);
      })
    );
  }

  const config = getConfig();
  const folder = firstWorkspaceFolder();
  const restoreDelayMs = Math.max(0, Number(config.get('restoreDelayMs')) || 0);
  log('Activated (v0.1.0); workspace=' + (folder ? folder.name : 'none') + '.');
  recordDiagnostic(context, 'activate.ready', {
    workspace: folder ? folder.name : null,
    activationMs: Date.now() - activateStartedAt,
    restoreDelayMs,
    launchMode: config.get('launchMode') || 'shell',
    staggerMs: Number(config.get('staggerMs')) || 0
  });
  if (!config.get('enabled')) {
    log('Extension is disabled.');
    return;
  }

  startSnapshotTimer(context);
  setTimeout(() => {
    restoreNow(context, false)
      .catch(error => log('Automatic restore failed: ' + error.message))
      .then(created => {
        if (created > 0) {
          // Restored Claude processes are still starting. The periodic snapshot
          // will merge them once they register; avoid competing with startup.
          return undefined;
        }
        return snapshotAll(context, false);
      })
      .catch(error => log('Initial snapshot failed: ' + error.message));
  }, restoreDelayMs);
}

function deactivate() {
  if (timer) {
    clearInterval(timer);
    timer = undefined;
  }
  if (extensionContext) {
    try {
      snapshotAllSync(extensionContext);
    } catch (error) {
      log('Deactivate snapshot failed: ' + error.message);
    }
  }
}

module.exports = {
  activate,
  deactivate
};
