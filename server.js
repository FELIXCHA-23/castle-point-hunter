'use strict';
// 캐슬 포인트 헌터 — 외부 패키지 없는 Node(18+) 서버.
// 저장: 기본은 data/db.json 한 파일. SUPABASE_URL / SUPABASE_SERVICE_KEY 가 있으면 학생별로 Supabase 에 저장(무료 서버에서도 데이터 유지).
const http = require('http'), fs = require('fs'), path = require('path'), crypto = require('crypto');

const PORT = +process.env.PORT || 3000;
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const IMG_DIR = path.join(DATA_DIR, 'img');
const DB_FILE = path.join(DATA_DIR, 'db.json');
const PUB = __dirname; // 화면 파일은 index.html 하나뿐이고, serveStatic 이 그 파일만 내보냅니다.
const SB_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SB_KEY = process.env.SUPABASE_SERVICE_KEY || '';
const REMOTE = !!(SB_URL && SB_KEY);
const TABLE = SB_URL + '/rest/v1/castle_kv';

const GRADES = ['중1', '중2', '중3', '고1', '고2', '고3'];
const CFG = {
  START_POINTS: 5000, PREVIEW_COST: 10, PREVIEW_SEC: 10, ACCEPT_COST: 100,
  TIME_LIMIT_SEC: 30 * 60, REWARD: 500, MORNING_FROM: 7, MORNING_TO: 9, DAILY_BONUS_COUNT: 15,
};
const CFG_RULES = { // [최소, 최대]
  START_POINTS: [0, 1e6], PREVIEW_COST: [0, 1e5], PREVIEW_SEC: [3, 120], ACCEPT_COST: [0, 1e5],
  TIME_LIMIT_SEC: [60, 6 * 3600], REWARD: [0, 1e6], MORNING_FROM: [0, 23], MORNING_TO: [1, 24], DAILY_BONUS_COUNT: [1, 500],
};
const PREVIEW_GRACE_MS = 3000, SUBMIT_GRACE_MS = 5000, MAX_ATTEMPTS = 200, MAX_LOG = 150;

