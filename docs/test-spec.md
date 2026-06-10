# DBOBJ Test Spec
Date: 2026-06-10

テストスイートの仕様を定義する。仕様本体は [spec.md](spec.md) を参照すること。

## テスト方針

- 実 PostgreSQL DB（`develop`）を使う結合テスト。モックは使わない
- テーブルは `CREATE TEMP TABLE` で作成し、テーブル名にプロセス ID を含めて
  他テストとの衝突を避ける
- 環境変数（`PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD`）が設定済みであること。
  定義元は `.claude/settings.json` の `env` とする

## 実行方法

```bash
prove -lr test/
```

## テストファイル

| ファイル | 役割 |
|---|---|
| `test/dbobj.t` | テスト本体。下表の全ケースを実装する |
| `test/insert.sql` | `psql()` 正常実行用の SQL ファイル |
| `test/error.sql` | `psql()` SQL エラー検証用の SQL ファイル |
| `test/notice.sql` | `psql()` NOTICE 検証用の SQL ファイル |

## テストケース

`test/dbobj.t` の各 subtest は `spec#N` コメントで下表の番号に対応する。

| # | テスト内容 |
|---|---|
| 1 | 接続成功・`close()` |
| 2 | 環境変数未設定で `die` |
| 3 | dbname 未指定で `die` |
| 4 | `PGDATABASE` に別値が入っていても `new($dbname)` の dbname が接続先として使われること |
| 5 | `run` + `get`（スカラー1値） |
| 6 | `get` で1行1列以外は `die`（複数列・複数行・0件） |
| 7 | `run` + `list`（単一カラム全件） |
| 8 | `list` で1列以外は `die` |
| 9 | `run` + `arrays`（AoA） |
| 10 | `arrays` 0件なら `[]` |
| 11 | `run` + `hashes` が metaAoh を返すこと（`MetaAoh::is_metaAOH` が真・AOH として行に添字アクセスできる・`count()` がデータ行数） |
| 12 | `hashes` の meta 確認（`order` は num カラムが `NAME#`・str カラムが `NAME`、`cols` がカラム順、`attrs` が型、`grouped` が 0） |
| 13 | `hashes` 0件なら空の metaAoh（`count() == 0`・`cols`/`attrs` は保持） |
| 14 | NULL → `''` への変換確認（get/list/arrays/hashes） |
| 15 | `prepare` + `execute` バインド変数 |
| 16 | DML（INSERT/UPDATE/DELETE）実行 |
| 17 | `run` で SQL 構文エラーが発生した場合 `die` すること（DBI 手動検知） |
| 18 | `prepare` + `execute` で SQL エラーが発生した場合 `die` すること（DBI 手動検知） |
| 19 | `psql($sqlfile)` ファイル実行 |
| 20 | `psql` でファイル不在の場合 `die` |
| 21 | `psql` で終了コード非0の場合 `die` |
| 22 | `psql` で NOTICE が出ても die しないこと |
| 23 | `hashes` の返り値に対して呼び出し側で `group()` が機能すること（DBOBJ の出力が MetaAoh の前提条件を満たす統合確認） |
