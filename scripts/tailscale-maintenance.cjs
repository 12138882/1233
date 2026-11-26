const fs = require('node:fs');

const HOST_OS = {
  linux: ['linux'],
  windows: ['windows'],
  macos: ['darwin', 'macos'],
  'remote-linux-1233': ['linux'],
  'remote-windows-1233': ['windows'],
  'remote-macos-1233': ['darwin', 'macos'],
};
const canonicalName = d => ({ linux: 'linux', windows: 'windows', darwin: 'macos', macos: 'macos' })[String(d.os).toLowerCase()];
const EXIT_ROUTES = ['0.0.0.0/0', '::/0'];
const idOf = d => String(d.nodeId || d.id || '');
const timestamp = s => typeof s === 'string' && s ? Date.parse(s) : NaN;

function isManaged(d, suffix) {
  if (!d || !Object.hasOwn(HOST_OS, d.hostname) || d.isExternal !== false) return false;
  if (!HOST_OS[d.hostname].includes(String(d.os).toLowerCase())) return false;
  const name = String(d.name || '').toLowerCase().replace(/\.$/, '');
  const aliases = [d.hostname, canonicalName(d)];
  if (!aliases.some(host => name === `${host}.${suffix}` || new RegExp(`^${host}-[0-9]+\\.${suffix.replaceAll('.', '\\.')}$`).test(name))) return false;
  return !!idOf(d) && Number.isFinite(timestamp(d.created));
}

function deletionPlan(devices, { suffix, now = Date.now(), graceMinutes = 15 }) {
  const managed = devices.filter(d => isManaged(d, suffix));
  return managed.filter(d => {
    if (d.connectedToControl !== false) return false;
    const lastSeen = timestamp(d.lastSeen);
    if (!Number.isFinite(lastSeen) || now - lastSeen < graceMinutes * 60000) return false;
    return managed.some(n => canonicalName(n) === canonicalName(d) && n.connectedToControl === true &&
      idOf(n) !== idOf(d) && timestamp(n.created) > timestamp(d.created));
  });
}

