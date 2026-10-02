# Invex — Plan

AI-assisted inventory management for a golf course food & beverage department (single location: kitchen + bar), replacing spreadsheets.

## Context & constraints

- **Users:** F&B manager (primary, read/write), GM / accounting (read-only reports)
- **Scale:** < 300 SKUs, one location, a handful of vendors
- **Today:** spreadsheets + vendor portals, no POS integration
- **Budget:** < $25/mo total running cost

## Decisions

| Area | Decision | Why |
|---|---|---|
| Frontend + API | Next.js (App Router) + TypeScript | One codebase, solo-dev friendly |
| Hosting | Vercel | Native Next.js hosting, Vercel Cron |
| Database | Supabase (PostgreSQL) | Relational data, SQL for reports/anomaly stats, auth included, low lock-in |
| ORM / types | Supabase generated types (or Drizzle) | Type-safe queries |
| Auth | Supabase Auth, roles: `manager`, `viewer` | Two roles are enough |
| Consistency (CAP) | **CP**: single Postgres primary, online required to save | One source of truth, no count conflicts. Offline shows "reconnect to save" |
| Workload | **Write-optimized**: inventory changes (adjustments, receipts, counts, deletes) outnumber reads | Drives the ledger design below |
| Storage model | **Append-only inventory ledger** (`inventory_transactions`); on-hand = sum of ledger | Writes are cheap single-row inserts with no row contention and a full audit trail. Mistakes get reversing entries, never destructive edits |
| Deletes | Soft delete (`archived_at`) for items/vendors; ledger rows are never deleted | Keeps history and COGS reports correct |
| Depletion model | Periodic counts + ad-hoc adjustments (waste, spoilage, comps, corrections) written to the ledger | Matches current workflow, no POS needed |
| AI assistant | Claude **Sonnet 5.5** with tool calling, read-mostly | Writes (e.g. draft PO) require explicit user confirmation |
| Anomaly detection | Deterministic rules + stats in SQL; LLM writes the plain-English explanation | Cheap, auditable, consistent |
| Notifications | SMS via Twilio | Most noticeable for a busy manager |

## Data model (initial)

Implemented in `supabase/migrations/20260929000000_init.sql` (tested by `npm run db:test`).

```
vendors          (id, name, contact, phone, email, portal_url, order_days, lead_time_days)
categories       (id, name)                         -- produce, dairy, liquor, beer, wine, dry goods...
items            (id, name, sku, category_id, vendor_id, unit, pack_size, unit_cost,
                  par_level, reorder_point, storage_area, archived_at)
inventory_transactions                              -- append-only ledger, the write hot path
                 (id, item_id, type: receipt|adjustment|waste|count_correction|reversal,
                  qty_delta, unit_cost, reason, source_id, reverses_id, created_by, created_at)
                  -- index: (item_id, created_at) only; keep indexes minimal for write speed
counts           (id, counted_at, counted_by, status: draft|submitted, notes)
count_lines      (count_id, item_id, quantity)
purchase_orders  (id, vendor_id, status: draft|placed|received|cancelled,
                  placed_at, expected_at, received_at, total_cost)
po_lines         (po_id, item_id, qty_ordered, qty_received, unit_cost)
anomalies        (id, type, item_id, count_id, severity, details jsonb, explanation, created_at, resolved_at)
notifications    (id, type, channel, to, body, sent_at, status)  -- SMS log / dedupe
```

Derived via SQL views:
- `v_on_hand`: sum of ledger `qty_delta` per item. Submitting a count writes a
  `count_correction` (counted − expected), so the sum always equals the latest count plus
  changes since. Add a snapshot table only if reads ever get slow; at < 300 SKUs they won't
- `v_price_history`: receipt costs from the ledger (no separate table)
- `v_usage_by_count`: usage per item per count interval (waste + comps + adjustments + unexplained loss)
- `v_cogs`: cost of usage per period (for the GM/accounting view)

## Features by phase

### MVP
1. **Item catalog**: CRUD for items/vendors/categories, par levels
2. **Quick adjustments**: fast "log waste / spoilage / comp / correction" form (item, qty, reason) that writes to the ledger
3. **Stock counts**: count sheet grouped by storage area. Saves as a draft while in progress and is locked on submit (CP: submit needs a connection)
4. **Incoming order tracking**: create POs with expected date, mark received (full/partial), updates on-hand and price history
5. **Spreadsheet import**: upload CSV/XLSX, map columns, preview, commit (items + an opening count)
6. **SMS notifications** (Vercel Cron, daily):
   - Delivery due today/tomorrow
   - Weekly count reminder
   - Anomaly flagged (after count submit)
