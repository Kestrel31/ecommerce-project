CREATE TABLE products (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  price_cents INT NOT NULL,
  emoji TEXT
);

CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  session_id TEXT NOT NULL,
  total_cents INT NOT NULL,
  items JSONB NOT NULL,
  payment_ref TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO products (name, description, price_cents, emoji) VALUES
 ('Mechanical Keyboard', 'Tactile switches, hot-swappable', 8999, '⌨️'),
 ('Wireless Mouse', 'Ergonomic, 6 buttons', 3499, '🖱️'),
 ('4K Monitor', '27 inch IPS', 32999, '🖥️'),
 ('Headphones', 'Noise cancelling', 19999, '🎧'),
 ('Webcam', '1080p with privacy shutter', 5999, '📷'),
 ('USB-C Hub', '7-in-1 aluminium', 4599, '🔌'),
 ('Laptop Stand', 'Adjustable aluminium', 2999, '💻'),
 ('Desk Lamp', 'LED, dimmable', 2499, '💡');
