# Deprecated Methods
Date: 2026-04-08

以下のメソッドおよび内部関数は廃止とする。実装しない。

| メソッド | 理由 |
|---|---|
| `fetch()` | `arrays()` / `hashes()` で代替 |
| `fetch_hr()` | `hashes()` で代替 |
| `fetch_group(@key_cols)` | `hashes()` + TableTools `group()` で代替 |
| `groups(@key_cols)` | `hashes()` + TableTools `group()` で代替 |
| `rows()` | 行数は `list()` のスカラー化・`arrays()` / `hashes()` の件数で取得可 |
| `_next_row()` | `fetch_group` / `groups` 廃止に伴い不要 |
| `_group()` | `fetch_group` / `groups` 廃止に伴い不要 |
