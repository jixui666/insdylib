#!/usr/bin/env node
/**
 * ProfileButtons 控制端（零依赖，Node 18+）
 *
 *   GET  /api/buttons   App 拉取按钮配置
 *   PUT  /api/buttons   更新配置（需要 Authorization: Bearer <ADMIN_TOKEN>）
 *   GET  /              简易后台（改链接 / 改文案）
 *   GET  /health
 *
 * 启动：ADMIN_TOKEN=your-secret node server.js
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8080);
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || 'change-me';
const CONFIG_PATH = process.env.CONFIG_PATH || path.join(__dirname, 'config.json');

const DEFAULT_CONFIG = {
  schema: 1,
  buttons: [
    { id: 'store', icon: 'storefront', url: 'https://example.com/store', title: { 'zh-Hans': '店铺中心', en: 'Store Center' } },
    { id: 'showcase', icon: 'bag', url: 'https://example.com/showcase', title: { 'zh-Hans': '商品橱窗', en: 'Showcase' } },
    { id: 'orders', icon: 'doc.text', url: 'https://example.com/orders', title: { 'zh-Hans': '订单详情', en: 'Order Details' } },
  ],
};

function readConfig() {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
    const obj = JSON.parse(raw);
    if (!obj || !Array.isArray(obj.buttons)) throw new Error('bad shape');
    return obj;
  } catch (err) {
    console.warn('[config] fallback to default:', err.message);
    return DEFAULT_CONFIG;
  }
}

function writeConfig(obj) {
  const tmp = CONFIG_PATH + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, CONFIG_PATH);
}

function sendJSON(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

function sendHTML(res, status, html) {
  res.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(html);
}

function authorized(req) {
  const h = req.headers['authorization'] || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : '';
  return token.length > 0 && token === ADMIN_TOKEN;
}

function readBody(req, limit = 256 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function validate(config) {
  if (!config || typeof config !== 'object') return 'not an object';
  if (!Array.isArray(config.buttons) || config.buttons.length === 0) return 'buttons must be a non-empty array';
  for (const b of config.buttons) {
    if (!b || typeof b !== 'object') return 'button must be an object';
    if (typeof b.url !== 'string' || !/^https?:\/\//i.test(b.url)) return `bad url: ${JSON.stringify(b.url)}`;
    if (b.title && typeof b.title === 'object') {
      for (const [k, v] of Object.entries(b.title)) {
        if (typeof v !== 'string' || !v.trim()) return `bad title[${k}]`;
      }
    }
  }
  return null;
}

const ADMIN_PAGE = `<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<title>ProfileButtons 控制台</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body{font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;padding:24px;background:#f5f5f7;color:#1d1d1f}
  h1{font-size:20px;margin:0 0 4px}
  p.hint{color:#6e6e73;margin:0 0 20px}
  .card{background:#fff;border-radius:12px;padding:16px 18px;margin-bottom:14px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
  .row{display:flex;gap:10px;align-items:center;margin:6px 0;flex-wrap:wrap}
  label{width:84px;color:#6e6e73}
  input,textarea{flex:1;min-width:220px;font:inherit;padding:7px 9px;border:1px solid #d2d2d7;border-radius:8px}
  textarea{min-height:110px;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
  button{font:inherit;padding:8px 16px;border-radius:8px;border:0;background:#0071e3;color:#fff;cursor:pointer}
  button.secondary{background:#e8e8ed;color:#1d1d1f}
  code{background:#f0f0f2;padding:1px 5px;border-radius:4px}
  .ok{color:#0a7d33}.err{color:#c00}
</style>
<h1>ProfileButtons 控制台</h1>
<p class="hint">改完点保存 → App 下次启动（或每 10 分钟内进一次个人主页）自动拉取。</p>

<div class="card">
  <div class="row"><label>管理令牌</label><input id="token" type="password" placeholder="ADMIN_TOKEN"></div>
  <div class="row"><button class="secondary" onclick="load()">读取当前配置</button><button onclick="save()">保存</button>
  <span id="status"></span></div>
</div>

<div id="buttons"></div>

<div class="card">
  <label>原始 JSON（高级）</label>
  <textarea id="raw"></textarea>
</div>

<script>
let config = { schema: 1, buttons: [] };
const $ = (id) => document.getElementById(id);
const setStatus = (t, cls) => { $('status').textContent = t; $('status').className = cls || ''; };

async function load() {
  setStatus('读取中…');
  try {
    const r = await fetch('/api/buttons', { cache: 'no-store' });
    config = await r.json();
    render();
    setStatus('已读取', 'ok');
  } catch (e) { setStatus('读取失败: ' + e.message, 'err'); }
}

function render() {
  $('raw').value = JSON.stringify(config, null, 2);
  const box = $('buttons');
  box.innerHTML = '';
  config.buttons.forEach((b, i) => {
    const card = document.createElement('div');
    card.className = 'card';
    card.innerHTML =
      '<div class="row"><label>id</label><input data-i="' + i + '" data-k="id" value="' + (b.id || '') + '"></div>' +
      '<div class="row"><label>链接</label><input data-i="' + i + '" data-k="url" value="' + (b.url || '') + '"></div>' +
      '<div class="row"><label>图标</label><input data-i="' + i + '" data-k="icon" value="' + (b.icon || '') + '" placeholder="SF Symbols，可空"></div>' +
      '<div class="row"><label>文案</label><textarea data-i="' + i + '" data-k="title">' + JSON.stringify(b.title || {}, null, 2) + '</textarea></div>';
    box.appendChild(card);
  });
  box.querySelectorAll('input,textarea').forEach((el) => {
    el.addEventListener('change', () => {
      const i = +el.dataset.i, k = el.dataset.k;
      if (k === 'title') { try { config.buttons[i].title = JSON.parse(el.value); } catch (_) {} }
      else config.buttons[i][k] = el.value;
      $('raw').value = JSON.stringify(config, null, 2);
    });
  });
}

async function save() {
  try {
    const parsed = JSON.parse($('raw').value);
    const r = await fetch('/api/buttons', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + $('token').value.trim() },
      body: JSON.stringify(parsed),
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ('HTTP ' + r.status));
    config = j.config || parsed;
    render();
    setStatus('已保存', 'ok');
  } catch (e) { setStatus('保存失败: ' + e.message, 'err'); }
}

load();
</script>
</html>`;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,PUT,OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    });
    return res.end();
  }

  if (p === '/health') return sendJSON(res, 200, { ok: true, time: Date.now() });

  if (p === '/api/buttons' && req.method === 'GET') {
    return sendJSON(res, 200, readConfig());
  }

  if (p === '/api/buttons' && req.method === 'PUT') {
    if (!authorized(req)) return sendJSON(res, 401, { error: 'unauthorized' });
    try {
      const body = await readBody(req);
      const obj = JSON.parse(body);
      const err = validate(obj);
      if (err) return sendJSON(res, 400, { error: err });
      writeConfig(obj);
      console.log('[config] updated by', req.socket.remoteAddress, new Date().toISOString());
      return sendJSON(res, 200, { ok: true, config: obj });
    } catch (e) {
      return sendJSON(res, 400, { error: e.message });
    }
  }

  if (p === '/' && req.method === 'GET') return sendHTML(res, 200, ADMIN_PAGE);

  sendJSON(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`ProfileButtons control server: http://127.0.0.1:${PORT}`);
  console.log(`  GET  /api/buttons`);
  console.log(`  PUT  /api/buttons   (Authorization: Bearer <ADMIN_TOKEN>)`);
  console.log(`  GET  /              (admin UI)`);
  console.log(`  config: ${CONFIG_PATH}`);
});
