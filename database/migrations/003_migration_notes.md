# Migration 003 — Farmer Dairy History
## Relationship Explanation · Data Flow · Reporting Examples · Backend Impact

---

## 1. The Problem This Solves

### What breaks today when a farmer switches dairies

A farmer named Ramesh Patil starts at Amul Dairy, gets 10 visits recorded. Then in March 2026 he switches to Dudhsagar Dairy. A doctor opens `PUT /api/farmers/:id` and changes `dairy_id` from `amul_id` to `dudhsagar_id`.

**What happens in the current system:**

```
farmers table, farmer_id = 7:
  BEFORE: dairy_id = 3  (Amul Dairy)
  AFTER:  dairy_id = 5  (Dudhsagar Dairy)   ← old value permanently gone
```

Now all 10 previous visits for Ramesh show "Dudhsagar Dairy" in reports — because `reports.js` does:

```sql
LEFT JOIN dairies d ON f.dairy_id = d.id   -- reads CURRENT dairy, not historical
```

The doctor tries to collect payment from Amul Dairy for a November 2025 visit. The PDF report shows Dudhsagar Dairy for that visit. The dairy owner disputes it. The doctor has no way to prove where the farmer was enrolled in November 2025.

**This is a real payment dispute scenario** — it directly costs the doctor money.

---

## 2. Relationship Explanation

### The three tables and their roles after Migration 003

```
farmers
  id, name, phone, village
  dairy_id  ────────────────► dairies(id)    ← "WHERE IS THIS FARMER TODAY"
                                               Still the live, mutable pointer.
                                               Updated when farmer switches dairy.

farmer_dairy_history
  farmer_id ────────────────► farmers(id)    ← WHO
  dairy_id  ────────────────► dairies(id)    ← WHERE (nullable: farmer may be independent)
  started_at                                 ← SINCE WHEN
  ended_at  (NULL = current)                 ← UNTIL WHEN

visits
  farmer_id ────────────────► farmers(id)    ← WHOSE VISIT
  dairy_id  ────────────────► dairies(id)    ← SNAPSHOT at visit time (existing)
  visit_date                                 ← WHEN
```

### The key insight: two different answers to "which dairy?"

| Question | Where to look | Why |
|---|---|---|
| "Where does Ramesh sell milk today?" | `farmers.dairy_id` | Single current value |
| "Where was Ramesh selling milk on 15-Nov-2025?" | `farmer_dairy_history` where `started_at <= '2025-11-15' AND (ended_at IS NULL OR ended_at >= '2025-11-15')` | Point-in-time lookup |
| "Which visits should Amul Dairy pay for?" | `visits.dairy_id = amul_id` | Already snapshotted at insert |

### Entity-Relationship

```
┌─────────────┐       ┌────────────────────────────┐       ┌─────────────┐
│   farmers   │       │   farmer_dairy_history     │       │   dairies   │
│─────────────│       │────────────────────────────│       │─────────────│
│ id          │──┐    │ id (UUID PK)               │    ┌──│ id          │
│ name        │  └───►│ farmer_id (FK, CASCADE)    │    │  │ name        │
│ phone       │       │ dairy_id (FK, SET NULL)    │◄───┘  │ phone       │
│ village     │       │ user_id                    │       │ address     │
│ dairy_id    │──────►│ started_at                 │       │ user_id     │
│ user_id     │  ┌───►│ ended_at (NULL = active)   │       └─────────────┘
└─────────────┘  │    │ change_reason              │
                 │    │ source                     │
┌─────────────┐  │    └────────────────────────────┘
│   users     │  │
│─────────────│  │    One farmer has MANY history records
│ id          │──┘    Only ONE record per farmer has ended_at = NULL
└─────────────┘       (enforced by application logic + the EXCLUDE constraint)
```

---

## 3. Data Flow Explanation

### Flow A: New farmer registered (INSERT)

