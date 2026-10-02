@AGENTS.md

# Invex

See PLAN.md for product decisions.

- Stack: Next.js 16 (App Router, `src/proxy.ts` not middleware) + Supabase Postgres. Supabase clients live in `src/lib/supabase/`; `admin.ts` bypasses RLS and is for cron/server jobs only.
- Stock is an append-only ledger (`inventory_transactions`). Never update or delete ledger rows; fix mistakes with `reverse_transaction`. On-hand is `v_on_hand`.
- supabase-js can't run multi-statement transactions, so writes that touch several rows (count submit, PO receive, reversal) are Postgres functions called via `rpc`.
- Schema changes: add a new file in `supabase/migrations/`, extend `supabase/tests/schema_test.sql`, run `npm run db:test` (plain local Postgres 17, no Docker).
