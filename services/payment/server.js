const express = require('express');
const crypto = require('crypto');
const client = require('prom-client');

const app = express();
app.use(express.json());
client.collectDefaultMetrics();
const charges = new client.Counter({ name: 'payment_charges_total', help: 'Charges', labelNames: ['result'] });

let down = false;
const ledger = []; // in-memory

app.post('/chaos/:mode', (req, res) => { down = req.params.mode === 'down'; res.json({ down }); });
app.get('/healthz', (_, res) => res.send('ok'));
app.get('/metrics', async (_, res) => res.type(client.register.contentType).send(await client.register.metrics()));
app.use((_, res, next) => (down ? res.status(503).json({ error: 'down' }) : next()));

app.post('/charge', async (req, res) => {
  const { amount_cents, card = '' } = req.body;
  await new Promise((r) => setTimeout(r, 100 + Math.random() * 300)); // mock latency
  if (!amount_cents || amount_cents <= 0) return res.status(400).json({ error: 'invalid amount' });
  if (String(card).replace(/\s/g, '').endsWith('0000')) {
    charges.inc({ result: 'declined' });
    return res.status(402).json({ error: 'card declined' });
  }
  const ref = 'ch_' + crypto.randomBytes(6).toString('hex');
  ledger.push({ ref, amount_cents, at: new Date().toISOString() });
  charges.inc({ result: 'approved' });
  res.json({ ref, status: 'approved' });
});

app.listen(3002, () => console.log('payment on 3002'));
