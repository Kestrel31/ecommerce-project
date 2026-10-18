const express = require('express');
const { Pool } = require('pg');
const client = require('prom-client');

const { DATABASE_URL, CART_URL, PAYMENT_URL, ADS_URL } = process.env;
const pool = new Pool({ connectionString: DATABASE_URL });
const app = express();
app.use(express.json());

client.collectDefaultMetrics();
const httpDur = new client.Histogram({
  name: 'http_request_duration_seconds', help: 'HTTP duration',
  labelNames: ['method', 'route', 'status'],
});
const orders = new client.Counter({ name: 'orders_total', help: 'Orders', labelNames: ['result'] });
app.use((req, res, next) => {
  const end = httpDur.startTimer();
  res.on('finish', () => end({ method: req.method, route: req.route?.path || req.path, status: res.statusCode }));
  next();
});

const call = async (url, opts = {}) => {
  const r = await fetch(url, {
    ...opts,
    headers: { 'content-type': 'application/json' },
    body: opts.body && JSON.stringify(opts.body),
    signal: AbortSignal.timeout(2000),
  });
  if (!r.ok) throw Object.assign(new Error(`upstream ${r.status}`), { body: await r.json().catch(() => ({})) });
  return r.json();
};

app.get('/healthz', (_, res) => res.send('ok'));
app.get('/metrics', async (_, res) => res.type(client.register.contentType).send(await client.register.metrics()));

app.get('/api/products', async (_, res) => {
  const { rows } = await pool.query('SELECT * FROM products ORDER BY id');
  res.json(rows);
});

app.get('/api/ads', async (_, res) => {
  try { res.json(await call(`${ADS_URL}/ad`)); } catch { res.json(null); }
});

app.get('/api/cart/:sid', async (req, res) => {
  try { res.json(await call(`${CART_URL}/cart/${req.params.sid}`)); }
  catch { res.status(503).json({ error: 'cart unavailable' }); }
});

app.post('/api/cart/:sid', async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM products WHERE id=$1', [req.body.productId]);
  if (!rows[0]) return res.status(404).json({ error: 'no such product' });
  try {
    res.json(await call(`${CART_URL}/cart/${req.params.sid}`, {
      method: 'POST',
      body: { productId: rows[0].id, name: rows[0].name, price_cents: rows[0].price_cents, qty: 1 },
    }));
  } catch { res.status(503).json({ error: 'cart unavailable' }); }
});

app.delete('/api/cart/:sid', async (req, res) => {
  try { res.json(await call(`${CART_URL}/cart/${req.params.sid}`, { method: 'DELETE' })); }
  catch { res.status(503).json({ error: 'cart unavailable' }); }
});

app.post('/api/checkout/:sid', async (req, res) => {
  const sid = req.params.sid;
  let items;
  try { items = await call(`${CART_URL}/cart/${sid}`); }
  catch { return res.status(503).json({ error: 'cart unavailable' }); }
  if (!items.length) return res.status(400).json({ error: 'cart is empty' });

  const total = items.reduce((s, i) => s + i.price_cents * i.qty, 0);
  let pay;
  try { pay = await call(`${PAYMENT_URL}/charge`, { method: 'POST', body: { amount_cents: total, card: req.body.card } }); }
  catch (e) {
    orders.inc({ result: 'failed' });
    return res.status(e.body?.error ? 402 : 503).json({ error: e.body?.error || 'payment unavailable' });
  }
  const { rows } = await pool.query(
    'INSERT INTO orders (session_id,total_cents,items,payment_ref) VALUES ($1,$2,$3,$4) RETURNING id',
    [sid, total, JSON.stringify(items), pay.ref]);
  await call(`${CART_URL}/cart/${sid}`, { method: 'DELETE' }).catch(() => {});
  orders.inc({ result: 'ok' });
  res.json({ orderId: rows[0].id, total_cents: total });
});

app.use((err, _req, res, _next) => { console.error(err); res.status(500).json({ error: 'internal error' }); });
app.listen(3000, () => console.log('api on 3000'));