async function maintain({ token, suffix = 'tail6f1974.ts.net', apply = false, fetchImpl = fetch, now = () => Date.now(), graceMinutes = 15, report = console.log }) {
  suffix = suffix.toLowerCase().replace(/\.$/, '');
  if (!/^[a-z0-9-]+\.ts\.net$/.test(suffix)) throw Error('Expected a specific ts.net tailnet DNS suffix');
  if (!/^tskey-api-[A-Za-z0-9_-]+$/.test(token || '')) throw Error('A Tailscale API access token is required');
  const headers = { Authorization: 'Basic ' + Buffer.from(token + ':').toString('base64'), 'Content-Type': 'application/json' };
  async function api(route, method = 'GET', body) {
    const r = await fetchImpl('https://api.tailscale.com/api/v2' + route, {
      method, headers, redirect: 'error', signal: AbortSignal.timeout(30000),
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (r.status === 404 && method === 'GET') return null;
    if (!r.ok) throw Error(`Tailscale ${method} ${route}: HTTP ${r.status}`);
    const text = await r.text();
    return text ? JSON.parse(text) : null;
  }
  const list = async () => {
    const result = await api('/tailnet/-/devices?fields=all');
    if (!Array.isArray(result?.devices)) throw Error('Device list is missing; no maintenance performed');
    return result.devices;
  };
  const summary = { apply, configured: [], deleted: [], candidates: [], skipped: [] };
  let devices = await list();
  for (const device of devices.filter(d => isManaged(d, suffix) && d.connectedToControl === true)) {
    const id = encodeURIComponent(idOf(device));
    const current = await api(`/device/${id}?fields=all`);
    if (!isManaged(current, suffix) || current.connectedToControl !== true) continue;
    const routes = await api(`/device/${id}/routes`);
    if (!Array.isArray(routes?.advertisedRoutes) || !Array.isArray(routes?.enabledRoutes)) throw Error('Route state is missing; no route changes performed');
    const linux = canonicalName(current) === 'linux';
    const required = linux ? EXIT_ROUTES.filter(r => routes.advertisedRoutes.includes(r)) : [];
    const enabled = [...new Set([...routes.enabledRoutes.filter(r => linux || !EXIT_ROUTES.includes(r)), ...required])];
    const renamed = canonicalName(current);
    if (apply) {
      if (required.some(r => !routes.enabledRoutes.includes(r)) || (!linux && routes.enabledRoutes.some(r => EXIT_ROUTES.includes(r)))) await api(`/device/${id}/routes`, 'POST', { routes: enabled });
      if (current.keyExpiryDisabled !== true) await api(`/device/${id}/key`, 'POST', { keyExpiryDisabled: true });
      const [verified, verifiedRoutes] = await Promise.all([api(`/device/${id}?fields=all`), api(`/device/${id}/routes`)]);
      if (verified?.keyExpiryDisabled !== true || required.some(r => !verifiedRoutes?.enabledRoutes?.includes(r)) || (!linux && verifiedRoutes?.enabledRoutes?.some(r => EXIT_ROUTES.includes(r)))) throw Error('Device maintenance read-back failed');
    }
    summary.configured.push({ name: renamed, addresses: current.addresses, exitRoutes: required, keyExpiryDisabled: apply ? true : current.keyExpiryDisabled });
  }
  devices = await list();
  const candidates = deletionPlan(devices, { suffix, now: now(), graceMinutes });
  if (candidates.length > 50) throw Error('More than 50 deletion candidates; stopped for review');
  for (const candidate of candidates) {
    const id = encodeURIComponent(idOf(candidate));
    const latest = await list();
    const current = latest.find(d => idOf(d) === idOf(candidate));
    if (!current || !deletionPlan(latest, { suffix, now: now(), graceMinutes }).some(d => idOf(d) === idOf(current))) {
      summary.skipped.push({ name: candidate.name, reason: 'Device or replacement state changed' });
      continue;
    }
    const fresh = await api(`/device/${id}?fields=all`);
    if (!fresh || !deletionPlan([...latest.filter(d => idOf(d) !== idOf(fresh)), fresh], { suffix, now: now(), graceMinutes }).some(d => idOf(d) === idOf(fresh))) {
      summary.skipped.push({ name: candidate.name, reason: 'Device is no longer safely stale' });
      continue;
    }
    const record = { id: idOf(fresh), name: fresh.name, addresses: fresh.addresses, lastSeen: fresh.lastSeen };
    summary.candidates.push(record);
    if (apply) {
      await api(`/device/${id}`, 'DELETE');
      if (await api(`/device/${id}?fields=all`)) throw Error('Deleted device is still present');
      summary.deleted.push(record);
    }
  }
  if (apply) {
    const latest = await list();
    for (const d of latest.filter(d => isManaged(d, suffix) && d.connectedToControl === true)) {
      const target = canonicalName(d);
      const currentName = String(d.name).replace(/\.$/, '').toLowerCase();
      const targetName = `${target}.${suffix}`;
      const owner = latest.find(n => idOf(n) !== idOf(d) && String(n.name).replace(/\.$/, '').toLowerCase() === targetName);
      if (currentName !== targetName && owner && isManaged(owner, suffix) && owner.connectedToControl === false && timestamp(owner.created) < timestamp(d.created)) {
        const old = await api(`/device/${encodeURIComponent(idOf(owner))}?fields=all`);
        if (old && isManaged(old, suffix) && old.connectedToControl === false && timestamp(old.created) < timestamp(d.created)) {
          const retiredName = `${target}-${timestamp(old.created)}`;
          await api(`/device/${encodeURIComponent(idOf(old))}/name`, 'POST', { name: retiredName });
          const retired = await api(`/device/${encodeURIComponent(idOf(old))}?fields=all`);
          if (String(retired?.name).replace(/\.$/, '').toLowerCase() !== `${retiredName}.${suffix}`) throw Error('Old device name read-back failed');
          owner.name = retired.name;
        }
      }
      if (currentName !== targetName && !latest.some(n => idOf(n) !== idOf(d) && String(n.name).replace(/\.$/, '').toLowerCase() === targetName)) {
        await api(`/device/${encodeURIComponent(idOf(d))}/name`, 'POST', { name: target });
        const renamed = await api(`/device/${encodeURIComponent(idOf(d))}?fields=all`);
        if (String(renamed?.name).replace(/\.$/, '').toLowerCase() !== targetName) throw Error('Device name read-back failed');
      }
    }
  }
  summary.remaining = (await list()).filter(d => isManaged(d, suffix)).map(d => ({ name: d.name, addresses: d.addresses, online: d.connectedToControl, keyExpiryDisabled: d.keyExpiryDisabled }));
  report(JSON.stringify(summary, null, 2));
  return summary;
}

module.exports = { isManaged, deletionPlan, maintain };
if (require.main === module) {
  maintain({ token: process.env.TAILSCALE_API_KEY, suffix: process.env.TAILSCALE_DNS_SUFFIX,
    apply: process.argv.includes('--apply') }).then(result => {
    if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `### Tailscale maintenance\n\nConfigured ${result.configured.length} online remote devices; removed ${result.deleted.length} stale devices.\n`);
  }).catch(e => { console.error(e.message); process.exitCode = 1; });
}
