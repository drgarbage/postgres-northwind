-- 課程分析用 View（檔名以 zz 開頭，確保在 northwind.sql 建表之後執行）

-- 各類別月銷售額
CREATE OR REPLACE VIEW category_monthly_sales AS
SELECT
  c.category_name AS category,
  to_char(o.order_date, 'YYYY-MM') AS month,
  round(sum(od.unit_price * od.quantity * (1 - od.discount))::numeric, 0) AS sales
FROM order_details od
JOIN orders o ON o.order_id = od.order_id
JOIN products p ON p.product_id = od.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE o.order_date IS NOT NULL
GROUP BY c.category_name, to_char(o.order_date, 'YYYY-MM')
ORDER BY category, month;

-- 商品庫存與補貨判斷基礎資料：
-- 近 90 天銷量（以資料庫中最後一筆訂單日期回推，Northwind 為歷史資料集）
CREATE OR REPLACE VIEW product_inventory_status AS
WITH last_day AS (
  SELECT max(order_date) AS d FROM orders
),
recent_sales AS (
  SELECT od.product_id, sum(od.quantity) AS qty_last_90d
  FROM order_details od
  JOIN orders o ON o.order_id = od.order_id, last_day
  WHERE o.order_date >= last_day.d - INTERVAL '90 days'
  GROUP BY od.product_id
)
SELECT
  p.product_id,
  p.product_name,
  c.category_name AS category,
  p.unit_price,
  p.units_in_stock,
  p.units_on_order,
  p.reorder_level,
  p.discontinued,
  coalesce(r.qty_last_90d, 0) AS qty_last_90d,
  round(coalesce(r.qty_last_90d, 0) / 90.0, 2) AS avg_daily_qty,
  CASE
    WHEN coalesce(r.qty_last_90d, 0) = 0 THEN NULL
    ELSE round(p.units_in_stock / (coalesce(r.qty_last_90d, 0) / 90.0), 1)
  END AS days_of_stock
FROM products p
JOIN categories c ON c.category_id = p.category_id
LEFT JOIN recent_sales r ON r.product_id = p.product_id
ORDER BY p.product_id;

GRANT SELECT ON category_monthly_sales TO web_anon;
GRANT SELECT ON product_inventory_status TO web_anon;

-- Agent 可探索的資料表清單
CREATE OR REPLACE VIEW analysis_tables AS
SELECT *
FROM (
  VALUES
    ('categories', '產品類別', '產品分類，例如 Beverages、Seafood'),
    ('products', '產品品項', '商品、單價、庫存、補貨點與供應商'),
    ('suppliers', '供應商', '供應商基本資料與地理位置'),
    ('customers', '客戶', '客戶公司、聯絡人與地理位置'),
    ('orders', '訂單主檔', '訂單日期、出貨日期、客戶、業務員、物流商與運費'),
    ('order_details', '訂單明細', '每張訂單中的商品、單價、數量與折扣'),
    ('employees', '業務員 / 員工', '員工資料、職稱與主管關係'),
    ('shippers', '物流商', '物流公司名稱與電話'),
    ('category_monthly_sales', '分析 View：類別月銷售', '各產品類別按月份彙整的銷售額'),
    ('product_inventory_status', '分析 View：商品庫存狀態', '商品庫存、近 90 天銷量與可售天數')
) AS t(table_name, display_name, description);