// ---------- 저장소 ----------
let db = { admin: null, problems: [], cfg: {}, sessions: {}, students: {} };
// Supabase 표 castle_kv(key text primary key, value text) 한 개를 키-값 저장소로 씁니다.
async function sb(method, query, body, extra) {
  const r = await fetch(TABLE + query, {
    method, body: body === undefined ? undefined : JSON.stringify(body),
    headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'Content-Type': 'application/json', ...extra },
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}
const kvGet = async (k) => { const r = await sb('GET', `?key=eq.${encodeURIComponent(k)}&select=value`); return r && r[0] ? r[0].value : null; };
const kvSet = (k, v) => sb('POST', '?on_conflict=key', { key: k, value: v }, { Prefer: 'resolution=merge-duplicates,return=minimal' });
const kvDel = (k) => sb('DELETE', `?key=eq.${encodeURIComponent(k)}`, undefined, { Prefer: 'return=minimal' });
async function kvListPrefix(prefix) { // 한 번에 200개씩
  const out = [];
  for (let off = 0; ; off += 200) {
    const rows = await sb('GET', `?key=like.${encodeURIComponent(prefix)}*&select=value&order=key`, undefined, { Range: `${off}-${off + 199}`, 'Range-Unit': 'items' });
    out.push(...rows.map((r) => r.value));
    if (rows.length < 200) return out;
  }
}
const metaJson = () => JSON.stringify({ admin: db.admin, problems: db.problems, cfg: db.cfg });
function writeLocal() {
  const t = DB_FILE + '.tmp';
  fs.writeFileSync(t, JSON.stringify({ admin: db.admin, problems: db.problems, cfg: db.cfg, sessions: db.sessions, students: db.students }));
  fs.renameSync(t, DB_FILE);
}
const dirty = new Set(); let timer = null, flushing = false;
function touch(k) { dirty.add(k); if (!timer) timer = setTimeout(flush, REMOTE ? 250 : 40); }
const tm = () => touch('meta'), tss = () => touch('sess'), ts = (st) => touch('s:' + st.id);
async function flush() {
  timer = null;
  if (flushing) { timer = setTimeout(flush, 250); return; }
  flushing = true;
  const keys = [...dirty]; dirty.clear();
  try {
    if (REMOTE) {
      for (const k of keys) {
        if (k === 'meta') await kvSet('meta', metaJson());
        else if (k === 'sess') await kvSet('sess', JSON.stringify(db.sessions));
        else { const s = db.students[k.slice(2)]; await (s ? kvSet(k, JSON.stringify(s)) : kvDel(k)); }
      }
    } else writeLocal();
  } catch (e) {
    console.error('저장 실패, 5초 뒤 다시 시도합니다:', e.message);
    keys.forEach((k) => dirty.add(k)); timer = setTimeout(flush, 5000);
  } finally { flushing = false; }
}
async function load() {
  fs.mkdirSync(IMG_DIR, { recursive: true });
  if (REMOTE) {
    const meta = await kvGet('meta'); if (meta) Object.assign(db, JSON.parse(meta));
    const ss = await kvGet('sess'); if (ss) db.sessions = JSON.parse(ss);
    const rows = await kvListPrefix('s:');
    for (const v of rows) { const s = JSON.parse(v); db.students[s.id] = s; }
    console.log(`Supabase 에서 학생 ${rows.length}명을 불러왔어요.`);
  } else if (fs.existsSync(DB_FILE)) Object.assign(db, JSON.parse(fs.readFileSync(DB_FILE, 'utf8')));
  Object.assign(CFG, db.cfg || {});
}

// ---------- 비밀번호 ----------
const hashPw = (pw, salt) => crypto.scryptSync(pw, salt, 32).toString('hex');
function setPw(o, pw) { o.salt = crypto.randomBytes(8).toString('hex'); o.hash = hashPw(pw, o.salt); }
function checkPw(o, pw) {
  return crypto.timingSafeEqual(Buffer.from(hashPw(String(pw), o.salt), 'hex'), Buffer.from(o.hash, 'hex'));
}

// ---------- 시간(한국시간) ----------
const kst = (t = Date.now()) => new Date(t + 9 * 3600e3);
const kstDay = (t) => kst(t).toISOString().slice(0, 10);
const kstHour = (t) => kst(t).getUTCHours();
const isMorning = (t = Date.now()) => kstHour(t) >= CFG.MORNING_FROM && kstHour(t) < CFG.MORNING_TO;

// ---------- 도우미 ----------
const fail = (code, msg) => Object.assign(new Error(msg), { code });
const prob = (id) => db.problems.find((p) => p.id === id);
const norm = (s) => String(s ?? '').normalize('NFKC').replace(/[\s,]/g, '').replace(/[−–—‐]/g, '-').replace(/^\+/, '');
const NUM = /^-?\d+(\.\d+)?$/;
function sameAnswer(a, b) {
  a = norm(a); b = norm(b);
  if (NUM.test(a) && NUM.test(b)) return Math.abs(Number(a) - Number(b)) < 1e-9;
  return a === b;
}
function addPts(st, delta, reason) {
  st.points += delta;
  st.log.push({ t: Date.now(), delta, reason, balance: st.points });
  if (st.log.length > MAX_LOG) st.log.splice(0, st.log.length - MAX_LOG);
  ts(st);
}
const todayCount = (st) => { const d = kstDay(Date.now()); return st.attempts.filter((a) => a.day === d).length; };
function nextMult(st) {
  const morning = isMorning(), daily = todayCount(st) + 1 >= CFG.DAILY_BONUS_COUNT;
  return { morning, daily, value: morning || daily ? 2 : 1 };
}
const activeOf = (st) => st.attempts.find((a) => a.state === 'preview' || a.state === 'solving');
const pubProb = (p) => ({ id: p.id, grade: p.grade, text: p.text, image: p.image || '' });
const maskName = (n) => (n.length <= 1 ? n : n.length === 2 ? n[0] + '*' : n[0] + '*'.repeat(n.length - 2) + n[n.length - 1]);

function finish(st, a, answer, now, timeout) {
  const p = prob(a.pid);
  const ok = !timeout && !!p && sameAnswer(answer, p.answer);
  Object.assign(a, { state: 'done', answer: String(answer ?? '').slice(0, 60), correct: ok, timeout: !!timeout, endAt: now, reward: ok ? CFG.REWARD * a.mult : 0 });
  if (!st.done.includes(a.pid)) st.done.push(a.pid);
  if (ok) addPts(st, a.reward, `정답 보상 (+${CFG.REWARD}${a.mult > 1 ? ' ×' + a.mult : ''})`);
  ts(st);
}
function settle(st) {
  const a = activeOf(st), now = Date.now();
  if (!a) return null;
  if (a.state === 'preview' && now > a.previewAt + CFG.PREVIEW_SEC * 1000 + PREVIEW_GRACE_MS) { a.state = 'skipped'; a.endAt = now; ts(st); return null; }
  if (a.state === 'solving' && now > a.deadline + SUBMIT_GRACE_MS) { finish(st, a, '', now, true); return null; }
  return a;
}
function activeView(a) {
  if (!a) return null;
  const p = prob(a.pid);
  if (!p) return null;
  return { state: a.state, problem: pubProb(p), previewEndsAt: a.previewAt + CFG.PREVIEW_SEC * 1000, deadline: a.deadline || 0 };
}
function trimAttempts(st) { if (st.attempts.length > MAX_ATTEMPTS) st.attempts.splice(0, st.attempts.length - MAX_ATTEMPTS); }

// ---------- 로그인 제한 ----------
const tries = {};
function throttle(key) { const t = tries[key]; if (t && t.until > Date.now()) throw fail(429, '로그인 시도가 너무 많아요. 5분 뒤에 다시 해 주세요.'); }
function failed(key) { const t = tries[key] = tries[key] || { n: 0, until: 0 }; if (++t.n >= 5) { t.until = Date.now() + 5 * 60e3; t.n = 0; } }

// ---------- 인증 ----------
function auth(req, role) {
  const tk = (req.headers.authorization || '').replace(/^Bearer /, '');
  const s = db.sessions[tk];
  if (!s || s.exp < Date.now()) throw fail(401, '다시 로그인해 주세요.');
  if (role && s.role !== role) throw fail(403, '권한이 없어요.');
  return s;
}
const student = (req) => { const s = auth(req, 'student'); const st = db.students[s.id]; if (!st) throw fail(401, '다시 로그인해 주세요.'); return st; };

// ---------- 이미지 ----------
const IMG_NAME = /^[a-f0-9]{16}\.(png|jpg|gif|webp)$/;
const imgCache = new Map();
async function putImage(name, mime, buf) {
  if (REMOTE) await kvSet('img:' + name, mime + '|' + buf.toString('base64'));
  else fs.writeFileSync(path.join(IMG_DIR, name), buf);
}
async function getImage(name) {
  if (imgCache.has(name)) return imgCache.get(name);
  let v = null;
  if (REMOTE) { const r = await kvGet('img:' + name); if (r) { const i = r.indexOf('|'); v = { mime: r.slice(0, i), buf: Buffer.from(r.slice(i + 1), 'base64') }; } }
  else { const f = path.join(IMG_DIR, name); if (fs.existsSync(f)) v = { mime: MIME[path.extname(name)], buf: fs.readFileSync(f) }; }
  if (v) { if (imgCache.size > 60) imgCache.delete(imgCache.keys().next().value); imgCache.set(name, v); }
  return v;
}

// ---------- 문제 ----------
function upsertProblem(b) {
  const grade = b.grade, text = String(b.text || '').trim().slice(0, 4000), answer = norm(b.answer);
  if (!GRADES.includes(grade)) throw fail(400, '학년이 올바르지 않아요.');
  if (!text) throw fail(400, '문제 내용을 입력해 주세요.');
  if (!NUM.test(answer)) throw fail(400, '정답은 숫자만 쓸 수 있어요 (예: 12, -3, 0.5).');
  const rec = {
    id: b.id && prob(b.id) ? b.id : crypto.randomBytes(5).toString('hex'), grade, text, answer,
    image: /^\/img\/[a-f0-9]{16}\.\w+$/.test(b.image || '') ? b.image : '',
    explanation: String(b.explanation || '').slice(0, 6000), extra: String(b.extra || '').slice(0, 6000), active: b.active !== false,
  };
  const i = db.problems.findIndex((p) => p.id === rec.id);
  if (i >= 0) db.problems[i] = rec; else db.problems.push(rec);
  tm(); return rec;
}

// ---------- API ----------
const routes = {
  'GET /api/health': () => ({ ok: true }),
  'POST /api/login': (req, b, ip) => {
    const id = String(b.id || '').normalize('NFC').replace(/\s/g, ''), pw = String(b.pw || '');
    const key = id + '|' + ip; throttle(key);
    const isAdmin = id.toLowerCase() === 'admin';
    const o = isAdmin ? db.admin : db.students[id];
    if (!o || !checkPw(o, pw)) { failed(key); throw fail(400, '아이디 또는 비밀번호가 맞지 않아요.'); }
    const token = crypto.randomBytes(24).toString('hex');
    db.sessions[token] = { id: isAdmin ? 'admin' : id, role: isAdmin ? 'admin' : 'student', exp: Date.now() + 7 * 864e5 };
    for (const k of Object.keys(db.sessions)) if (db.sessions[k].exp < Date.now()) delete db.sessions[k];
    tss();
    return { token, role: isAdmin ? 'admin' : 'student', mustChange: !isAdmin && !!o.mustChange };
  },
  'POST /api/logout': (req) => { const tk = (req.headers.authorization || '').replace(/^Bearer /, ''); delete db.sessions[tk]; tss(); return { ok: true }; },
  'POST /api/setpw': (req, b) => {
    const st = student(req), pw = String(b.pw || '');
    if (!/^\d{4}$/.test(pw)) throw fail(400, '비밀번호는 숫자 4자리예요.');
    if (pw === '0000') throw fail(400, '0000은 쓸 수 없어요. 다른 숫자로 정해 주세요.');
    setPw(st, pw); st.mustChange = false; ts(st); return { ok: true };
  },
  'GET /api/me': (req) => {
    const st = student(req), a = settle(st);
    return {
      id: st.id, name: st.name, points: st.points, mustChange: !!st.mustChange, grades: GRADES, cfg: CFG,
      mult: nextMult(st), todayCount: todayCount(st), active: activeView(a), serverNow: Date.now(),
    };
  },
  'GET /api/rank': (req) => {
    const me = student(req);
    const all = Object.values(db.students).sort((a, b) => b.points - a.points);
    return {
      top: all.slice(0, 10).map((s, i) => ({ rank: i + 1, name: maskName(s.name), points: s.points, me: s.id === me.id })),
      myRank: all.findIndex((s) => s.id === me.id) + 1, total: all.length,
    };
  },
  'POST /api/preview': (req, b) => {
    const st = student(req); settle(st);
    if (activeOf(st)) throw fail(400, '진행 중인 문제가 있어요.');
    if (!GRADES.includes(b.grade)) throw fail(400, '학년을 선택해 주세요.');
    if (st.points < CFG.PREVIEW_COST) throw fail(400, '포인트가 부족해요.');
    const pool = db.problems.filter((p) => p.grade === b.grade && p.active !== false && !st.done.includes(p.id));
    if (!pool.length) throw fail(400, '이 학년에는 새로 풀 문제가 없어요. 다른 학년을 골라 보세요!');
    const seen = new Set(st.attempts.map((x) => x.pid));
    const fresh = pool.filter((p) => !seen.has(p.id)), list = fresh.length ? fresh : pool;
    const p = list[crypto.randomInt(list.length)];
    addPts(st, -CFG.PREVIEW_COST, '문제 미리보기');
    const a = { id: crypto.randomBytes(6).toString('hex'), pid: p.id, grade: p.grade, state: 'preview', previewAt: Date.now() };
    st.attempts.push(a); trimAttempts(st); ts(st);
    return { points: st.points, active: activeView(a), serverNow: Date.now() };
  },
  'POST /api/skip': (req) => {
    const st = student(req), a = activeOf(st);
    if (a && a.state === 'preview') { a.state = 'skipped'; a.endAt = Date.now(); ts(st); }
    return { points: st.points };
  },
  'POST /api/accept': (req) => {
    const st = student(req), a = activeOf(st), now = Date.now();
    if (!a || a.state !== 'preview') throw fail(400, '미리보기 중인 문제가 없어요.');
    if (now > a.previewAt + CFG.PREVIEW_SEC * 1000 + PREVIEW_GRACE_MS) { settle(st); throw fail(400, '선택 시간이 지나 문제가 넘어갔어요.'); }
    if (st.points < CFG.ACCEPT_COST) { a.state = 'skipped'; a.endAt = now; ts(st); throw fail(400, `풀이 포인트(${CFG.ACCEPT_COST}P)가 부족해요.`); }
    addPts(st, -CFG.ACCEPT_COST, '문제 풀기 선택');
    a.day = kstDay(now); a.mult = nextMult(st).value;
    a.state = 'solving'; a.startAt = now; a.deadline = now + CFG.TIME_LIMIT_SEC * 1000; ts(st);
    return { points: st.points, active: activeView(a), mult: a.mult, serverNow: now };
  },
  'POST /api/submit': (req, b) => {
    const st = student(req), a = activeOf(st), now = Date.now();
    if (!a || a.state !== 'solving') throw fail(400, '풀고 있는 문제가 없어요.');
    finish(st, a, b.answer, now, now > a.deadline + SUBMIT_GRACE_MS);
    const p = prob(a.pid) || {};
    return {
      correct: a.correct, timeout: a.timeout, reward: a.reward, mult: a.mult, points: st.points,
      answer: p.answer || '', explanation: p.explanation || '', extra: p.extra || '',
    };
  },
  'GET /api/history': (req) => {
    const st = student(req);
    return st.attempts.filter((a) => a.state === 'done').slice(-30).reverse().map((a) => {
      const p = prob(a.pid) || { text: '(삭제된 문제)' };
      return { t: a.endAt, grade: a.grade, text: p.text, image: p.image, correct: a.correct, timeout: a.timeout, reward: a.reward, myAnswer: a.answer, answer: p.answer, explanation: p.explanation, extra: p.extra };
    });
  },

  // ----- 관리자 -----
  'GET /api/admin/students': (req) => {
    auth(req, 'admin');
    return Object.values(db.students).map((s) => ({ id: s.id, name: s.name, points: s.points, mustChange: !!s.mustChange, today: todayCount(s), solved: s.done.length }));
  },
  'POST /api/admin/students': (req, b) => {
    auth(req, 'admin');
    const added = [], skipped = [];
    for (const line of String(b.text || '').normalize('NFC').split(/\r?\n/)) {
      const l = line.trim(); if (!l) continue;
      const m = l.match(/^([가-힣A-Za-z·]+)\s*[,\t ]?\s*(\d{4})$/);
      if (!m) { skipped.push(l + ' (형식 오류)'); continue; }
      const id = m[1] + m[2];
      if (id.toLowerCase() === 'admin' || db.students[id]) { skipped.push(id + ' (이미 있음)'); continue; }
      const st = { id, name: m[1], points: 0, mustChange: true, createdAt: Date.now(), attempts: [], done: [], log: [] };
      setPw(st, '0000'); db.students[id] = st; addPts(st, CFG.START_POINTS, '기본 포인트'); added.push(id);
    }
    return { added, skipped };
  },
  'POST /api/admin/points': (req, b) => {
    auth(req, 'admin');
    const delta = Math.trunc(Number(b.delta));
    if (!Number.isFinite(delta) || delta === 0) throw fail(400, '포인트 숫자를 입력해 주세요.');
    const ids = Array.isArray(b.ids) ? b.ids : [];
    const reason = String(b.reason || '').trim().slice(0, 60) || '관리자 지급';
    let n = 0;
    for (const id of ids) { const st = db.students[id]; if (st) { addPts(st, delta, '관리자: ' + reason); n++; } }
    return { count: n };
  },
  'POST /api/admin/resetpw': (req, b) => {
    auth(req, 'admin'); const st = db.students[b.id];
    if (!st) throw fail(404, '학생이 없어요.');
    setPw(st, '0000'); st.mustChange = true; ts(st); return { ok: true };
  },
  'POST /api/admin/deletestudent': (req, b) => { auth(req, 'admin'); delete db.students[b.id]; touch('s:' + b.id); return { ok: true }; },
  'POST /api/admin/adminpw': (req, b) => {
    auth(req, 'admin');
    if (String(b.pw || '').length < 6) throw fail(400, '관리자 비밀번호는 6자 이상이어야 해요.');
    setPw(db.admin, String(b.pw)); tm(); return { ok: true };
  },
  'GET /api/admin/cfg': (req) => { auth(req, 'admin'); return CFG; },
  'POST /api/admin/cfg': (req, b) => {
    auth(req, 'admin');
    const next = {};
    for (const [k, [lo, hi]] of Object.entries(CFG_RULES)) {
      const v = Math.trunc(Number(b[k]));
      if (!Number.isFinite(v) || v < lo || v > hi) throw fail(400, `${k} 값은 ${lo}~${hi} 사이 숫자여야 해요.`);
      next[k] = v;
    }
    if (next.MORNING_TO <= next.MORNING_FROM) throw fail(400, '아침 시간대의 끝은 시작보다 늦어야 해요.');
    Object.assign(CFG, next); db.cfg = { ...next }; tm(); return CFG;
  },
  'GET /api/admin/problems': (req) => { auth(req, 'admin'); return db.problems; },
  'POST /api/admin/problem': (req, b) => { auth(req, 'admin'); return { problem: upsertProblem(b) }; },
  'POST /api/admin/import': (req, b) => {
    auth(req, 'admin');
    if (!Array.isArray(b.items)) throw fail(400, '문제 목록(배열)이 필요해요.');
    let n = 0; const errors = [];
    b.items.forEach((it, i) => { try { upsertProblem(it); n++; } catch (e) { errors.push(`${i + 1}번째: ${e.message}`); } });
    return { count: n, errors };
  },
  'POST /api/admin/deleteproblem': (req, b) => { auth(req, 'admin'); db.problems = db.problems.filter((p) => p.id !== b.id); tm(); return { ok: true }; },
  'POST /api/admin/upload': async (req, b) => {
    auth(req, 'admin');
    const m = String(b.dataUrl || '').match(/^data:image\/(png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=]+)$/);
    if (!m) throw fail(400, '이미지 파일(png/jpg/gif/webp)만 올릴 수 있어요.');
    const buf = Buffer.from(m[2], 'base64');
    if (buf.length > 900 * 1024) throw fail(400, '그림이 너무 커요 (900KB 이하).');
    const ext = m[1] === 'jpeg' ? 'jpg' : m[1], name = crypto.randomBytes(8).toString('hex') + '.' + ext;
    await putImage(name, 'image/' + m[1].replace('jpg', 'jpeg'), buf);
    return { url: '/img/' + name };
  },
  'GET /api/admin/log': (req) => {
    auth(req, 'admin');
    const rows = [];
    for (const s of Object.values(db.students)) for (const l of s.log.slice(-60)) rows.push({ ...l, sid: s.id });
    return rows.sort((a, b) => b.t - a.t).slice(0, 300);
  },
};

