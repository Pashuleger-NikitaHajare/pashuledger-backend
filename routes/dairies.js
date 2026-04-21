const router = require('express').Router();
const { body, validationResult } = require('express-validator');
const { pool } = require('../db');
const auth = require('../middleware/auth');

// FIX #7: Mobile validation helper
const phoneValidation = body('phone')
  .optional({ nullable: true, checkFalsy: true })
  .matches(/^\d{10}$/).withMessage('Phone must be exactly 10 digits');

// Get all dairies for user
router.get('/', auth, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT d.*, COUNT(f.id)::int AS farmer_count
       FROM dairies d
       LEFT JOIN farmers f ON f.dairy_id = d.id
       WHERE d.user_id=$1
       GROUP BY d.id
       ORDER BY d.name`,
      [req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #6 & #10: Add dairy with duplicate check
router.post('/', auth, [
  body('name').trim().notEmpty().withMessage('Dairy name is required'),
  phoneValidation
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { name, phone, address } = req.body;
  try {
    // FIX #10: Duplicate validation - name + phone + address (village)
    const dup = await pool.query(
      `SELECT id FROM dairies WHERE user_id=$1 AND LOWER(TRIM(name))=LOWER(TRIM($2))
       AND COALESCE(LOWER(TRIM(phone)),'') = COALESCE(LOWER(TRIM($3)),'')
       AND COALESCE(LOWER(TRIM(address)),'') = COALESCE(LOWER(TRIM($4)),'')`,
      [req.userId, name, phone || '', address || '']
    );
    if (dup.rows.length) {
      return res.status(409).json({ error: 'A dairy with the same name, phone, and village already exists.' });
    }

    const result = await pool.query(
      'INSERT INTO dairies(name,phone,address,user_id) VALUES($1,$2,$3,$4) RETURNING *',
      [name, phone || null, address || null, req.userId]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #6: Update dairy (edit functionality)
router.put('/:id', auth, [
  body('name').trim().notEmpty().withMessage('Dairy name is required'),
  phoneValidation
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { name, phone, address } = req.body;
  try {
    // FIX #10: Duplicate check excluding self
    const dup = await pool.query(
      `SELECT id FROM dairies WHERE user_id=$1 AND id != $5
       AND LOWER(TRIM(name))=LOWER(TRIM($2))
       AND COALESCE(LOWER(TRIM(phone)),'') = COALESCE(LOWER(TRIM($3)),'')
       AND COALESCE(LOWER(TRIM(address)),'') = COALESCE(LOWER(TRIM($4)),'')`,
      [req.userId, name, phone || '', address || '', req.params.id]
    );
    if (dup.rows.length) {
      return res.status(409).json({ error: 'A dairy with the same name, phone, and village already exists.' });
    }

    const result = await pool.query(
      'UPDATE dairies SET name=$1,phone=$2,address=$3 WHERE id=$4 AND user_id=$5 RETURNING *',
      [name, phone || null, address || null, req.params.id, req.userId]
    );
    if (!result.rows.length) return res.status(404).json({ error: 'Dairy not found' });
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

// Delete dairy
router.delete('/:id', auth, async (req, res) => {
  try {
    await pool.query('DELETE FROM dairies WHERE id=$1 AND user_id=$2', [req.params.id, req.userId]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

module.exports = router;
