// Playground session gateway.
//
// ALB (authenticate-cognito) terminates the Cognito login and forwards
// every request here with a signed identity JWT in the x-amzn-oidc-data
// header. This process:
//   - verifies that JWT against the ALB's own public key (never trusts the
//     plaintext x-amzn-oidc-identity header alone — see verifyOidcJwt)
//   - launches a dedicated Fargate task for that user on first request
//   - proxies all HTTP/WebSocket traffic to that user's ttyd container
//   - stops the task automatically after SESSION_MAX_MINUTES or at the end
//     of the daily access window, whichever comes first
//
// Local/offline mode: if ECS_CLUSTER is not set, falls back to the static
// USERS_JSON/users.json routing used by docker-compose (no Cognito, no
// dynamic launch) — this keeps `docker compose up` working unmodified.
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const httpProxy = require('http-proxy');
const { ECSClient, RunTaskCommand, DescribeTasksCommand, StopTaskCommand } = require('@aws-sdk/client-ecs');
const { EC2Client, DescribeNetworkInterfacesCommand } = require('@aws-sdk/client-ec2');

const PORT = process.env.PORT || 8080;
const REGION = process.env.AWS_REGION || 'ap-northeast-1';

const ECS_CLUSTER = process.env.ECS_CLUSTER || null;
const TASK_DEFINITION = process.env.TASK_DEFINITION || null;
const CONTAINER_NAME = process.env.CONTAINER_NAME || 'claude-user';
const SUBNET_IDS = (process.env.SUBNET_IDS || '').split(',').filter(Boolean);
const CONTAINER_SECURITY_GROUPS = (process.env.CONTAINER_SECURITY_GROUPS || '').split(',').filter(Boolean);
const DYNAMIC_MODE = Boolean(ECS_CLUSTER);

const SESSION_MAX_MINUTES = Number(process.env.SESSION_MAX_MINUTES || 45);
const [WINDOW_START_H, WINDOW_START_M] = (process.env.WINDOW_START_JST || '10:00').split(':').map(Number);
const [WINDOW_END_H, WINDOW_END_M] = (process.env.WINDOW_END_JST || '11:00').split(':').map(Number);

const USERS_FILE = process.env.USERS_FILE || path.join(__dirname, 'users.json');
const USERS_JSON = process.env.USERS_JSON || null;

const ecs = DYNAMIC_MODE ? new ECSClient({ region: REGION }) : null;
const ec2 = DYNAMIC_MODE ? new EC2Client({ region: REGION }) : null;

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

function jstParts(nowMs) {
  const d = new Date(nowMs + JST_OFFSET_MS);
  return { y: d.getUTCFullYear(), mo: d.getUTCMonth(), da: d.getUTCDate() };
}

function windowBoundsUtcMs(nowMs) {
  const { y, mo, da } = jstParts(nowMs);
  const startUtc = Date.UTC(y, mo, da, WINDOW_START_H, WINDOW_START_M) - JST_OFFSET_MS;
  const endUtc = Date.UTC(y, mo, da, WINDOW_END_H, WINDOW_END_M) - JST_OFFSET_MS;
  return { startUtc, endUtc };
}

function isWithinLaunchWindow(nowMs) {
  const { startUtc, endUtc } = windowBoundsUtcMs(nowMs);
  return nowMs >= startUtc && nowMs < endUtc;
}

function sessionExpiryUtcMs(nowMs) {
  const { endUtc } = windowBoundsUtcMs(nowMs);
  return Math.min(nowMs + SESSION_MAX_MINUTES * 60 * 1000, endUtc);
}

// --- ALB-signed identity verification -------------------------------------
// ALB signs x-amzn-oidc-data with ES256 over its own key, rotated by kid.
// We fetch+cache the public key per kid rather than trusting the separate
// plaintext x-amzn-oidc-identity header, per AWS's documented verification
// requirement for this header.
const jwkCache = new Map();