7. **Anomaly detection**, in two modes:
   - Rule of thumb: check live only what is certain at the moment of the write. Live checks see
     only logged events (data-entry and vendor problems); count-time checks see real usage
     (over-pouring, theft, unrecorded waste)
   - **Live** (on every ledger write, via an `AFTER INSERT` trigger on `inventory_transactions`):
     - Vendor price change > X% vs last receipt (checked when a delivery is received)
     - Negative on-hand: flagged **low** severity (often temporary, e.g. delivery on the dock but
       not logged yet). Escalated to high only if still negative at the next count
     - Oversized single entry: waste/spoilage/comp/adjustment > X% of on-hand or > N× that item's typical entry
     - Burst: unusually many manual entries for one item in a short window (e.g. 3+ in an hour)
   - **On count submit** (needs a full count interval to compare):
     - Usage z-score vs trailing 6–8 counts (e.g. |z| > 2)
     - Negative usage (count went up without a receipt)
     - Escalate open negative on-hand flags that the count didn't resolve
   - Write path stays fast: the trigger only does indexed lookups for that one item and inserts
     an `anomalies` row in the same transaction (CP: the flag can't be lost). The slow parts,
     Claude's 1–2 sentence explanation and the SMS, run afterwards (right after the server action
     returns, with a cron sweep picking up any anomaly still missing an explanation)
   - **Fail-safe trigger:** checks run inside an exception block, so a bug in detection logs
     an error and lets the write through. It never blocks a manager from recording stock
   - Noise control: **high** severity texts immediately; medium/low show in-app and in the
     count-submit summary. One open anomaly per item + type (dedupe), thresholds in a settings table
8. **AI assistant** (chat panel), tools:
   - `getStock(item | category)`, `getUsage(item, range)`, `listOrders(status, range)`,
     `getAnomalies(range)`, `getVendor(name)`
   - `draftPurchaseOrder(vendor, lines)`: creates a **draft** only, user confirms in UI
9. **Reports** (viewer role): on-hand value, usage/COGS by period, variance

### Phase 2
- Low-stock alerts (on hand < reorder point → SMS / digest)
- Suggested order quantities (usage rate × lead time + par)
- Invoice photo OCR to receive POs
- Local-storage backup of in-progress counts (Wi-Fi drops mid-count)

### Later
- POS integration for near-real-time depletion
- Demand forecasting (tee sheet / events / seasonality)

## Architecture

```
Browser (Next.js UI) ──► Next.js route handlers / server actions (Vercel)
                             ├── Supabase Postgres (data, views, RLS)
                             ├── Supabase Auth
                             ├── Claude API (assistant + anomaly explanations)
                             └── Twilio (SMS)
Vercel Cron (daily) ──► /api/cron/daily  → delivery reminders, count reminder,
                                          and a DB touch (keeps free Supabase project from pausing)
```

- **Write path:** every inventory change is one server action → one transaction → a ledger
  INSERT (plus the PO/count row it belongs to). The UI updates optimistically, and a failed
  write rolls back and shows an error (CP: no silent local-only writes)
- **Edits/deletes of inventory** = reversal entry + new entry, so the ledger stays immutable
- Row Level Security: `viewer` role gets SELECT only
- Assistant tools run server-side with the user's session, so the model can never bypass RLS
- `notifications` table dedupes so a cron retry never double-texts

## Cost estimate (monthly, rough; verify current pricing)

| Item | Est. |
|---|---|
| Vercel Hobby | $0 (check whether commercial use requires Pro) |
| Supabase Free | $0 (pauses after inactivity; daily cron mitigates) |
| Claude Sonnet 5.5 | Low single-digit $ at a few chats/day + anomaly write-ups; use prompt caching on the system prompt/tool defs |
| Twilio SMS | Phone number ~$1–2 + per-message fees + US A2P 10DLC or toll-free verification fees |

**Risks to the budget:** Vercel Hobby is for non-commercial use, so a club deployment may need Pro ($20/mo). Together with Twilio registration fees, that could exceed $25. Options: confirm with the club, or fall back to email for low-priority notices.

## Open questions

- Who receives SMS: manager only, or GM too?
- Count cadence: weekly or biweekly? Which day?
- Units: do items get counted in different units than they're ordered in (e.g. order by case, count by bottle)? This affects the schema (`pack_size` conversion)
- Can we get a sample of the current spreadsheet to design the import mapping?
