// ProxyProof server: auth, device binding, rotating tokens, attendance, live dashboard (SSE), CSV export.
const express = require('express');
const cors = require('cors');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const Database = require('better-sqlite3');
const path = require('path');

const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret-change-me';
const ROTATE = Number(process.env.ROTATE_SECONDS || 5);      // token rotation period (s)
const RSSI_MIN = Number(process.env.RSSI_MIN || -85);         // weakest RSSI accepted as "in the room"
const ORGANISER_CODE = process.env.ORGANISER_CODE || 'ORG123'; // invite code needed to register as organiser
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@proxyproof.local';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'admin123';

const db = new Database(process.env.DB_FILE || path.join(__dirname, 'proxyproof.db'));
db.pragma('journal_mode = WAL');
db.exec(`
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL, email TEXT UNIQUE NOT NULL, roll_no TEXT,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN('student','organiser','admin')),
  device_id TEXT UNIQUE            -- one device <-> one student
);
CREATE TABLE IF NOT EXISTS device_requests(
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
  new_device_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions(
  id INTEGER PRIMARY KEY AUTOINCREMENT, organiser_id INTEGER NOT NULL, title TEXT NOT NULL,
  secret TEXT NOT NULL, started_at INTEGER NOT NULL, ends_at INTEGER NOT NULL, closed_at INTEGER
);
CREATE TABLE IF NOT EXISTS attendance(
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, student_id INTEGER NOT NULL,
  device_id TEXT, rssi INTEGER, method TEXT NOT NULL, marked_at INTEGER NOT NULL,
  UNIQUE(session_id, student_id),
  UNIQUE(session_id, device_id)    -- one device marks only one student per session
);
CREATE TABLE IF NOT EXISTS attempts(
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, student_id INTEGER,
  reason TEXT NOT NULL, rssi INTEGER, created_at INTEGER NOT NULL
);
`);

if (!db.prepare("SELECT 1 FROM users WHERE role='admin'").get()) {
  db.prepare("INSERT INTO users(name,email,password_hash,role) VALUES('Admin',?,?,'admin')")
    .run(ADMIN_EMAIL, bcrypt.hashSync(ADMIN_PASSWORD, 10));
  console.log(`Seeded admin: ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}`);
}

const now = () => Math.floor(Date.now() / 1000);
const isClosed = (s) => !!s.closed_at || s.ends_at <= now();
const statusOf = (s) => (isClosed(s) ? 'closed' : 'active');

// ---------- rotating token (HMAC over the current time window) ----------
const window_ = () => Math.floor(Date.now() / 1000 / ROTATE);
const tokenFor = (secret, w) =>
  crypto.createHmac('sha256', secret).update(String(w)).digest('hex').slice(0, 8); // 32 bits -> fits in BLE adv
function tokenValid(secret, token) {
  if (typeof token !== 'string' || token.length !== 8) return false;
  const w = window_();
  // Current window or the previous one only (5-10 s old). Tokens are never issued ahead of time, so w+1 is not accepted.
  return [w - 1, w].some((x) => {
    const exp = Buffer.from(tokenFor(secret, x));
    const got = Buffer.from(token);
    return exp.length === got.length && crypto.timingSafeEqual(exp, got);
  });
}

// ---------- live updates (SSE) ----------
const streams = new Map();
const emit = (id) => (streams.get(id) || new Set()).forEach((r) => r.write(`data: ${Date.now()}\n\n`));

setInterval(() => {
  const rows = db.prepare('SELECT id FROM sessions WHERE closed_at IS NULL AND ends_at<=?').all(now());
  for (const r of rows) {
    db.prepare('UPDATE sessions SET closed_at=? WHERE id=?').run(now(), r.id);
    emit(r.id);
  }
}, 5000);

