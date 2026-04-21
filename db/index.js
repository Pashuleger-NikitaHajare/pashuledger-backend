const { Pool } = require('pg');
require('dotenv').config();

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

const initDB = async () => {
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        mobile VARCHAR(15) UNIQUE NOT NULL,
        password TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS dairies (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        phone VARCHAR(15),
        address TEXT,
        user_id INT REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS farmers (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        phone VARCHAR(15),
        village VARCHAR(100),
        dairy_id INT REFERENCES dairies(id) ON DELETE SET NULL,
        user_id INT REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS visits (
        id SERIAL PRIMARY KEY,
        farmer_id INT REFERENCES farmers(id) ON DELETE CASCADE,
        dairy_id INT REFERENCES dairies(id) ON DELETE SET NULL,
        visit_date DATE NOT NULL,
        animals_count INT NOT NULL DEFAULT 1,
        treatment TEXT NOT NULL,
        medicines TEXT,
        amount DECIMAL(10,2) NOT NULL DEFAULT 0,
        payment_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
        notes TEXT,
        user_id INT REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_visits_user_date ON visits(user_id, visit_date);
      CREATE INDEX IF NOT EXISTS idx_visits_farmer ON visits(farmer_id);
      CREATE INDEX IF NOT EXISTS idx_farmers_dairy ON farmers(dairy_id);
      CREATE INDEX IF NOT EXISTS idx_dairies_user ON dairies(user_id);
    `);
    console.log('✅ Database initialized successfully');
  } finally {
    client.release();
  }
};

module.exports = { pool, initDB };