// 처음 실행 때 보여줄 샘플 문제 (관리자 화면에서 지우세요)
function seedSamples() {
  if (db.problems.length) return;
  [
    ['중1', 'x = 3일 때, 2x + 5의 값을 구하시오.', '11', 'x에 3을 넣으면 2×3+5 = 11', ''],
    ['중2', '일차함수 y = 2x − 1의 그래프가 점 (a, 7)을 지날 때, a의 값을 구하시오.', '4', 'y = 7을 대입하면 7 = 2a − 1, 2a = 8, a = 4', ''],
    ['중3', '(√8 + √2)²의 값을 구하시오.', '18', '√8 = 2√2 이므로 √8 + √2 = 3√2, 제곱하면 18.', '[변형 풀이] 원래 문제는 √8 + √2 의 값(3√2)을 구하는 문제였습니다. 답이 숫자만 되도록 제곱한 값을 묻는 문제로 바꾸었으며, 3√2 를 제곱하면 9 × 2 = 18 입니다.'],
    ['고1', '이차방정식 x² − 5x + 6 = 0의 두 근의 합을 구하시오.', '5', '근과 계수의 관계에서 두 근의 합은 5.', ''],
    ['고2', '등차수열 {aₙ}에서 a₁ = 3, 공차가 4일 때, a₁₀의 값을 구하시오.', '39', 'a₁₀ = 3 + 9×4 = 39', ''],
    ['고3', '함수 f(x) = x³ − 3x 의 극댓값을 구하시오.', '2', "f'(x) = 3x² − 3 = 0 에서 x = −1 일 때 극대, f(−1) = −1 + 3 = 2", ''],
  ].forEach(([grade, text, answer, explanation, extra]) => upsertProblem({ grade, text, answer, explanation, extra }));
}