// ---------- auth helpers ----------
const publicUser = (u) => ({ id: u.id, name: u.name, email: u.email, rollNo: u.roll_no, role: u.role });
function userFromToken(t) {
  try {
    const { id } = jwt.verify(t, JWT_SECRET);
    return db.prepare('SELECT * FROM users WHERE id=?').get(id);
  } catch { return null; }
}
const auth = (req, res, next) => {
  const h = req.get('Authorization') || '';
  const u = h.startsWith('Bearer ') ? userFromToken(h.slice(7)) : null;
  if (!u) return res.status(401).json({ error: 'Not logged in' });
  req.user = u; next();
};
const roles = (...allowed) => (req, res, next) =>
  allowed.includes(req.user.role) ? next() : res.status(403).json({ error: 'Not allowed' });
const staff = roles('organiser', 'admin');

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ---------- auth ----------
app.post('/api/auth/register', (req, res) => {
  const { name, email, password, role = 'student', rollNo, deviceId, inviteCode } = req.body || {};
  if (!name || !email || !password || password.length < 6)
    return res.status(400).json({ error: 'Name, email and a 6+ char password are required' });
  if (!['student', 'organiser'].includes(role)) return res.status(400).json({ error: 'Bad role' });
  if (role === 'organiser' && inviteCode !== ORGANISER_CODE)
    return res.status(403).json({ error: 'Invalid organiser invite code' });
  if (role === 'student') {
    if (!deviceId) return res.status(400).json({ error: 'Device ID missing' });
    if (db.prepare('SELECT 1 FROM users WHERE device_id=?').get(deviceId))
      return res.status(409).json({ error: 'This device is already registered to another student' });
  }
  if (db.prepare('SELECT 1 FROM users WHERE email=?').get(email.toLowerCase()))
    return res.status(409).json({ error: 'Email already registered' });
  const info = db
    .prepare('INSERT INTO users(name,email,roll_no,password_hash,role,device_id) VALUES(?,?,?,?,?,?)')
    .run(name, email.toLowerCase(), rollNo || null, bcrypt.hashSync(password, 10), role, role === 'student' ? deviceId : null);
  const u = db.prepare('SELECT * FROM users WHERE id=?').get(info.lastInsertRowid);
  res.json({ token: jwt.sign({ id: u.id }, JWT_SECRET, { expiresIn: '7d' }), user: publicUser(u) });
});

app.post('/api/auth/login', (req, res) => {
  const { email, password, deviceId } = req.body || {};
  const u = db.prepare('SELECT * FROM users WHERE email=?').get((email || '').toLowerCase());
  if (!u || !bcrypt.compareSync(password || '', u.password_hash))
    return res.status(401).json({ error: 'Wrong email or password' });
  if (u.role === 'student' && u.device_id !== deviceId) {
    const pending = db.prepare("SELECT 1 FROM device_requests WHERE user_id=? AND new_device_id=? AND status='pending'").get(u.id, deviceId);
    if (!pending && deviceId)
      db.prepare('INSERT INTO device_requests(user_id,new_device_id,created_at) VALUES(?,?,?)').run(u.id, deviceId, now());
    return res.status(403).json({
      code: 'DEVICE_MISMATCH',
      error: 'This account is bound to another device. A device-change request was sent to the admin for approval.',
    });
  }
  res.json({ token: jwt.sign({ id: u.id }, JWT_SECRET, { expiresIn: '7d' }), user: publicUser(u) });
});

app.get('/api/me', auth, (req, res) => res.json(publicUser(req.user)));

