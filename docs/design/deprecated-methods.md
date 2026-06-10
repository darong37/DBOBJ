# Deprecated Methods
Date: 2026-06-10

以下のメソッドおよび内部関数は廃止とする。実装しない。

| メソッド | 理由 |
|---|---|
| `spool($spool_id)` | スプールへの書き出しは DBOBJ の責務外。呼び出し側が `hashes()` の metaAoh を使って外で行う |
| `fetch()` | `arrays()` / `hashes()` で代替 |
| `fetch_hr()` | `hashes()` で代替 |
| `fetch_group(@key_cols)` | `hashes()` + metaAoh の `group()` で代替 |
| `groups(@key_cols)` | `hashes()` + metaAoh の `group()` で代替 |
| `rows()` | 行数は `list()` のスカラー化・`arrays()` / `hashes()` の件数で取得可 |
| `_next_row()` | `fetch_group` / `groups` 廃止に伴い不要 |
| `_group()` | `fetch_group` / `groups` 廃止に伴い不要 |