```
Doctor creates farmer via POST /api/farmers
  │
  ├─► INSERT INTO farmers (name, phone, village, dairy_id, user_id)
  │     Returns: new farmer row with id = 42
  │
  └─► INSERT INTO farmer_dairy_history
        (farmer_id=42, dairy_id=3, started_at=TODAY, ended_at=NULL, source='api')
        ← Must be done by the backend route handler (trigger only fires on UPDATE)
```

**Backend change required:** The `POST /api/farmers` handler needs ONE additional INSERT into `farmer_dairy_history` after the farmer is created. This is a safe, additive change to `routes/farmers.js`.

---

### Flow B: Farmer changes dairy (UPDATE) — handled automatically by trigger

```
Doctor edits farmer via PUT /api/farmers/42
  Body: { dairy_id: 5 }   ← changed from 3 (Amul) to 5 (Dudhsagar)
  │
  ├─► UPDATE farmers SET dairy_id=5 WHERE id=42
  │
  └─► [TRIGGER fires: farmers_dairy_change_trigger]
        │
        ├─► UPDATE farmer_dairy_history
        │     SET ended_at = CURRENT_DATE - 1 day
        │     WHERE farmer_id = 42 AND ended_at IS NULL
        │     ← closes the Amul Dairy record
        │
        └─► INSERT INTO farmer_dairy_history
              (farmer_id=42, dairy_id=5, started_at=TODAY, ended_at=NULL, source='trigger')
              ← opens the Dudhsagar Dairy record
```

**No backend code change required for this flow.** The trigger handles it automatically whenever `farmers.dairy_id` is updated.

---

### Flow C: New visit created — what changes in the future

```
Doctor creates visit via POST /api/visits
  Body: { farmer_id: 42, visit_date: '2026-05-10', ... }
  │
  CURRENT CODE:
  ├─► SELECT dairy_id FROM farmers WHERE id=42
  │     Returns: dairy_id = 5 (Dudhsagar, the current one)
  │
  ├─► INSERT INTO visits (..., dairy_id=5, ...)
  │     ← visits.dairy_id is already snapshotted correctly at insert time
  │
  └─► (done)

  FUTURE V2 CODE (more accurate):
  ├─► SELECT * FROM get_farmer_dairy_at(42, '2026-05-10')
  │     Returns: dairy_id at that specific visit_date
  │     ← handles backdated visits correctly
  │
  ├─► INSERT INTO visits (..., dairy_id=<historical_result>, ...)
  └─► (done)
```

The current code is correct for same-day visits. The `get_farmer_dairy_at()` function improves accuracy for backdated visit entries (when a doctor records a visit that happened days ago).

---

### Flow D: Historical PDF report — the core fix

```
CURRENT reports.js query (BROKEN for historical accuracy):
  LEFT JOIN dairies d ON f.dairy_id = d.id
  ← always uses CURRENT dairy, even for 6-month-old visits

CORRECTED V2 query for reports:
  LEFT JOIN farmer_dairy_history fdh
    ON fdh.farmer_id = v.farmer_id
    AND fdh.started_at <= v.visit_date
    AND (fdh.ended_at IS NULL OR fdh.ended_at >= v.visit_date)
  LEFT JOIN dairies d ON d.id = fdh.dairy_id
  ← resolves the dairy that was ACTIVE on the visit date

  OR use the function per-row (simpler but slower for large reports):
  SELECT *, get_farmer_dairy_at(v.farmer_id, v.visit_date) AS historical_dairy
  FROM visits v ...
```

---

### Flow E: Timeline for a single farmer (visual)

```
Ramesh Patil (farmer_id = 7)

TIMELINE:
  Jan 2025 ─────────── Nov 2025 ─────────── Mar 2026 ──────────► today
  |                    |                    |
  Amul Dairy           Amul Dairy           Dudhsagar Dairy
  (started_at=2025-01-10)                   (started_at=2026-03-01)
  (ended_at=2026-02-28) ──────────────────► (ended_at=NULL)

farmer_dairy_history rows for farmer_id=7:
  ┌──────────────────────┬────────────────┬──────────────┬─────────────┐
  │ id                   │ dairy_id (name)│ started_at   │ ended_at    │
  ├──────────────────────┼────────────────┼──────────────┼─────────────┤
  │ a3f8c2d1-...         │ 3 (Amul)       │ 2025-01-10   │ 2026-02-28  │ ← CLOSED
  │ b7e1a4c9-...         │ 5 (Dudhsagar)  │ 2026-03-01   │ NULL        │ ← ACTIVE
  └──────────────────────┴────────────────┴──────────────┴─────────────┘

Query: get_farmer_dairy_at(7, '2025-11-15')  → Amul Dairy ✅
Query: get_farmer_dairy_at(7, '2026-04-20')  → Dudhsagar  ✅
Query: get_farmer_dairy_at(7, CURRENT_DATE)  → Dudhsagar  ✅
```

