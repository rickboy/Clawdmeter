import noble from '@stoprocent/noble';
import { readFile, writeFile, mkdir, unlink } from 'fs/promises';
import { existsSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

const DEVICE_NAME   = 'Claude Controller';
const SERVICE_UUID  = '4c41555a446576696365000000000001';
const RX_CHAR_UUID  = '4c41555a446576696365000000000002';
const REQ_CHAR_UUID = '4c41555a446576696365000000000004';
const POLL_INTERVAL = 60_000;
const TICK          = 5_000;
const SCAN_TIMEOUT  = 10_000;

const CONFIG_DIR    = join(homedir(), '.config', 'claude-usage-monitor');
const ID_FILE       = join(CONFIG_DIR, 'ble-id');
const CREDS_FILE    = join(homedir(), '.claude', '.credentials.json');

function log(msg) {
  const t = new Date().toTimeString().slice(0, 8);
  console.log(`[${t}] ${msg}`);
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

async function readToken() {
  const raw = await readFile(CREDS_FILE, 'utf8');
  const m = raw.match(/"accessToken":"([^"]+)"/);
  if (!m) throw new Error('accessToken not found in credentials');
  return m[1];
}

async function loadId() {
  if (!existsSync(ID_FILE)) return null;
  const id = (await readFile(ID_FILE, 'utf8')).trim();
  return id || null;
}

async function saveId(id) {
  await mkdir(CONFIG_DIR, { recursive: true });
  await writeFile(ID_FILE, id, 'utf8');
}

async function clearId() {
  try { await unlink(ID_FILE); } catch {}
}

function waitForPoweredOn(timeoutMs = 15_000) {
  return new Promise((resolve, reject) => {
    if (noble.state === 'poweredOn') return resolve();
    const timer = setTimeout(
      () => reject(new Error(`BLE not ready (state: ${noble.state})`)),
      timeoutMs,
    );
    function onState(state) {
      if (state === 'poweredOn') {
        clearTimeout(timer);
        noble.removeListener('stateChange', onState);
        resolve();
      } else if (state === 'poweredOff' || state === 'unauthorized') {
        clearTimeout(timer);
        noble.removeListener('stateChange', onState);
        reject(new Error(`BLE state: ${state}`));
      }
    }
    noble.on('stateChange', onState);
  });
}

function scanFor(matchFn) {
  return new Promise((resolve) => {
    function onDiscover(peripheral) {
      if (matchFn(peripheral)) {
        clearTimeout(timer);
        noble.removeListener('discover', onDiscover);
        noble.stopScanning();
        resolve(peripheral);
      }
    }
    const timer = setTimeout(() => {
      noble.removeListener('discover', onDiscover);
      noble.stopScanning();
      resolve(null);
    }, SCAN_TIMEOUT);
    noble.on('discover', onDiscover);
    noble.startScanning([], false);
  });
}

async function findDevice(savedId) {
  await waitForPoweredOn();
  if (savedId) {
    log(`Scanning to reconnect (${savedId})...`);
    const p = await scanFor(d => d.id === savedId);
    if (p) return p;
    log('Saved ID not found, rescanning by name...');
    await clearId();
  }
  log(`Scanning for '${DEVICE_NAME}'...`);
  return scanFor(d => d.advertisement.localName === DEVICE_NAME);
}

async function poll(rxChar) {
  let token;
  try {
    token = await readToken();
  } catch (e) {
    log(`Token read error: ${e.message}`);
    return false;
  }

  const now = Math.floor(Date.now() / 1000);
  let res;
  try {
    res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        Authorization:        `Bearer ${token}`,
        'anthropic-version':  '2023-06-01',
        'anthropic-beta':     'oauth-2025-04-20',
        'Content-Type':       'application/json',
        'User-Agent':         'claude-code/2.1.5',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1,
        messages: [{ role: 'user', content: 'hi' }],
      }),
    });
  } catch (e) {
    log(`API call failed: ${e.message}`);
    return false;
  }

  const h = res.headers;
  const s5hUtil  = parseFloat(h.get('anthropic-ratelimit-unified-5h-utilization'))  || 0;
  const s5hReset = parseInt(h.get('anthropic-ratelimit-unified-5h-reset'))           || 0;
  const s7dUtil  = parseFloat(h.get('anthropic-ratelimit-unified-7d-utilization'))  || 0;
  const s7dReset = parseInt(h.get('anthropic-ratelimit-unified-7d-reset'))           || 0;
  const status   = h.get('anthropic-ratelimit-unified-5h-status')                   || 'unknown';

  const payload = JSON.stringify({
    s:  Math.round(s5hUtil * 100),
    sr: Math.max(0, Math.round((s5hReset - now) / 60)),
    w:  Math.round(s7dUtil * 100),
    wr: Math.max(0, Math.round((s7dReset - now) / 60)),
    st: status,
    ok: true,
  });

  log(`Sending: ${payload}`);
  try {
    await rxChar.writeAsync(Buffer.from(payload, 'utf8'), false);
    return true;
  } catch (e) {
    log(`Write failed: ${e.message}`);
    return false;
  }
}