// ---------- HTTP ----------
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.ico': 'image/x-icon' };
const COMMON = { 'X-Content-Type-Options': 'nosniff' };
function sendJson(res, code, obj) { res.writeHead(code, { ...COMMON, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(obj)); }
function serveStatic(res, rel) {
  const f = path.join(PUB, 'index.html');
  if (rel !== 'index.html') { res.writeHead(404, COMMON); return res.end('Not found'); }
  res.writeHead(200, { ...COMMON, 'Content-Type': MIME[path.extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
  fs.createReadStream(f).pipe(res);
}
async function onRequest(req, res) {
  const url = new URL(req.url, 'http://x'), key = req.method + ' ' + url.pathname;
  if (url.pathname.startsWith('/api/')) {
    const h = routes[key];
    if (!h) return sendJson(res, 404, { error: '없는 주소예요.' });
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 4e6) req.destroy(); });
    req.on('end', async () => {
      try { sendJson(res, 200, await h(req, body ? JSON.parse(body) : {}, req.socket.remoteAddress)); }
      catch (e) { sendJson(res, e.code || 500, { error: e.code ? e.message : '서버 오류가 났어요.' }); if (!e.code) console.error(e); }
    });
    return;
  }
  if (url.pathname.startsWith('/img/')) {
    const name = url.pathname.slice(5);
    const v = IMG_NAME.test(name) ? await getImage(name).catch(() => null) : null;
    if (!v) { res.writeHead(404, COMMON); return res.end('Not found'); }
    res.writeHead(200, { ...COMMON, 'Content-Type': v.mime, 'Cache-Control': 'public, max-age=31536000, immutable' });
    return res.end(v.buf);
  }
  serveStatic(res, url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
}

async function main() {
  await load();
  if (!db.admin) {
    db.admin = {};
    const pw = process.env.ADMIN_PASSWORD || 'castle1234!';
    setPw(db.admin, pw); tm();
    if (!process.env.ADMIN_PASSWORD) console.log('※ 관리자 초기 비밀번호: castle1234!  (관리자 화면 > 설정에서 꼭 바꾸세요)');
  }
  seedSamples();
  if (!REMOTE && process.env.RENDER) console.warn('※ 경고: 원격 저장소가 연결되지 않았어요. 이 서버는 재시작하면 데이터가 사라질 수 있어요.');
  console.log(`저장 방식: ${REMOTE ? '원격(Supabase)' : '로컬 파일 ' + DB_FILE}`);
  http.createServer((req, res) => onRequest(req, res).catch((e) => { console.error(e); try { res.writeHead(500); res.end(); } catch {} })).listen(PORT, () => console.log(`캐슬 포인트 헌터 실행 중: http://localhost:${PORT}`));
  const bye = async () => { try { if (timer) clearTimeout(timer); if (dirty.size) { if (REMOTE) await flush(); else writeLocal(); } } finally { process.exit(0); } };
  process.on('SIGINT', bye); process.on('SIGTERM', bye);
}
main().catch((e) => { console.error('시작 실패:', e); process.exit(1); });