---

## 4. Future Reporting Examples

### Report A: Correct historical PDF (fix for reports.js)

Replace the current broken join:

```sql
-- CURRENT (broken — uses current dairy for all historical visits):
LEFT JOIN dairies d ON f.dairy_id = d.id

-- CORRECTED (uses the dairy active on the visit date):
LEFT JOIN farmer_dairy_history fdh
  ON  fdh.farmer_id  = v.farmer_id
  AND fdh.started_at <= v.visit_date
  AND (fdh.ended_at IS NULL OR fdh.ended_at >= v.visit_date)
LEFT JOIN dairies d ON d.id = fdh.dairy_id
```

This single join change in `routes/reports.js` fixes the core historical accuracy problem.

---

### Report B: Payment collection report — by dairy, by period

"Show me all PENDING amounts grouped by which dairy owes them, for visits between Jan–Mar 2026"

```sql
SELECT
  d.name                              AS dairy_name,
  d.phone                             AS dairy_phone,
  COUNT(DISTINCT v.farmer_id)         AS farmer_count,
  COUNT(v.id)                         AS visit_count,
  SUM(v.amount)                       AS total_pending
FROM visits v
JOIN farmer_dairy_history fdh
  ON  fdh.farmer_id  = v.farmer_id
  AND fdh.started_at <= v.visit_date
  AND (fdh.ended_at IS NULL OR fdh.ended_at >= v.visit_date)
JOIN dairies d ON d.id = fdh.dairy_id
WHERE
  v.user_id          = $1                    -- doctor's data only
  AND v.payment_status = 'PENDING'
  AND v.visit_date BETWEEN '2026-01-01' AND '2026-03-31'
GROUP BY d.id, d.name, d.phone
ORDER BY total_pending DESC;
```

---

### Report C: Farmer loyalty — how long at each dairy

"Which farmers have been with the same dairy for over 6 months?"

```sql
SELECT
  f.name                              AS farmer_name,
  f.village,
  d.name                              AS dairy_name,
  fdh.started_at,
  AGE(CURRENT_DATE, fdh.started_at)  AS time_at_dairy
FROM farmer_dairy_history fdh
JOIN farmers f  ON f.id  = fdh.farmer_id
JOIN dairies d  ON d.id  = fdh.dairy_id
WHERE
  fdh.user_id     = $1
  AND fdh.ended_at IS NULL                          -- currently active
  AND fdh.started_at < CURRENT_DATE - INTERVAL '6 months'
ORDER BY fdh.started_at ASC;
```

---

### Report D: Dairy churn — farmers who left a specific dairy

"How many farmers left Amul Dairy in the last 3 months, and where did they go?"

```sql
SELECT
  f.name                AS farmer_name,
  f.village,
  fdh_old.ended_at      AS left_amul_on,
  d_new.name            AS moved_to_dairy,
  fdh_new.started_at    AS started_at_new_dairy
FROM farmer_dairy_history fdh_old
JOIN farmers f   ON f.id  = fdh_old.farmer_id
-- Find where each farmer went after leaving
LEFT JOIN farmer_dairy_history fdh_new
  ON  fdh_new.farmer_id  = fdh_old.farmer_id
  AND fdh_new.started_at = fdh_old.ended_at + INTERVAL '1 day'
LEFT JOIN dairies d_new ON d_new.id = fdh_new.dairy_id
WHERE
  fdh_old.dairy_id    = $1   -- Amul Dairy id
  AND fdh_old.ended_at IS NOT NULL
  AND fdh_old.ended_at >= CURRENT_DATE - INTERVAL '3 months'
  AND fdh_old.user_id = $2
ORDER BY fdh_old.ended_at DESC;
```

