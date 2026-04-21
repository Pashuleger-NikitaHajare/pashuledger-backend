const router = require('express').Router();
const { body, validationResult } = require('express-validator');
const { pool } = require('../db');
const auth = require('../middleware/auth');

// Get visits with filters
router.get('/', auth, async (req, res) => {
  const { from, to, farmer_id, dairy_id, status } = req.query;
  let conditions = ['v.user_id=$1'];
  let params = [req.userId];
  let idx = 2;

  if (from) { conditions.push(`v.visit_date >= $${idx++}`); params.push(from); }
  if (to) { conditions.push(`v.visit_date <= $${idx++}`); params.push(to); }
  if (farmer_id) { conditions.push(`v.farmer_id = $${idx++}`); params.push(farmer_id); }
  if (dairy_id) { conditions.push(`f.dairy_id = $${idx++}`); params.push(dairy_id); }
  if (status) { conditions.push(`v.payment_status = $${idx++}`); params.push(status); }

  try {
    const result = await pool.query(
      `SELECT v.*, f.name AS farmer_name, f.phone AS farmer_phone, f.village,
              d.name AS dairy_name
       FROM visits v
       JOIN farmers f ON v.farmer_id = f.id
       LEFT JOIN dairies d ON f.dairy_id = d.id
       WHERE ${conditions.join(' AND ')}
       ORDER BY v.visit_date DESC, v.created_at DESC`,
      params
    );
    res.json(result.rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// Today's visits
router.get('/today', auth, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT v.*, f.name AS farmer_name, d.name AS dairy_name
       FROM visits v
       JOIN farmers f ON v.farmer_id = f.id
       LEFT JOIN dairies d ON f.dairy_id = d.id
       WHERE v.user_id=$1 AND v.visit_date = CURRENT_DATE
       ORDER BY v.created_at DESC`,
      [req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// Dashboard summary
router.get('/summary', auth, async (req, res) => {
  try {
    const [earnings, pending, farmers, todayCount] = await Promise.all([
      pool.query(
        `SELECT COALESCE(SUM(amount),0) AS total FROM visits
         WHERE user_id=$1 AND visit_date >= CURRENT_DATE - INTERVAL '15 days'`,
        [req.userId]
      ),
      pool.query(
        `SELECT COALESCE(SUM(amount),0) AS total FROM visits
         WHERE user_id=$1 AND payment_status='PENDING'`,
        [req.userId]
      ),
      pool.query('SELECT COUNT(*)::int AS total FROM farmers WHERE user_id=$1', [req.userId]),
      pool.query(
        'SELECT COUNT(*)::int AS total FROM visits WHERE user_id=$1 AND visit_date=CURRENT_DATE',
        [req.userId]
      )
    ]);
    res.json({
      earnings_15d: parseFloat(earnings.rows[0].total),
      pending_amount: parseFloat(pending.rows[0].total),
      total_farmers: farmers.rows[0].total,
      today_visits: todayCount.rows[0].total
    });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #8 & #14: Add visit with amount + date validations
router.post('/', auth, [
  body('farmer_id').notEmpty().withMessage('Farmer is required'),
  body('visit_date')
    .isDate().withMessage('Valid date required')
    .custom(val => {
      const today = new Date().toISOString().split('T')[0];
      if (val > today) throw new Error('Visit date cannot be in the future');
      return true;
    }),
  body('treatment').notEmpty().withMessage('Treatment is required'),
  body('amount')
    .isFloat({ min: 0 }).withMessage('Amount must be a non-negative number')
    .custom(val => {
      if (String(val).includes('-')) throw new Error('Amount cannot be negative');
      return true;
    })
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { farmer_id, visit_date, animals_count, treatment, medicines, amount, payment_status, notes } = req.body;
  try {
    const farmerRes = await pool.query('SELECT dairy_id FROM farmers WHERE id=$1 AND user_id=$2', [farmer_id, req.userId]);
    if (!farmerRes.rows.length) return res.status(404).json({ error: 'Farmer not found' });

    const result = await pool.query(
      `INSERT INTO visits(farmer_id,dairy_id,visit_date,animals_count,treatment,medicines,amount,payment_status,notes,user_id)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *`,
      [farmer_id, farmerRes.rows[0].dairy_id, visit_date, animals_count || 1,
       treatment, medicines || null, amount, payment_status || 'PENDING', notes || null, req.userId]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #6: Update visit (edit functionality)
router.put('/:id', auth, [
  body('farmer_id').notEmpty().withMessage('Farmer is required'),
  body('visit_date')
    .isDate().withMessage('Valid date required')
    .custom(val => {
      const today = new Date().toISOString().split('T')[0];
      if (val > today) throw new Error('Visit date cannot be in the future');
      return true;
    }),
  body('treatment').notEmpty().withMessage('Treatment is required'),
  body('amount').isFloat({ min: 0 }).withMessage('Amount must be a non-negative number')
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { farmer_id, visit_date, animals_count, treatment, medicines, amount, payment_status, notes } = req.body;
  try {
    const farmerRes = await pool.query('SELECT dairy_id FROM farmers WHERE id=$1 AND user_id=$2', [farmer_id, req.userId]);
    if (!farmerRes.rows.length) return res.status(404).json({ error: 'Farmer not found' });

    const result = await pool.query(
      `UPDATE visits SET farmer_id=$1, dairy_id=$2, visit_date=$3, animals_count=$4,
       treatment=$5, medicines=$6, amount=$7, payment_status=$8, notes=$9
       WHERE id=$10 AND user_id=$11 RETURNING *`,
      [farmer_id, farmerRes.rows[0].dairy_id, visit_date, animals_count || 1,
       treatment, medicines || null, amount, payment_status || 'PENDING', notes || null,
       req.params.id, req.userId]
    );
    if (!result.rows.length) return res.status(404).json({ error: 'Visit not found' });
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// Update payment status
router.patch('/:id/payment', auth, async (req, res) => {
  const { status } = req.body;
  if (!['PAID', 'PENDING'].includes(status)) return res.status(400).json({ error: 'Invalid status' });
  try {
    const result = await pool.query(
      'UPDATE visits SET payment_status=$1 WHERE id=$2 AND user_id=$3 RETURNING *',
      [status, req.params.id, req.userId]
    );
    if (!result.rows.length) return res.status(404).json({ error: 'Visit not found' });
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// Delete visit
router.delete('/:id', auth, async (req, res) => {
  try {
    await pool.query('DELETE FROM visits WHERE id=$1 AND user_id=$2', [req.params.id, req.userId]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

module.exports = router;
