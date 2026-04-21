const router = require('express').Router();
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { body, validationResult } = require('express-validator');
const { pool } = require('../db');

// FIX #1: Register - does NOT return token anymore; frontend redirects to login
router.post('/register', [
  body('name').trim().notEmpty().withMessage('Name is required'),
  body('mobile').matches(/^\d{10}$/).withMessage('Enter valid 10-digit mobile number'),
  body('password').isLength({ min: 6 }).withMessage('Password must be at least 6 characters')
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { name, mobile, password } = req.body;
  try {
    const existing = await pool.query('SELECT id FROM users WHERE mobile=$1', [mobile]);
    if (existing.rows.length) return res.status(409).json({ error: 'Mobile number already registered' });

    const hashed = await bcrypt.hash(password, 12);
    await pool.query(
      'INSERT INTO users(name,mobile,password) VALUES($1,$2,$3)',
      [name, mobile, hashed]
    );
    // Return success without token - user must login
    res.status(201).json({ success: true, message: 'Registration successful. Please login.' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// Login
router.post('/login', [
  body('mobile').matches(/^\d{10}$/).withMessage('Enter valid 10-digit mobile number'),
  body('password').notEmpty().withMessage('Password is required')
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { mobile, password } = req.body;
  try {
    const result = await pool.query('SELECT * FROM users WHERE mobile=$1', [mobile]);
    if (!result.rows.length) return res.status(401).json({ error: 'Mobile number not registered' });

    const user = result.rows[0];
    const valid = await bcrypt.compare(password, user.password);
    if (!valid) return res.status(401).json({ error: 'Incorrect password' });

    const token = jwt.sign({ id: user.id }, process.env.JWT_SECRET, { expiresIn: '30d' });
    res.json({ token, user: { id: user.id, name: user.name, mobile: user.mobile } });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #2: Forgot password - verify mobile exists, then allow reset
router.post('/forgot-password', [
  body('mobile').matches(/^\d{10}$/).withMessage('Enter valid 10-digit mobile number')
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { mobile } = req.body;
  try {
    const result = await pool.query('SELECT id, name FROM users WHERE mobile=$1', [mobile]);
    if (!result.rows.length) return res.status(404).json({ error: 'Mobile number not registered' });

    // In production: send OTP via SMS. Here we return a reset token valid 15 min.
    const resetToken = jwt.sign({ id: result.rows[0].id, type: 'reset' }, process.env.JWT_SECRET, { expiresIn: '15m' });
    res.json({ success: true, resetToken, message: 'Verified. You can now reset your password.' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// FIX #2: Reset password using reset token
router.post('/reset-password', [
  body('resetToken').notEmpty().withMessage('Reset token is required'),
  body('newPassword').isLength({ min: 6 }).withMessage('Password must be at least 6 characters')
], async (req, res) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });

  const { resetToken, newPassword } = req.body;
  try {
    const decoded = jwt.verify(resetToken, process.env.JWT_SECRET);
    if (decoded.type !== 'reset') return res.status(400).json({ error: 'Invalid reset token' });

    const hashed = await bcrypt.hash(newPassword, 12);
    await pool.query('UPDATE users SET password=$1 WHERE id=$2', [hashed, decoded.id]);
    res.json({ success: true, message: 'Password reset successfully. Please login.' });
  } catch (err) {
    if (err.name === 'TokenExpiredError') return res.status(400).json({ error: 'Reset token expired. Try again.' });
    res.status(400).json({ error: 'Invalid reset token' });
  }
});

module.exports = router;
