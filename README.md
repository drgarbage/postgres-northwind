# Northwind 資料庫（Docker）

Course 08 使用的真實企業交易資料庫：PostgreSQL（內建 Northwind 資料）+ PostgREST（自動 REST API）+ pgAdmin（管理介面）。

## 啟動

```bash
cd class08/northwind
docker compose up -d
```

第一次啟動會下載 image，需要幾分鐘。

## 驗證

| 服務 | 網址 | 說明 |
|------|------|------|
| PostgREST API | http://localhost:3000/categories | 任一資料表名都是端點 |
| 課程分析 View | http://localhost:3000/category_monthly_sales | 各類別月銷售額 |
| 課程分析 View | http://localhost:3000/product_inventory_status | 庫存與補貨判斷資料 |
| Schema 清單 | http://localhost:3000/analysis_tables | Agent 可探索的資料表與分析 View |
| 關聯清單 | http://localhost:3000/analysis_relationships | Agent 組 SQL 時使用的 JOIN 參考 |
| pgAdmin | http://localhost:5050 | admin@example.com / admin |

pgAdmin 連線資料庫：Host `db`、Port `5432`、DB `northwind`、User `northwind`、Password `northwind`（依 image 預設）。

## 分享給全班（講師）

```bash
ngrok http 3000
```

把 ngrok 網址提供給學員，Agent 的工具會以 `apiBaseUrl` 參數帶入。

## 停止

```bash
docker compose down      # 保留資料
docker compose down -v   # 連資料一起清除（下次啟動重新初始化）
```

## 安全說明

PostgREST 以 `web_anon` 唯讀角色對外，只能 SELECT。`db-init/zz-analysis-views.sql` 建立課程用的分析 View、schema metadata view，以及 `run_read_only_sql` 唯讀查詢入口。

`run_read_only_sql` 只接受 `SELECT` 或 `WITH ... SELECT`，拒絕寫入、DDL、權限、COPY、EXECUTE、CALL 與多語句，並限制回傳筆數。若需增加 View，記得 `GRANT SELECT ... TO web_anon` 並重啟。