// ---------- admin: device change approval ----------
app.get('/api/admin/device-requests', auth, roles('admin'), (req, res) => {
  res.json(db.prepare(`SELECT r.id, r.created_at createdAt, u.name, u.roll_no rollNo, u.email
    FROM device_requests r JOIN users u ON u.id=r.user_id WHERE r.status='pending' ORDER BY r.id DESC`).all());
});
app.post('/api/admin/device-requests/:id/:action', auth, roles('admin'), (req, res) => {
  const r = db.prepare("SELECT * FROM device_requests WHERE id=? AND status='pending'").get(req.params.id);
  if (!r) return res.status(404).json({ error: 'Request not found' });
  if (req.params.action === 'approve') {
    if (db.prepare('SELECT 1 FROM users WHERE device_id=? AND id<>?').get(r.new_device_id, r.user_id))
      return res.status(409).json({ error: 'That device belongs to another student' });
    db.prepare('UPDATE users SET device_id=? WHERE id=?').run(r.new_device_id, r.user_id);
    db.prepare("UPDATE device_requests SET status='approved' WHERE id=?").run(r.id);
  } else if (req.params.action === 'reject') {
    db.prepare("UPDATE device_requests SET status='rejected' WHERE id=?").run(r.id);
  } else return res.status(400).json({ error: 'Bad action' });
  res.json({ ok: true });
});

// ---------- sessions ----------
function ownSession(req, res) {
  const s = db.prepare('SELECT * FROM sessions WHERE id=?').get(req.params.id);
  if (!s) { res.status(404).json({ error: 'Session not found' }); return null; }
  if (req.user.role !== 'admin' && s.organiser_id !== req.user.id) { res.status(403).json({ error: 'Not your session' }); return null; }
  return s;
}

app.post('/api/sessions', auth, staff, (req, res) => {
  const title = (req.body.title || 'Session').toString().slice(0, 80);
  const minutes = Math.min(Math.max(Number(req.body.durationMinutes) || 5, 1), 240);
  const t = now();
  const info = db.prepare('INSERT INTO sessions(organiser_id,title,secret,started_at,ends_at) VALUES(?,?,?,?,?)')
    .run(req.user.id, title, crypto.randomBytes(32).toString('hex'), t, t + minutes * 60);
  res.json({ id: info.lastInsertRowid, title, startedAt: t, endsAt: t + minutes * 60, rotateSeconds: ROTATE });
});

app.get('/api/sessions', auth, staff, (req, res) => {
  const rows = db.prepare(`SELECT s.*, (SELECT COUNT(*) FROM attendance WHERE session_id=s.id) present
    FROM sessions s WHERE (?='admin' OR organiser_id=?) ORDER BY id DESC`).all(req.user.role, req.user.id);
  res.json(rows.map((s) => ({ id: s.id, title: s.title, startedAt: s.started_at, endsAt: s.ends_at, status: statusOf(s), present: s.present })));
});

// The organiser phone polls this and broadcasts the result over BLE.
app.get('/api/sessions/:id/token', auth, staff, (req, res) => {
  const s = ownSession(req, res); if (!s) return;
  if (isClosed(s)) return res.status(410).json({ error: 'Session closed', code: 'SESSION_CLOSED' });
  res.json({ sessionId: s.id, token: tokenFor(s.secret, window_()), rotateSeconds: ROTATE, endsAt: s.ends_at });
});

app.post('/api/sessions/:id/close', auth, staff, (req, res) => {
  const s = ownSession(req, res); if (!s) return;
  if (!s.closed_at) db.prepare('UPDATE sessions SET closed_at=? WHERE id=?').run(now(), s.id);
  emit(s.id); res.json({ ok: true });
});

app.get('/api/sessions/:id', auth, staff, (req, res) => {
  const s = ownSession(req, res); if (!s) return;
  const present = db.prepare(`SELECT a.student_id studentId, u.name, u.roll_no rollNo, a.marked_at markedAt, a.method, a.rssi
    FROM attendance a JOIN users u ON u.id=a.student_id WHERE a.session_id=? ORDER BY a.marked_at`).all(s.id);
  const attempts = db.prepare(`SELECT u.name, u.roll_no rollNo, t.reason, t.rssi, t.created_at at
    FROM attempts t LEFT JOIN users u ON u.id=t.student_id WHERE t.session_id=? ORDER BY t.id DESC LIMIT 25`).all(s.id);
  const students = db.prepare("SELECT id, name, roll_no rollNo FROM users WHERE role='student' ORDER BY roll_no, name").all();
  res.json({ id: s.id, title: s.title, status: statusOf(s), startedAt: s.started_at, endsAt: s.ends_at, present, attempts, students });
});