async function run() {
  log('=== Claude Usage Tracker Daemon (BLE/Node) ===');
  log(`Poll interval: ${POLL_INTERVAL / 1000}s`);

  let backoff = 1_000;

  while (true) {
    // Find peripheral
    const savedId = await loadId();
    const peripheral = await findDevice(savedId);

    if (!peripheral) {
      log(`Device not found, retrying in ${backoff / 1000}s...`);
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 60_000);
      continue;
    }

    log(`Found: ${peripheral.advertisement.localName} (${peripheral.id})`);
    await saveId(peripheral.id);

    // Connect
    try {
      await peripheral.connectAsync();
    } catch (e) {
      log(`Connect failed: ${e.message}`);
      await clearId();
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 60_000);
      continue;
    }

    log('Connected');
    backoff = 1_000;

    // Discover GATT service + characteristics
    let rxChar, reqChar;
    try {
      const services = await peripheral.discoverServicesAsync([SERVICE_UUID]);
      if (!services.length) throw new Error('Service not found');
      const chars = await services[0].discoverCharacteristicsAsync([RX_CHAR_UUID, REQ_CHAR_UUID]);
      rxChar  = chars.find(c => c.uuid === RX_CHAR_UUID);
      reqChar = chars.find(c => c.uuid === REQ_CHAR_UUID);
      if (!rxChar) throw new Error('RX characteristic not found');
    } catch (e) {
      log(`GATT discovery failed: ${e.message}`);
      try { peripheral.disconnect(); } catch {}
      await sleep(5_000);
      continue;
    }

    // Subscribe to refresh-request notifications (ESP fires 0x01 on boot)
    let refreshRequested = false;
    if (reqChar) {
      try {
        await reqChar.subscribeAsync();
        reqChar.on('data', () => { refreshRequested = true; });
        log('Subscribed to refresh notifications');
      } catch (e) {
        log(`REQ subscribe failed (non-fatal): ${e.message}`);
      }
    }

    // Poll loop
    let connected = true;
    peripheral.once('disconnect', () => { connected = false; });

    let lastPoll = 0;
    if (await poll(rxChar)) lastPoll = Date.now();

    while (connected) {
      await sleep(TICK);
      if (!connected) break;
      const now = Date.now();
      if (refreshRequested || now - lastPoll >= POLL_INTERVAL) {
        if (refreshRequested) {
          log('Refresh requested by device');
          refreshRequested = false;
        }
        if (await poll(rxChar)) lastPoll = now;
      }
    }

    log('Disconnected, reconnecting...');
    await sleep(2_000);
  }
}

process.on('SIGINT',  () => { log('Stopping...'); process.exit(0); });
process.on('SIGTERM', () => { log('Stopping...'); process.exit(0); });

run().catch(e => { console.error(e); process.exit(1); });