-- Agent 可讀的欄位說明
CREATE OR REPLACE VIEW analysis_columns AS
SELECT
  c.table_name,
  c.column_name,
  c.data_type,
  c.is_nullable,
  CASE
    WHEN c.table_name = 'orders' AND c.column_name IN ('order_id', 'customer_id', 'employee_id', 'ship_via') THEN '關聯識別欄位，可用於串接訂單、客戶、業務員與物流商'
    WHEN c.table_name = 'orders' AND c.column_name IN ('order_date', 'required_date', 'shipped_date') THEN '日期欄位，可用於趨勢、履約與延遲分析'
    WHEN c.table_name = 'orders' AND c.column_name IN ('freight', 'ship_country', 'ship_city') THEN '物流與地理分析欄位'
    WHEN c.table_name = 'order_details' AND c.column_name IN ('unit_price', 'quantity', 'discount') THEN '銷售金額計算欄位：unit_price * quantity * (1 - discount)'
    WHEN c.table_name = 'products' AND c.column_name IN ('product_name', 'category_id', 'supplier_id', 'unit_price', 'units_in_stock', 'units_on_order', 'reorder_level', 'discontinued') THEN '產品、供應商、庫存與補貨分析欄位'
    WHEN c.table_name = 'customers' AND c.column_name IN ('customer_id', 'company_name', 'country', 'city') THEN '客戶價值與地理分群分析欄位'
    WHEN c.table_name = 'employees' AND c.column_name IN ('employee_id', 'first_name', 'last_name', 'title', 'reports_to') THEN '業務員績效與組織層級分析欄位'
    ELSE NULL
  END AS analysis_hint
FROM information_schema.columns c
JOIN analysis_tables t ON t.table_name = c.table_name
WHERE c.table_schema = 'public'
ORDER BY c.table_name, c.ordinal_position;

-- 常用關聯路徑，讓 Agent 組 SQL 時知道怎麼 JOIN
CREATE OR REPLACE VIEW analysis_relationships AS
SELECT *
FROM (
  VALUES
    ('orders', 'customer_id', 'customers', 'customer_id', '訂單對應客戶'),
    ('orders', 'employee_id', 'employees', 'employee_id', '訂單對應業務員'),
    ('orders', 'ship_via', 'shippers', 'shipper_id', '訂單對應物流商'),
    ('order_details', 'order_id', 'orders', 'order_id', '訂單明細對應訂單主檔'),
    ('order_details', 'product_id', 'products', 'product_id', '訂單明細對應產品'),
    ('products', 'category_id', 'categories', 'category_id', '產品對應類別'),
    ('products', 'supplier_id', 'suppliers', 'supplier_id', '產品對應供應商'),
    ('employees', 'reports_to', 'employees', 'employee_id', '員工對應直屬主管')
) AS r(from_table, from_column, to_table, to_column, description);

-- 唯讀 SQL 執行入口：只允許 SELECT / WITH ... SELECT，並由 DB 端再加一道防護
CREATE OR REPLACE FUNCTION run_read_only_sql(sql_text text, row_limit integer DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
SET statement_timeout = '5s'
AS $$
DECLARE
  cleaned text;
  limited_sql text;
  result jsonb;
  safe_limit integer;
BEGIN
  cleaned := trim(sql_text);
  safe_limit := LEAST(GREATEST(COALESCE(row_limit, 200), 1), 500);

  IF cleaned !~* '^(select|with)\s' THEN
    RAISE EXCEPTION 'Only SELECT or WITH ... SELECT statements are allowed';
  END IF;

  IF cleaned ~* '\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|copy|execute|call)\b' THEN
    RAISE EXCEPTION 'Write, DDL, privilege, COPY, EXECUTE, and CALL statements are not allowed';
  END IF;

  IF cleaned ~ ';' THEN
    RAISE EXCEPTION 'Multiple statements are not allowed';
  END IF;

  limited_sql := format('SELECT jsonb_agg(row_to_json(q)) FROM (%s LIMIT %s) q', cleaned, safe_limit);
  EXECUTE limited_sql INTO result;

  RETURN jsonb_build_object(
    'rowCount', COALESCE(jsonb_array_length(result), 0),
    'rows', COALESCE(result, '[]'::jsonb),
    'executedSql', cleaned,
    'limit', safe_limit
  );
END;
$$;

GRANT SELECT ON analysis_tables TO web_anon;
GRANT SELECT ON analysis_columns TO web_anon;
GRANT SELECT ON analysis_relationships TO web_anon;
GRANT EXECUTE ON FUNCTION run_read_only_sql(text, integer) TO web_anon;

NOTIFY pgrst, 'reload schema';