// Live stream. EventSource can't set headers, so the JWT comes in the query string.
app.get('/api/sessions/:id/stream', (req, res) => {
  const u = userFromToken(req.query.t);
  const id = Number(req.params.id);
  const s = db.prepare('SELECT * FROM sessions WHERE id=?').get(id);
  if (!u || !s || !['organiser', 'admin'].includes(u.role) || (u.role !== 'admin' && s.organiser_id !== u.id)) return res.sendStatus(401);
  res.set({ 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
  res.write('retry: 2000\n\n');
  if (!streams.has(id)) streams.set(id, new Set());
  streams.get(id).add(res);
  const ping = setInterval(() => res.write(': ping\n\n'), 20000);
  req.on('close', () => { clearInterval(ping); streams.get(id).delete(res); });
});

// Manual add / remove
app.post('/api/sessions/:id/attendance', auth, staff, (req, res) => {
  const s = ownSession(req, res); if (!s) return;
  const stu = db.prepare("SELECT id FROM users WHERE id=? AND role='student'").get(req.body.studentId);
  if (!stu) return res.status(404).json({ error: 'Student not found' });
  db.prepare("INSERT OR IGNORE INTO attendance(session_id,student_id,method,marked_at) VALUES(?,?,'manual',?)").run(s.id, stu.id, now());
  emit(s.id); res.json({ ok: true });
});
app.delete('/api/sessions/:id/attendance/:studentId', auth, staff, (req, res) => {
  const s = ownSession(req, res); if (!s) return;
  db.prepare('DELETE FROM attendance WHERE session_id=? AND student_id=?').run(s.id, req.params.studentId);
  emit(s.id); res.json({ ok: true });
});

// ---------- student marks attendance ----------
const hits = new Map();
function rateLimited(uid) {
  const t = Date.now(), arr = (hits.get(uid) || []).filter((x) => t - x < 60000);
  arr.push(t); hits.set(uid, arr);
  return arr.length > 20;
}

app.post('/api/attendance/mark', auth, roles('student'), (req, res) => {
  const { sessionId, token, rssi } = req.body || {};
  const deviceId = req.get('X-Device-Id');
  const s = db.prepare('SELECT * FROM sessions WHERE id=?').get(Number(sessionId));
  if (!s) return res.status(404).json({ ok: false, code: 'NO_SESSION', error: 'Unknown session' });
  if (rateLimited(req.user.id)) return res.status(429).json({ ok: false, code: 'RATE_LIMIT', error: 'Too many attempts' });

  const fail = (code, error, status = 400, log = true) => {
    if (log) {
      db.prepare('INSERT INTO attempts(session_id,student_id,reason,rssi,created_at) VALUES(?,?,?,?,?)')
        .run(s.id, req.user.id, code, Number.isFinite(rssi) ? rssi : null, now());
      emit(s.id);
    }
    return res.status(status).json({ ok: false, code, error });
  };

  if (isClosed(s)) return fail('SESSION_CLOSED', 'Session has ended', 410, false);
  if (req.user.device_id !== deviceId) return fail('DEVICE_MISMATCH', 'Request is not from your registered device', 403);
  if (!tokenValid(s.secret, token)) return fail('STALE_TOKEN', 'Code expired or invalid', 400, false);
  if (typeof rssi !== 'number' || rssi < RSSI_MIN) return fail('TOO_FAR', `Signal too weak (${rssi} dBm) - move closer to the organiser`, 400);

  if (db.prepare('SELECT 1 FROM attendance WHERE session_id=? AND student_id=?').get(s.id, req.user.id))
    return res.json({ ok: true, alreadyMarked: true });
  try {
    db.prepare("INSERT INTO attendance(session_id,student_id,device_id,rssi,method,marked_at) VALUES(?,?,?,?,'auto',?)")
      .run(s.id, req.user.id, deviceId, rssi, now());
  } catch { return fail('DEVICE_ALREADY_USED', 'This device already marked another student', 409); }
  emit(s.id);
  res.json({ ok: true, title: s.title });
});

// ---------- history & percentages ----------
app.get('/api/me/attendance', auth, roles('student'), (req, res) => {
  const rows = db.prepare(`SELECT s.id, s.title, s.started_at startedAt, s.closed_at closedAt, s.ends_at endsAt,
      a.marked_at markedAt, a.method FROM sessions s
      LEFT JOIN attendance a ON a.session_id=s.id AND a.student_id=? ORDER BY s.id DESC`).all(req.user.id);
  const closed = rows.filter((r) => r.closedAt || r.endsAt <= now());
  const present = closed.filter((r) => r.markedAt).length;
  res.json({
    total: closed.length, present,
    percentage: closed.length ? Math.round((present / closed.length) * 1000) / 10 : 0,
    sessions: rows.map((r) => ({ id: r.id, title: r.title, startedAt: r.startedAt, present: !!r.markedAt, method: r.method })),
  });
});

const summaryRows = () => db.prepare(`SELECT u.id, u.name, u.roll_no rollNo,
  (SELECT COUNT(*) FROM sessions WHERE closed_at IS NOT NULL OR ends_at<=CAST(strftime('%s','now') AS INTEGER)) total,
  (SELECT COUNT(*) FROM attendance a JOIN sessions s ON s.id=a.session_id
     WHERE a.student_id=u.id AND (s.closed_at IS NOT NULL OR s.ends_at<=CAST(strftime('%s','now') AS INTEGER))) present
  FROM users u WHERE u.role='student' ORDER BY u.roll_no, u.name`).all()
  .map((r) => ({ ...r, percentage: r.total ? Math.round((r.present / r.total) * 1000) / 10 : 0 }));

app.get('/api/summary', auth, staff, (req, res) => res.json(summaryRows()));

// ---------- CSV ----------
const csv = (rows) => rows.map((r) => r.map((c) => `"${String(c ?? '').replace(/"/g, '""')}"`).join(',')).join('\r\n');
const iso = (t) => (t ? new Date(t * 1000).toISOString() : '');

app.get('/api/sessions/:id/export.csv', auth, staff, (req, res) => {
  const s = ownSession(req, res); if (!s) return;
  const rows = db.prepare(`SELECT u.roll_no, u.name, a.marked_at, a.method, a.rssi FROM users u
    LEFT JOIN attendance a ON a.student_id=u.id AND a.session_id=? WHERE u.role='student' ORDER BY u.roll_no, u.name`).all(s.id);
  const out = [['Roll No', 'Name', 'Status', 'Marked At', 'Method', 'RSSI']].concat(
    rows.map((r) => [r.roll_no, r.name, r.marked_at ? 'Present' : 'Absent', iso(r.marked_at), r.method, r.rssi]));
  res.set({ 'Content-Type': 'text/csv', 'Content-Disposition': `attachment; filename="session-${s.id}.csv"` }).send(csv(out));
});

app.get('/api/export/summary.csv', auth, staff, (req, res) => {
  const out = [['Roll No', 'Name', 'Sessions Held', 'Present', 'Percentage']].concat(
    summaryRows().map((r) => [r.rollNo, r.name, r.total, r.present, r.percentage]));
  res.set({ 'Content-Type': 'text/csv', 'Content-Disposition': 'attachment; filename="attendance-summary.csv"' }).send(csv(out));
});

app.listen(PORT, '0.0.0.0', () => console.log(`ProxyProof server on http://0.0.0.0:${PORT}`));
