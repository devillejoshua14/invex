-- Invex initial schema
--
-- Design notes:
--   * Write-optimized: every stock change is a single INSERT into the append-only
--     inventory_transactions ledger. On-hand = SUM(qty_delta) per item.
--   * Ledger rows are immutable. Mistakes are fixed with a reversal entry.
--   * Items and vendors are soft-deleted (archived_at) so history stays intact.
--   * Multi-row writes that must be atomic (count submit, PO receive, reversal)
--     are Postgres functions, since supabase-js cannot run client-side transactions.
--   * Quantities in the ledger are always in an item's count_unit (e.g. bottle).
--     Purchase orders are in order units (e.g. case) and converted on receipt.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type public.user_role as enum ('manager', 'viewer');

create type public.txn_type as enum (
  'opening',           -- initial stock from spreadsheet import
  'receipt',           -- delivery received against a PO
  'adjustment',        -- manual +/- with a reason
  'waste',
  'spoilage',
  'comp',
  'count_correction',  -- counted - expected, written on count submit (usage/variance)
  'reversal'           -- negates a previous entry
);

create type public.count_status as enum ('draft', 'submitted');

create type public.po_status as enum ('draft', 'placed', 'partially_received', 'received', 'cancelled');

create type public.anomaly_type as enum ('usage_spike', 'negative_usage', 'price_change');

create type public.anomaly_severity as enum ('low', 'medium', 'high');

create type public.notification_status as enum ('pending', 'sent', 'failed');

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text,
  phone       text,                      -- E.164, for SMS
  role        public.user_role not null default 'viewer',
  sms_opt_in  boolean not null default false,
  created_at  timestamptz not null default now()
);

-- New auth users get a viewer profile. Promote the first manager manually:
--   update public.profiles set role = 'manager' where id = '<uuid>';
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.is_manager()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'manager'
  );
$$;

-- ---------------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------------