---

### Report E: Dairy headcount over time (analytics)

"How many active farmers did each dairy have, month by month, in 2025?"

```sql
SELECT
  d.name                                          AS dairy_name,
  DATE_TRUNC('month', gs.month)::date             AS month,
  COUNT(fdh.id)                                   AS farmer_count
FROM dairies d
CROSS JOIN GENERATE_SERIES(
  '2025-01-01'::date,
  '2025-12-01'::date,
  INTERVAL '1 month'
) AS gs(month)
LEFT JOIN farmer_dairy_history fdh
  ON  fdh.dairy_id    = d.id
  AND fdh.started_at <= gs.month::date + INTERVAL '1 month' - INTERVAL '1 day'
  AND (fdh.ended_at IS NULL OR fdh.ended_at >= gs.month::date)
WHERE d.user_id = $1
GROUP BY d.id, d.name, DATE_TRUNC('month', gs.month)
ORDER BY dairy_name, month;
```

---

### Report F: Outstanding balance per dairy (correct, historical)

"How much does each dairy owe me in total pending payments?"

```sql
-- Uses historical dairy (not current) for correct attribution
SELECT
  COALESCE(d.name, 'Independent') AS dairy_name,
  COUNT(v.id)                     AS pending_visits,
  SUM(v.amount)                   AS pending_amount,
  MIN(v.visit_date)               AS oldest_pending_visit
FROM visits v
JOIN farmers f ON f.id = v.farmer_id
LEFT JOIN farmer_dairy_history fdh
  ON  fdh.farmer_id  = v.farmer_id
  AND fdh.started_at <= v.visit_date
  AND (fdh.ended_at IS NULL OR fdh.ended_at >= v.visit_date)
LEFT JOIN dairies d ON d.id = fdh.dairy_id
WHERE
  v.user_id         = $1
  AND v.payment_status = 'PENDING'
GROUP BY d.id, d.name
ORDER BY pending_amount DESC;
```

---

## 5. Migration-Safe Approach

### Why this migration cannot break production

**No existing column is modified.** `farmers.dairy_id` stays exactly as-is. The trigger fires `AFTER UPDATE` — the farmer UPDATE succeeds first, then history is written. If the history INSERT fails for any reason, the trigger error propagates and the entire UPDATE transaction rolls back cleanly. The farmer's data is never in an inconsistent state.

**The backfill is idempotent.** The INSERT in Step 7 uses `WHERE NOT EXISTS (SELECT 1 FROM farmer_dairy_history WHERE farmer_id = f.id)`. Running the migration twice creates no duplicate rows.

**The trigger only fires on `dairy_id` changes.** `AFTER UPDATE OF dairy_id ON farmers` means edits to `name`, `phone`, or `village` do not touch `farmer_dairy_history` at all. No performance impact on non-dairy edits.

**New records are created in a transaction with the farmer UPDATE.** Because the trigger runs inside the same transaction as the `UPDATE farmers`, if anything fails, both the farmer row and the history row are rolled back together. You can never have a history record without the corresponding farmer state.

---

## 6. Backend Files That Need Changes

### Immediate — required for correct history tracking

| File | Change | Risk | Notes |
|---|---|---|---|
| `routes/farmers.js` | `POST /` — add history INSERT after farmer INSERT | LOW | One additive INSERT |
| `routes/farmers.js` | `PUT /:id` — trigger handles the dairy change automatically | NONE | No code change needed |

**The only code change required right now is `POST /api/farmers`:**

```javascript
// In routes/farmers.js — POST handler, after successful farmer INSERT:

const farmer = result.rows[0];

// Record initial dairy enrollment in history
// (trigger only fires on UPDATE, not INSERT — must do this manually)
if (farmer.dairy_id) {
  await pool.query(
    `INSERT INTO farmer_dairy_history
       (farmer_id, dairy_id, user_id, started_at, ended_at, source)
     VALUES ($1, $2, $3, CURRENT_DATE, NULL, 'api')`,
    [farmer.id, farmer.dairy_id, req.userId]
  );
}
// If dairy_id is null (independent farmer), skip — history starts when they join a dairy

res.status(201).json(farmer);
```

