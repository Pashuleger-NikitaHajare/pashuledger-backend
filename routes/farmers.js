const router = require('express').Router();
const { body, validationResult } = require('express-validator');
const { pool } = require('../db');
const auth = require('../middleware/auth');

// FIX #7: Mobile validation
const phoneValidation = body('phone')
  .optional({ nullable: true, checkFalsy: true })
  .matches(/^\d{10}$/).withMessage('Phone must be exactly 10 digits');

// Get all farmers
router.get('/', auth, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT f.*, d.name AS dairy_name,
       COALESCE(SUM(CASE WHEN v.payment_status='PENDING' THEN v.amount ELSE 0 END),0)::numeric AS pending_amount
       FROM farmers f
       LEFT JOIN dairies d ON f.dairy_id = d.id
       LEFT JOIN visits v ON v.farmer_id = f.id
       WHERE f.user_id=$1
       GROUP BY f.id, d.name
       ORDER BY f.name`,
      [req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #6 & #11: Add farmer with duplicate check
router.post('/', auth, [
  body('name').trim().notEmpty().withMessage('Farmer name is required'),
  phoneValidation
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { name, phone, village, dairy_id } = req.body;
  try {
    // FIX #11: Duplicate validation - name + phone + village
    const dup = await pool.query(
      `SELECT id FROM farmers WHERE user_id=$1 AND LOWER(TRIM(name))=LOWER(TRIM($2))
       AND COALESCE(LOWER(TRIM(phone)),'') = COALESCE(LOWER(TRIM($3)),'')
       AND COALESCE(LOWER(TRIM(village)),'') = COALESCE(LOWER(TRIM($4)),'')`,
      [req.userId, name, phone || '', village || '']
    );
    if (dup.rows.length) {
      return res.status(409).json({ error: 'A farmer with the same name, phone, and village already exists.' });
    }

    const result = await pool.query(
      'INSERT INTO farmers(name,phone,village,dairy_id,user_id) VALUES($1,$2,$3,$4,$5) RETURNING *',
      [name, phone || null, village || null, dairy_id || null, req.userId]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #6: Update farmer (edit functionality)
router.put('/:id', auth, [
  body('name').trim().notEmpty().withMessage('Farmer name is required'),
  phoneValidation
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { name, phone, village, dairy_id } = req.body;
  try {
    // FIX #11: Duplicate check excluding self
    const dup = await pool.query(
      `SELECT id FROM farmers WHERE user_id=$1 AND id != $5
       AND LOWER(TRIM(name))=LOWER(TRIM($2))
       AND COALESCE(LOWER(TRIM(phone)),'') = COALESCE(LOWER(TRIM($3)),'')
       AND COALESCE(LOWER(TRIM(village)),'') = COALESCE(LOWER(TRIM($4)),'')`,
      [req.userId, name, phone || '', village || '', req.params.id]
    );
    if (dup.rows.length) {
      return res.status(409).json({ error: 'A farmer with the same name, phone, and village already exists.' });
    }

    const result = await pool.query(
      'UPDATE farmers SET name=$1,phone=$2,village=$3,dairy_id=$4 WHERE id=$5 AND user_id=$6 RETURNING *',
      [name, phone || null, village || null, dairy_id || null, req.params.id, req.userId]
    );
    if (!result.rows.length) return res.status(404).json({ error: 'Farmer not found' });
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// Delete farmer
router.delete('/:id', auth, async (req, res) => {
  try {
    await pool.query('DELETE FROM farmers WHERE id=$1 AND user_id=$2', [req.params.id, req.userId]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

module.exports = router;
