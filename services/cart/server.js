const express = require('express');
const client = require('prom-client');

const app = express();
app.use(express.json());
client.collectDefaultMetrics();

let down = false;
const carts = new Map(); // sid -> Map(productId -> item)

app.post('/chaos/:mode', (req, res) => { down = req.params.mode === 'down'; res.json({ down }); });
app.get('/healthz', (_, res) => res.send('ok'));
app.get('/metrics', async (_, res) => res.type(client.register.contentType).send(await client.register.metrics()));
app.use((_, res, next) => (down ? res.status(503).json({ error: 'down' }) : next()));

const list = (sid) => [...(carts.get(sid)?.values() || [])];

app.get('/cart/:sid', (req, res) => res.json(list(req.params.sid)));
app.post('/cart/:sid', (req, res) => {
  const c = carts.get(req.params.sid) || new Map();
  const it = req.body;
  const cur = c.get(it.productId);
  c.set(it.productId, cur ? { ...cur, qty: cur.qty + it.qty } : it);
  carts.set(req.params.sid, c);
  res.json(list(req.params.sid));
});
app.delete('/cart/:sid', (req, res) => { carts.delete(req.params.sid); res.json([]); });

app.listen(3001, () => console.log('cart on 3001'));