That's the entire required backend change for Phase 1 of this migration.

---

### Phase 2 — improve report accuracy (reports.js)

The single join change that fixes the core reporting problem:

```javascript
// In routes/reports.js — replace the existing LEFT JOIN dairies:

// REMOVE this line:
// LEFT JOIN dairies d ON f.dairy_id = d.id

// ADD this in its place:
`LEFT JOIN farmer_dairy_history fdh
   ON  fdh.farmer_id  = v.farmer_id
   AND fdh.started_at <= v.visit_date
   AND (fdh.ended_at IS NULL OR fdh.ended_at >= v.visit_date)
 LEFT JOIN dairies d ON d.id = fdh.dairy_id`
```

**This is the fix that prevents payment disputes.** When a farmer's dairy history exists, the PDF will show the correct dairy for each historical visit date. Without this change, reports show the current dairy for all visits.

---

### Phase 2 — improve visits accuracy (visits.js)

For the visits GET query (the main list), the same join fix applies:

```javascript
// In routes/visits.js — GET / handler

// REMOVE:
// LEFT JOIN dairies d ON f.dairy_id = d.id

// ADD:
`LEFT JOIN farmer_dairy_history fdh
   ON  fdh.farmer_id  = v.farmer_id
   AND fdh.started_at <= v.visit_date
   AND (fdh.ended_at IS NULL OR fdh.ended_at >= v.visit_date)
 LEFT JOIN dairies d ON d.id = fdh.dairy_id`
```

For `today` route: same change. For `POST /visits` (new visit creation), optionally use `get_farmer_dairy_at(farmer_id, visit_date)` instead of `SELECT dairy_id FROM farmers` — this handles backdated visits correctly.

---

### Phase 3 — new history endpoints (optional, new file)

```javascript
// New routes to expose in a future version:

// GET /api/farmers/:id/dairy-history
// → Returns full dairy timeline for a farmer
// → Used for: farmer profile page, audit view, dispute resolution

// GET /api/dairies/:id/farmer-history?from=&to=
// → Returns all farmers enrolled at this dairy during a period
// → Used for: dairy detail page, collection planning
```

---

### Frontend files that need changes (Phase 2)

| File | Change | Notes |
|---|---|---|
| `pages/Farmers.js` | Show dairy history timeline on farmer detail | Additive — new UI section |
| `pages/Report.js` | No change needed — the fix is in `reports.js` backend | PDF accuracy fixed transparently |
| `pages/AddVisit.js` | No change needed — dairy still auto-selected from farmer | Trigger handles the rest |

---

## 7. What "Pre-Migration History is Lost" Means

The backfill creates one history record per farmer with `started_at = farmers.created_at`. This means:

- **For all future dairy changes (from now on):** perfectly tracked via trigger
- **For dairy changes that happened in the past (before this migration):** genuinely unknown — the old `dairy_id` values were overwritten

If you know of specific farmers who changed dairies in the MVP period, you can manually insert their history:

```sql
-- Manually insert known historical change for farmer_id = 7 (Ramesh Patil)
-- First, close the backfill record:
UPDATE farmer_dairy_history
SET ended_at = '2026-02-28'
WHERE farmer_id = 7 AND source = 'backfill';

-- Then insert the true history:
INSERT INTO farmer_dairy_history
  (farmer_id, dairy_id, user_id, started_at, ended_at, source, change_reason)
VALUES
  (7, 3, 1, '2025-01-10', '2026-02-28', 'manual', 'Known from doctor records'),
  (7, 5, 1, '2026-03-01', NULL,          'manual', 'Switched to Dudhsagar in March');
```

---

*Migration 003 — PashuLedger V2*
*© NSN Technologies Pvt. Ltd., 2026 — Internal Engineering Reference*
