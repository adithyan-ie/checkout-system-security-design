const express = require('express');

const app = express();
const PORT = process.env.PORT || 3002;
const DELAY_MS = Number(process.env.DELAY_MS || 0);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Intentionally tiny and in-memory for teaching purposes
const inventory = {
  1: { inStock: true },
  2: { inStock: true },
  3: { inStock: false },
  4: { inStock: true },
  5: { inStock: false },
  6: { inStock: true },
};

app.get('/health', (req, res) => res.json({ ok: true }));

app.get('/stock/:sku', async (req, res) => {

  const requestId = req.header('X-Request-Id') || `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  
  console.log({
    requestId,
    message: 'Inventory request received',
    sku: req.params.sku,
    timestamp: new Date().toISOString(),
  });
  
  try{	
	  if (DELAY_MS > 0) await sleep(DELAY_MS);

  	const sku = Number(req.params.sku);
  	if (!Number.isInteger(sku)) {
    	return res.status(400).json({ error: 'sku must be an integer' });
 	 }
  	const item = inventory[sku];
  	if (!item) return res.status(404).json({ error: 'unknown sku' });
  
 	console.log({ requestId, message: 'Inventory response', sku, inStock: item.inStock });
 	return res.json({ sku, inStock: item.inStock });
	}catch (err) {
    console.error({ requestId, message: 'Inventory request failed', error: err.message, stack: err.stack });
    return res.status(500).json({ error: 'internal server error' });
  }	
});

app.listen(PORT, () => console.log(`inventory-service on ${PORT}`));
