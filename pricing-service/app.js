const express = require('express');

const app = express();
const PORT = process.env.PORT || 3003;
const DELAY_MS = Number(process.env.DELAY_MS || 0);

app.use(express.json({ limit: '50kb' }));

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

app.get('/health', (req, res) => res.json({ ok: true }));

app.post('/price', async (req, res) => {

  const requestId = req.header('X-Request-Id') || `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  
  console.log({
    requestId,
    message: 'Pricing request received',
    timestamp: new Date().toISOString(),
  });	
	
  if (DELAY_MS > 0) await sleep(DELAY_MS);

  const { subtotal } = req.body;
  const s = Number(subtotal);
  if (!Number.isFinite(s) || s < 0) {
    return res.status(400).json({ error: 'subtotal must be a non-negative number' });
  }
  const taxRate = 0.23;
  const tax = Number((s * taxRate).toFixed(2));
  const total = Number((s + tax).toFixed(2));

  console.log({ requestId, message: 'Pricing response', s, tax, total });
  return res.json({ subtotal: s, taxRate, tax, total });
});

app.listen(PORT, () => console.log(`pricing-service on ${PORT}`));
