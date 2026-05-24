const express = require('express');

const app = express();
const PORT = process.env.PORT || 3001;
const { Pool }  = require('pg');
const crypto = require('crypto');

app.use(express.json({ limit: '50kb' }));

const PRICING_URL = process.env.PRICING_URL || 'http://pricing-service:3003';
const INVENTORY_URL = process.env.INVENTORY_URL || 'http://inventory-service:3002';
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 1500);



function withTimeout(ms) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), ms);
  return { signal: c.signal, cancel: () => clearTimeout(t) };
}

// 🔹 Generate Request ID if not provided
function generateRequestId() {
  return crypto.randomUUID();
}

app.use((req, res, next) => {
  const incomingId = req.header('X-Request-Id');
  const requestId = incomingId || generateRequestId();

  req.requestId = requestId;

  // return it in response also
  res.setHeader('X-Request-Id', requestId);

  next();
});

function log(requestId, message, extra = {}) {
  console.log(JSON.stringify({
    requestId,
    message,
    ...extra,
    timestamp: new Date().toISOString(),
  }));
}

// 🔹 Safe fetch wrapper (FAIL FAST + CLEAR ERROR)
async function safeFetch(url, options, serviceName, requestId) {
  try {
    const res = await fetch(url, {
      ...options,
       headers: {
        ...(options.headers || {}),
        'X-Request-Id': requestId, // 🔥 PROPAGATION
      },
  });

    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(`${serviceName} responded with error: ${body.error || res.status}`);
    }

    return await res.json();
  } catch (err) {
    if (err.name === 'AbortError') {
      throw new Error(`${serviceName} timeout after ${TIMEOUT_MS}ms`);
    }
    throw new Error(`${serviceName} unavailable`);
  }
}



const client = new Pool({
  host: 'postgres-db',               // Kubernetes Service name
  port: 5432,
  user: process.env.POSTGRES_USER || 'postgres',
  password: process.env.POSTGRES_PASSWORD || 'admin',
  database: process.env.POSTGRES_DB || 'shop'               // default DB or your DB name
});

async function init_db() {
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
	requestId varchar(100),
        sku INTEGER,
        subtotal NUMERIC,
        price JSONB,
        in_stock BOOLEAN,
        created_at TIMESTAMP DEFAULT NOW()
      );
    `);
    console.log('✅ Table "orders" ensured');
  } catch (err) {
    console.error('❌ DB init error:', err);
  }
}

app.get('/health', (req, res) => res.json({ ok: true }));

app.post('/api/checkout', async (req, res) => {
  const { sku, subtotal } = req.body;
  const skuNum = Number(sku);
  const subNum = Number(subtotal);

 const requestId = req.requestId;

 log(requestId, 'Checkout request received', { sku: skuNum, subtotal: subNum });

  if (!Number.isInteger(skuNum)) {
    return res.status(400).json({ error: 'sku must be an integer' });
  }
  if (!Number.isFinite(subNum) || subNum < 0) {
    return res.status(400).json({ error: 'subtotal must be a non-negative number' });
  }

  const pricingCtl = withTimeout(TIMEOUT_MS);
  const invCtl = withTimeout(TIMEOUT_MS);

  try {
    const [priceRes, stockRes] = await Promise.all([
      safeFetch(`${PRICING_URL}/price`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ subtotal: subNum }),
        signal: pricingCtl.signal,
      },'Pricing Service', requestId),
      safeFetch(`${INVENTORY_URL}/stock/${skuNum}`, { signal: invCtl.signal },'Inventory Service',requestId),
    ]);


    const price = await priceRes;
    const stock = await stockRes;

    if (!stock.inStock) {
      return res.status(409).json({ error: 'out of stock', sku: skuNum, price });
    }

     await client.query(
      `INSERT INTO orders (requestId,sku, subtotal, price, in_stock)
       VALUES ($1, $2, $3, $4, $5)`,
      [requestId, skuNum, subNum, price, stock.inStock]
    );  
     log(requestId, 'Checkout success', { sku: skuNum });  
    return res.json({ ok: true, requestId: requestId, sku: skuNum, price, stock });

  } catch (e) {
    log(requestId, 'Checkout failed', { error: e.stack });
    return res.status(500).json({ error: 'dependency timeout/unavailable' });
  } finally {
    pricingCtl.cancel();
    invCtl.cancel();
  }
});


// GET all saved checkouts
app.get('/api/checkout', async (req, res) => {
  try {
    const result = await client.query('SELECT * FROM orders');
    res.json(result.rows);
  } catch (err) {
    log(requestId, 'Checkout fetch failed, DB error', { error: err.message });
    res.status(500).json({ error: 'Failed to fetch orders' });
  }
});

app.listen(PORT, async () =>{
	await init_db();
	console.log(`checkout-service on ${PORT}`)

});