create table public.vendors (
  id              bigint generated always as identity primary key,
  name            text not null,
  contact_name    text,
  phone           text,
  email           text,
  portal_url      text,
  order_days      smallint[] not null default '{}',  -- 0 = Sunday ... 6 = Saturday
  lead_time_days  integer not null default 1 check (lead_time_days >= 0),
  notes           text,
  archived_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create unique index vendors_name_active_key on public.vendors (lower(name)) where archived_at is null;

create table public.categories (
  id    bigint generated always as identity primary key,
  name  text not null unique
);

create table public.items (
  id                    bigint generated always as identity primary key,
  name                  text not null,
  sku                   text,
  category_id           bigint references public.categories (id),
  vendor_id             bigint references public.vendors (id),
  count_unit            text not null default 'each',   -- unit on the shelf, e.g. bottle
  order_unit            text not null default 'each',   -- unit on the PO, e.g. case
  units_per_order_unit  numeric(10, 3) not null default 1 check (units_per_order_unit > 0),
  unit_cost             numeric(12, 4) check (unit_cost >= 0),  -- per count_unit, latest known
  par_level             numeric(12, 3) check (par_level >= 0),
  reorder_point         numeric(12, 3) check (reorder_point >= 0),
  storage_area          text,                           -- walk-in, freezer, dry storage, bar...
  archived_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create unique index items_name_active_key on public.items (lower(name)) where archived_at is null;
create index items_vendor_id_idx on public.items (vendor_id);
create index items_category_id_idx on public.items (category_id);

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger vendors_set_updated_at before update on public.vendors
  for each row execute function public.set_updated_at();
create trigger items_set_updated_at before update on public.items
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Counts
-- ---------------------------------------------------------------------------

create table public.counts (
  id            bigint generated always as identity primary key,
  status        public.count_status not null default 'draft',
  started_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  counted_by    uuid references public.profiles (id) default auth.uid(),
  notes         text,
  check ((status = 'submitted') = (submitted_at is not null))
);

create table public.count_lines (
  count_id      bigint not null references public.counts (id) on delete cascade,
  item_id       bigint not null references public.items (id),
  quantity      numeric(12, 3) not null check (quantity >= 0),
  expected_qty  numeric(12, 3),   -- ledger on-hand at submit time
  primary key (count_id, item_id)
);

-- ---------------------------------------------------------------------------
-- Purchase orders
-- ---------------------------------------------------------------------------

create table public.purchase_orders (
  id           bigint generated always as identity primary key,
  vendor_id    bigint not null references public.vendors (id),
  status       public.po_status not null default 'draft',
  placed_at    timestamptz,
  expected_at  date,
  received_at  timestamptz,
  notes        text,
  created_by   uuid references public.profiles (id) default auth.uid(),
  created_at   timestamptz not null default now()
);

create index purchase_orders_open_expected_idx on public.purchase_orders (expected_at)
  where status in ('placed', 'partially_received');

create table public.po_lines (
  id                    bigint generated always as identity primary key,
  po_id                 bigint not null references public.purchase_orders (id) on delete cascade,
  item_id               bigint not null references public.items (id),
  qty_ordered           numeric(12, 3) not null check (qty_ordered > 0),   -- order units
  qty_received          numeric(12, 3) not null default 0 check (qty_received >= 0),
  unit_cost             numeric(12, 4) check (unit_cost >= 0),             -- per order unit
  units_per_order_unit  numeric(10, 3) not null check (units_per_order_unit > 0),  -- snapshot
  unique (po_id, item_id)
);

-- Snapshot the item's conversion factor so later catalog edits don't rewrite history.
create function public.po_lines_snapshot_units()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.units_per_order_unit is null then
    select i.units_per_order_unit into new.units_per_order_unit
    from public.items i where i.id = new.item_id;
  end if;
  return new;
end;
$$;

create trigger po_lines_snapshot_units before insert on public.po_lines
  for each row execute function public.po_lines_snapshot_units();

-- ---------------------------------------------------------------------------
-- Ledger (the write hot path)
-- ---------------------------------------------------------------------------

create table public.inventory_transactions (
  id           bigint generated always as identity primary key,
  item_id      bigint not null references public.items (id),
  type         public.txn_type not null,
  qty_delta    numeric(12, 3) not null check (qty_delta <> 0),  -- count units
  unit_cost    numeric(12, 4) check (unit_cost >= 0),           -- per count unit, when known
  reason       text,
  count_id     bigint references public.counts (id),
  po_line_id   bigint references public.po_lines (id),
  reverses_id  bigint unique references public.inventory_transactions (id),
  created_by   uuid references public.profiles (id) default auth.uid(),
  created_at   timestamptz not null default now(),
  check ((type = 'reversal') = (reverses_id is not null)),
  check (type <> 'receipt' or po_line_id is not null),
  check (type <> 'count_correction' or count_id is not null)
);

-- Deliberately minimal indexing to keep inserts cheap.
create index inventory_transactions_item_created_idx
  on public.inventory_transactions (item_id, created_at);

create function public.prevent_ledger_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'inventory_transactions is append-only; insert a reversal instead';
end;
$$;

create trigger inventory_transactions_immutable
  before update or delete on public.inventory_transactions
  for each row execute function public.prevent_ledger_mutation();

-- ---------------------------------------------------------------------------
-- Anomalies & notifications
-- ---------------------------------------------------------------------------

create table public.anomalies (
  id           bigint generated always as identity primary key,
  type         public.anomaly_type not null,
  severity     public.anomaly_severity not null default 'medium',
  item_id      bigint references public.items (id),
  count_id     bigint references public.counts (id),
  po_id        bigint references public.purchase_orders (id),
  details      jsonb not null default '{}',
  explanation  text,   -- plain-English summary written by the LLM
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  resolved_by  uuid references public.profiles (id)
);

create index anomalies_unresolved_idx on public.anomalies (created_at) where resolved_at is null;

create table public.notifications (
  id          bigint generated always as identity primary key,
  type        text not null,             -- delivery_due, count_reminder, anomaly
  channel     text not null default 'sms',
  recipient   text not null,
  body        text not null,
  dedupe_key  text not null unique,      -- e.g. delivery_due:po:42:2026-10-01:+15551234567
  status      public.notification_status not null default 'pending',
  error       text,
  sent_at     timestamptz,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Views (security_invoker so RLS of the caller applies)
-- ---------------------------------------------------------------------------

create view public.v_on_hand with (security_invoker = true) as
select
  i.id                                   as item_id,
  i.name,
  i.category_id,
  i.vendor_id,
  i.count_unit,
  i.storage_area,
  i.par_level,
  i.reorder_point,
  coalesce(sum(t.qty_delta), 0)          as on_hand,
  coalesce(sum(t.qty_delta), 0) * coalesce(i.unit_cost, 0) as on_hand_value
from public.items i
left join public.inventory_transactions t on t.item_id = i.id
where i.archived_at is null
group by i.id;

-- Receipt costs from the ledger; this is the price history.
create view public.v_price_history with (security_invoker = true) as
select
  t.item_id,
  po.vendor_id,
  t.unit_cost,
  t.created_at as effective_at,
  po.id        as po_id
from public.inventory_transactions t
join public.po_lines pl on pl.id = t.po_line_id
join public.purchase_orders po on po.id = pl.po_id
where t.type = 'receipt' and t.unit_cost is not null
  and not exists (select 1 from public.inventory_transactions r where r.reverses_id = t.id);

-- Usage per item per count interval: everything that left the shelf except receipts.
-- Positive number = units consumed.
create view public.v_usage_by_count with (security_invoker = true) as
with submitted as (
  select id, submitted_at,
         lag(submitted_at) over (order by submitted_at) as prev_submitted_at
  from public.counts
  where status = 'submitted'
)
select
  s.id                     as count_id,
  s.prev_submitted_at      as period_start,
  s.submitted_at           as period_end,
  t.item_id,
  -sum(t.qty_delta)        as usage_qty,
  -sum(t.qty_delta * coalesce(t.unit_cost, i.unit_cost, 0)) as usage_cost
from submitted s
join public.inventory_transactions t
  on t.created_at <= s.submitted_at
 and (s.prev_submitted_at is null or t.created_at > s.prev_submitted_at)
join public.items i on i.id = t.item_id
where t.type in ('adjustment', 'waste', 'spoilage', 'comp', 'count_correction')
group by s.id, s.prev_submitted_at, s.submitted_at, t.item_id;

-- ---------------------------------------------------------------------------
-- Atomic write functions
-- ---------------------------------------------------------------------------

-- Submit a draft count: for each counted item, write count_correction = counted - on_hand.
-- Takes a lock that blocks concurrent ledger inserts for the few ms this runs, so the
-- expected quantity can't shift underneath it (CP).
create function public.submit_count(p_count_id bigint)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.count_status;
  v_corrections integer;
begin
  if not public.is_manager() then
    raise exception 'only managers can submit counts' using errcode = '42501';
  end if;

  select status into v_status from public.counts where id = p_count_id for update;
  if v_status is null then
    raise exception 'count % not found', p_count_id;
  elsif v_status <> 'draft' then
    raise exception 'count % is already submitted', p_count_id;
  end if;

  lock table public.inventory_transactions in share row exclusive mode;

  update public.count_lines cl
  set expected_qty = coalesce((
    select sum(t.qty_delta) from public.inventory_transactions t where t.item_id = cl.item_id
  ), 0)
  where cl.count_id = p_count_id;

  insert into public.inventory_transactions (item_id, type, qty_delta, unit_cost, count_id, created_by)
  select cl.item_id, 'count_correction', cl.quantity - cl.expected_qty, i.unit_cost, p_count_id, auth.uid()
  from public.count_lines cl
  join public.items i on i.id = cl.item_id
  where cl.count_id = p_count_id and cl.quantity <> cl.expected_qty;
  get diagnostics v_corrections = row_count;

  update public.counts set status = 'submitted', submitted_at = now() where id = p_count_id;

  return v_corrections;
end;
$$;

-- Receive (part of) a PO. p_lines: [{"po_line_id": 1, "qty": 2, "unit_cost": 24.50}, ...]
-- qty and unit_cost are in order units; unit_cost is optional (defaults to the PO price).
create function public.receive_purchase_order(p_po_id bigint, p_lines jsonb)
returns public.po_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.po_status;
  v_line record;
  v_new_status public.po_status;
  v_matched integer;
begin
  if not public.is_manager() then
    raise exception 'only managers can receive orders' using errcode = '42501';
  end if;

  select status into v_status from public.purchase_orders where id = p_po_id for update;
  if v_status is null then
    raise exception 'purchase order % not found', p_po_id;
  elsif v_status not in ('placed', 'partially_received') then
    raise exception 'purchase order % is %, cannot receive', p_po_id, v_status;
  end if;

  select count(*) into v_matched
  from jsonb_array_elements(p_lines) l
  join public.po_lines pl on pl.id = (l ->> 'po_line_id')::bigint and pl.po_id = p_po_id;
  if v_matched = 0 or v_matched <> jsonb_array_length(p_lines) then
    raise exception 'p_lines must be a non-empty list of lines on purchase order %', p_po_id;
  end if;

  for v_line in
    select pl.id, pl.item_id, pl.units_per_order_unit,
           (l ->> 'qty')::numeric                                   as qty,
           coalesce((l ->> 'unit_cost')::numeric, pl.unit_cost)    as unit_cost
    from jsonb_array_elements(p_lines) l
    join public.po_lines pl on pl.id = (l ->> 'po_line_id')::bigint and pl.po_id = p_po_id
  loop
    if v_line.qty is null or v_line.qty <= 0 then
      raise exception 'received qty must be positive for po_line %', v_line.id;
    end if;

    update public.po_lines
    set qty_received = qty_received + v_line.qty,
        unit_cost = v_line.unit_cost
    where id = v_line.id;

    insert into public.inventory_transactions (item_id, type, qty_delta, unit_cost, po_line_id, created_by)
    values (
      v_line.item_id, 'receipt',
      v_line.qty * v_line.units_per_order_unit,
      v_line.unit_cost / v_line.units_per_order_unit,
      v_line.id, auth.uid()
    );

    if v_line.unit_cost is not null then
      update public.items
      set unit_cost = v_line.unit_cost / v_line.units_per_order_unit
      where id = v_line.item_id;
    end if;
  end loop;

  select case when bool_and(qty_received >= qty_ordered) then 'received' else 'partially_received' end
  into v_new_status
  from public.po_lines where po_id = p_po_id;

  update public.purchase_orders
  set status = v_new_status,
      received_at = case when v_new_status = 'received' then now() else received_at end
  where id = p_po_id;

  return v_new_status;
end;
$$;

-- Undo a ledger entry by inserting its negation. Reversing a reversal is not allowed;
-- re-enter the original instead.
create function public.reverse_transaction(p_txn_id bigint, p_reason text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txn public.inventory_transactions;
  v_new_id bigint;
begin
  if not public.is_manager() then
    raise exception 'only managers can reverse transactions' using errcode = '42501';
  end if;

  select * into v_txn from public.inventory_transactions where id = p_txn_id;
  if v_txn.id is null then
    raise exception 'transaction % not found', p_txn_id;
  elsif v_txn.type = 'reversal' then
    raise exception 'cannot reverse a reversal';
  end if;

  if v_txn.po_line_id is not null then
    update public.po_lines
    set qty_received = qty_received - v_txn.qty_delta / units_per_order_unit
    where id = v_txn.po_line_id;

    update public.purchase_orders po
    set status = case
          when agg.fully then 'received'::public.po_status
          when agg.any_received then 'partially_received'::public.po_status
          else 'placed'::public.po_status
        end,
        received_at = case when agg.fully then po.received_at end
    from (
      select pl.po_id,
             bool_and(pl.qty_received >= pl.qty_ordered) as fully,
             bool_or(pl.qty_received > 0)               as any_received
      from public.po_lines pl
      where pl.po_id = (select po_id from public.po_lines where id = v_txn.po_line_id)
      group by pl.po_id
    ) agg
    where po.id = agg.po_id;
  end if;

  insert into public.inventory_transactions
    (item_id, type, qty_delta, unit_cost, reason, reverses_id, created_by)
  values
    (v_txn.item_id, 'reversal', -v_txn.qty_delta, v_txn.unit_cost, p_reason, v_txn.id, auth.uid())
  returning id into v_new_id;

  return v_new_id;
end;
$$;

revoke execute on function public.submit_count(bigint) from public, anon;
revoke execute on function public.receive_purchase_order(bigint, jsonb) from public, anon;
revoke execute on function public.reverse_transaction(bigint, text) from public, anon;
grant execute on function public.submit_count(bigint) to authenticated;
grant execute on function public.receive_purchase_order(bigint, jsonb) to authenticated;
grant execute on function public.reverse_transaction(bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
--   viewer  -> read everything except other users' profiles
--   manager -> read + write; ledger is insert-only for everyone
--   anomalies/notifications are written by the server with the service role
-- ---------------------------------------------------------------------------

alter table public.profiles               enable row level security;
alter table public.vendors                enable row level security;
alter table public.categories             enable row level security;
alter table public.items                  enable row level security;
alter table public.counts                 enable row level security;
alter table public.count_lines            enable row level security;
alter table public.purchase_orders        enable row level security;
alter table public.po_lines               enable row level security;
alter table public.inventory_transactions enable row level security;
alter table public.anomalies              enable row level security;
alter table public.notifications          enable row level security;

create policy "own profile or manager" on public.profiles
  for select to authenticated using (id = (select auth.uid()) or (select public.is_manager()));
create policy "managers update profiles" on public.profiles
  for update to authenticated using ((select public.is_manager())) with check ((select public.is_manager()));

do $$
declare
  t text;
begin
  foreach t in array array['vendors', 'categories', 'items', 'counts', 'count_lines',
                           'purchase_orders', 'po_lines', 'inventory_transactions',
                           'anomalies', 'notifications']
  loop
    execute format(
      'create policy "authenticated read" on public.%I for select to authenticated using (true)', t);
  end loop;

  foreach t in array array['vendors', 'categories', 'items', 'purchase_orders', 'po_lines']
  loop
    execute format(
      'create policy "managers write" on public.%I for all to authenticated
         using ((select public.is_manager())) with check ((select public.is_manager()))', t);
  end loop;
end;
$$;

-- Counts: managers can create drafts and edit lines only while the count is a draft.
create policy "managers insert counts" on public.counts
  for insert to authenticated with check ((select public.is_manager()) and status = 'draft');
create policy "managers edit draft counts" on public.counts
  for update to authenticated
  using ((select public.is_manager()) and status = 'draft')
  with check ((select public.is_manager()) and status = 'draft');
create policy "managers delete draft counts" on public.counts
  for delete to authenticated using ((select public.is_manager()) and status = 'draft');

create policy "managers write draft count lines" on public.count_lines
  for all to authenticated
  using ((select public.is_manager()) and exists (
    select 1 from public.counts c where c.id = count_id and c.status = 'draft'))
  with check ((select public.is_manager()) and exists (
    select 1 from public.counts c where c.id = count_id and c.status = 'draft'));

-- Ledger: managers insert direct entries as themselves. Opening balances come from the
-- spreadsheet import; manual adjustments need a reason. Receipts, count corrections and
-- reversals go through the functions above.
create policy "managers insert manual entries" on public.inventory_transactions
  for insert to authenticated
  with check (
    (select public.is_manager())
    and created_by = (select auth.uid())
    and type in ('opening', 'adjustment', 'waste', 'spoilage', 'comp')
    and (type = 'opening' or reason is not null)
  );

create policy "managers resolve anomalies" on public.anomalies
  for update to authenticated using ((select public.is_manager())) with check ((select public.is_manager()));