function base64UrlDecode(str) {
  return Buffer.from(str.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

async function fetchAlbPublicKeyPem(kid) {
  if (jwkCache.has(kid)) return jwkCache.get(kid);
  const res = await fetch(`https://public-keys.auth.elb.${REGION}.amazonaws.com/${kid}`);
  if (!res.ok) throw new Error(`failed to fetch ALB public key for kid=${kid}: ${res.status}`);
  const pem = await res.text();
  jwkCache.set(kid, pem);
  return pem;
}

async function verifyOidcJwt(token) {
  const [headerB64, payloadB64, sigB64] = token.split('.');
  if (!headerB64 || !payloadB64 || !sigB64) throw new Error('malformed JWT');

  const header = JSON.parse(base64UrlDecode(headerB64).toString('utf8'));
  const payload = JSON.parse(base64UrlDecode(payloadB64).toString('utf8'));

  if (header.alg !== 'ES256') throw new Error(`unexpected alg: ${header.alg}`);
  if (payload.exp && Date.now() / 1000 > payload.exp) throw new Error('token expired');

  const pem = await fetchAlbPublicKeyPem(header.kid);
  const publicKey = crypto.createPublicKey(pem);
  const verified = crypto.verify(
    'sha256',
    Buffer.from(`${headerB64}.${payloadB64}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    base64UrlDecode(sigB64),
  );
  if (!verified) throw new Error('signature verification failed');

  return payload; // contains sub, email (scope=openid email), exp, etc.
}

async function resolveIdentity(req) {
  const oidcData = req.headers['x-amzn-oidc-data'];
  if (!oidcData) return { error: 401, message: 'missing ALB identity header — access this gateway only through the ALB' };
  try {
    const claims = await verifyOidcJwt(oidcData);
    return { sub: claims.sub, email: claims.email || claims.sub };
  } catch (err) {
    return { error: 401, message: `identity verification failed: ${err.message}` };
  }
}

// --- Dynamic per-user Fargate task lifecycle -------------------------------
// sub -> { status: 'launching'|'running', ip, taskArn, expiresAt, launchPromise, stopTimer }
const sessions = new Map();

function sanitizeForEnv(email) {
  return String(email).slice(0, 200);
}

async function waitForTaskRunning(taskArn, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const { tasks } = await ecs.send(new DescribeTasksCommand({ cluster: ECS_CLUSTER, tasks: [taskArn] }));
    const task = tasks && tasks[0];
    if (!task) throw new Error('task disappeared while starting');
    if (task.lastStatus === 'STOPPED') {
      throw new Error(`task stopped before becoming ready: ${task.stoppedReason || 'unknown reason'}`);
    }
    if (task.lastStatus === 'RUNNING') {
      const eni = task.attachments?.[0]?.details?.find((d) => d.name === 'networkInterfaceId')?.value;
      if (eni) return eni;
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error('timed out waiting for task to start');
}

async function resolvePrivateIp(eni) {
  const { NetworkInterfaces } = await ec2.send(new DescribeNetworkInterfacesCommand({ NetworkInterfaceIds: [eni] }));
  return NetworkInterfaces[0].PrivateIpAddress;
}

async function stopSession(sub, reason) {
  const session = sessions.get(sub);
  if (!session) return;
  sessions.delete(sub);
  clearTimeout(session.stopTimer);
  if (session.taskArn) {
    try {
      await ecs.send(new StopTaskCommand({ cluster: ECS_CLUSTER, task: session.taskArn, reason }));
    } catch (err) {
      console.error(`failed to stop task for ${sub}:`, err.message);
    }
  }
}

async function launchSession(sub, email) {
  const nowMs = Date.now();
  const { tasks } = await ecs.send(new RunTaskCommand({
    cluster: ECS_CLUSTER,
    taskDefinition: TASK_DEFINITION,
    launchType: 'FARGATE',
    startedBy: 'playground-gateway',
    networkConfiguration: {
      awsvpcConfiguration: {
        subnets: SUBNET_IDS,
        securityGroups: CONTAINER_SECURITY_GROUPS,
        assignPublicIp: 'DISABLED',
      },
    },
    overrides: {
      containerOverrides: [{ name: CONTAINER_NAME, environment: [{ name: 'PLAYGROUND_USER', value: sanitizeForEnv(email) }] }],
    },
  }));

  const failure = tasks?.length ? null : 'RunTask returned no tasks';
  if (failure) throw new Error(failure);
  const taskArn = tasks[0].taskArn;

  const eni = await waitForTaskRunning(taskArn);
  const ip = await resolvePrivateIp(eni);

  const expiresAt = sessionExpiryUtcMs(nowMs);
  const session = sessions.get(sub);
  session.status = 'running';
  session.ip = ip;
  session.taskArn = taskArn;
  session.expiresAt = expiresAt;
  session.stopTimer = setTimeout(() => stopSession(sub, 'session time limit reached'), Math.max(expiresAt - Date.now(), 0));
  return session;
}

async function getOrCreateSession(sub, email) {
  const existing = sessions.get(sub);
  if (existing) {
    if (existing.launchPromise) await existing.launchPromise;
    return sessions.get(sub);
  }

  if (!isWithinLaunchWindow(Date.now())) {
    const err = new Error(`access is only available ${String(WINDOW_START_H).padStart(2, '0')}:${String(WINDOW_START_M).padStart(2, '0')}–${String(WINDOW_END_H).padStart(2, '0')}:${String(WINDOW_END_M).padStart(2, '0')} JST`);
    err.statusCode = 403;
    throw err;
  }

  const session = { status: 'launching', launchPromise: null };
  sessions.set(sub, session);
  session.launchPromise = launchSession(sub, email)
    .catch((err) => {
      sessions.delete(sub);
      throw err;
    })
    .finally(() => {
      const s = sessions.get(sub);
      if (s) s.launchPromise = null;
    });
  await session.launchPromise;
  return sessions.get(sub);
}

// --- Static fallback (local docker-compose, no Cognito) --------------------
function loadStaticUsers() {
  if (USERS_JSON) return JSON.parse(USERS_JSON);
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function getCookie(req, name) {
  const header = req.headers.cookie || '';
  const match = header.split(';').map((c) => c.trim()).find((c) => c.startsWith(`${name}=`));
  return match ? decodeURIComponent(match.split('=')[1]) : null;
}

// --- Proxy -------------------------------------------------------------
const proxy = httpProxy.createProxyServer({ ws: true });
proxy.on('error', (err, req, res) => {
  console.error('proxy error:', err.message);
  if (res && res.writeHead) {
    res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end(`gateway: upstream container unreachable (${err.message})`);
  }
});

const STARTING_PAGE = `<!DOCTYPE html><html><head><meta http-equiv="refresh" content="3"></head>
<body style="font-family: sans-serif; padding: 2em;">
<h2>Starting your playground container…</h2>
<p>This page refreshes automatically every 3 seconds.</p>
</body></html>`;

async function resolveTarget(req) {
  if (!DYNAMIC_MODE) {
    const user = getCookie(req, 'poc_session');
    if (!user) return { error: 401, message: 'not logged in — visit /login?user=<name>' };
    const users = loadStaticUsers();
    const target = users[user];
    if (!target) return { error: 404, message: `unknown user '${user}'` };
    return { target };
  }

  const identity = await resolveIdentity(req);
  if (identity.error) return identity;

  const existing = sessions.get(identity.sub);
  if (existing && existing.status === 'running') {
    return { target: { host: existing.ip, port: 7681 } };
  }

  try {
    const session = await getOrCreateSession(identity.sub, identity.email);
    return { target: { host: session.ip, port: 7681 } };
  } catch (err) {
    return { error: err.statusCode || 502, message: err.message, starting: !err.statusCode };
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
    return;
  }

  if (!DYNAMIC_MODE && url.pathname === '/login') {
    const user = url.searchParams.get('user');
    if (!user) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('usage: /login?user=alice');
      return;
    }
    res.writeHead(302, {
      'Set-Cookie': `poc_session=${encodeURIComponent(user)}; Path=/; HttpOnly`,
      Location: '/',
    });
    res.end();
    return;
  }

  const resolved = await resolveTarget(req);
  if (resolved.error) {
    if (resolved.starting) {
      res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
      res.end(STARTING_PAGE);
      return;
    }
    res.writeHead(resolved.error, { 'Content-Type': 'text/plain' });
    res.end(resolved.message);
    return;
  }

  proxy.web(req, res, { target: `http://${resolved.target.host}:${resolved.target.port}` });
});

server.on('upgrade', async (req, socket, head) => {
  const resolved = await resolveTarget(req);
  if (resolved.error) {
    socket.write(`HTTP/1.1 ${resolved.error} ${resolved.message}\r\n\r\n`);
    socket.destroy();
    return;
  }
  proxy.ws(req, socket, head, { target: `http://${resolved.target.host}:${resolved.target.port}` });
});

server.listen(PORT, () => {
  console.log(`playground gateway listening on :${PORT} (dynamic mode: ${DYNAMIC_MODE})`);
});
