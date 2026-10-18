const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const client = require('prom-client');

const app = express();
client.collectDefaultMetrics();

app.get('/healthz', (_, res) => res.send('ok'));
app.get('/metrics', async (_, res) => res.type(client.register.contentType).send(await client.register.metrics()));
app.use(createProxyMiddleware({
  target: process.env.API_URL,
  pathFilter: '/api',
  changeOrigin: true,
}));
app.use(express.static('public'));

app.listen(8080, () => console.log('frontend on 8080'));
