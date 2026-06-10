# Deprecated Methods
Date: 2026-06-10

以下のメソッドおよび内部関数は廃止とする。実装しない。

| メソッド | 理由 |
|---|---|
| `fetch()` | `arrays()` / `hashes()` で代替 |
| `fetch_hr()` | `hashes()` で代替 |
| `fetch_group(@key_cols)` | `hashes()` + metaAoh の `group()` で代替 |
| `groups(@key_cols)` | `hashes()` + metaAoh の `group()` で代替 |
| `rows()` | 行数は `list()` のスカラー化・`arrays()` / `hashes()` の件数で取得可 |
| `_next_row()` | `fetch_group` / `groups` 廃止に伴い不要 |
| `_group()` | `fetch_group` / `groups` 廃止に伴い不要 |

## 変更履歴

- 2026-06-11: `spool($spool_id)` を一覧から削除。当初は「スプールへの書き出しは DBOBJ の責務外」として廃止したが、巨大な結果セットを metaAoh としてメモリに作らず fetch ループで 1 行ずつ Spool へ流すストリーミング退避は `hashes()` では代替できないため、別仕様として新設した（design-concept.md 第三コンセプト）
