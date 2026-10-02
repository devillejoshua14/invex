-- Sample data for local development (`npx supabase db reset`).

insert into public.categories (name) values
  ('Liquor'), ('Beer'), ('Wine'), ('Non-alcoholic'), ('Proteins'), ('Produce'), ('Dairy'), ('Dry goods');

insert into public.vendors (name, contact_name, phone, order_days, lead_time_days) values
  ('Sysco',                 'Sysco rep',         '+15555550101', '{1,4}', 2),
  ('Southern Glazer''s',    'Spirits rep',       '+15555550102', '{2}',   3),
  ('Local Beer Distributor','Beer rep',          '+15555550103', '{3}',   2);

insert into public.items
  (name, category_id, vendor_id, count_unit, order_unit, units_per_order_unit, unit_cost, par_level, reorder_point, storage_area)
select v.name, c.id, ve.id, v.count_unit, v.order_unit, v.upo, v.unit_cost, v.par, v.reorder, v.area
from (values
  ('Tito''s Vodka 1L',        'Liquor',        'Southern Glazer''s',     'bottle', 'case',  12, 21.50,  8,  4, 'Bar'),
  ('Jameson Irish Whiskey 1L','Liquor',        'Southern Glazer''s',     'bottle', 'case',  12, 32.00,  4,  2, 'Bar'),
  ('Coors Light 12oz can',    'Beer',          'Local Beer Distributor', 'can',    'case',  24,  0.95, 144, 72, 'Walk-in cooler'),
  ('Michelob Ultra 12oz can', 'Beer',          'Local Beer Distributor', 'can',    'case',  24,  1.05, 192, 96, 'Walk-in cooler'),
  ('House Chardonnay 750ml',  'Wine',          'Southern Glazer''s',     'bottle', 'case',  12,  9.75,  12,  6, 'Bar'),
  ('Gatorade Lemon-Lime 20oz','Non-alcoholic', 'Sysco',                  'bottle', 'case',  24,  1.10,  96, 48, 'Walk-in cooler'),
  ('Burger patties 1/3lb',    'Proteins',      'Sysco',                  'each',   'case',  48,  1.85,  96, 48, 'Freezer'),
  ('Hot dogs 1/4lb',          'Proteins',      'Sysco',                  'each',   'case',  40,  0.90,  80, 40, 'Freezer'),
  ('Brioche buns',            'Dry goods',     'Sysco',                  'each',   'case',  48,  0.45,  96, 48, 'Dry storage'),
  ('Romaine hearts',          'Produce',       'Sysco',                  'each',   'case',  24,  0.80,  24, 12, 'Walk-in cooler'),
  ('American cheese slices',  'Dairy',         'Sysco',                  'slice',  'case', 480,  0.06, 400,200, 'Walk-in cooler')
) as v(name, category, vendor, count_unit, order_unit, upo, unit_cost, par, reorder, area)
join public.categories c on c.name = v.category
join public.vendors ve on ve.name = v.vendor;

-- Opening balances, as if imported from the old spreadsheet.
insert into public.inventory_transactions (item_id, type, qty_delta, unit_cost, reason)
select id, 'opening', coalesce(par_level, 1), unit_cost, 'Imported from spreadsheet'
from public.items;
