const express = require('express');
const client = require('prom-client');

const app = express();
client.collectDefaultMetrics();

let down = false;
const ads = [
  { text: '🚚 Free shipping on orders over $100!' },
  { text: '🎉 Use code DEVOPS10 for 10% off (not really).' },
  { text: '🔥 New arrivals: check out our monitors.' },
];

app.post('/chaos/:mode', (req, res) => { down = req.params.mode === 'down'; res.json({ down }); });
app.get('/healthz', (_, res) => res.send('ok'));
app.get('/metrics', async (_, res) => res.type(client.register.contentType).send(await client.register.metrics()));
app.use((_, res, next) => (down ? res.status(503).json({ error: 'down' }) : next()));

app.get('/ad', (_, res) => res.json(ads[Math.floor(Math.random() * ads.length)]));

app.listen(3003, () => console.log('ads on 3003'));
