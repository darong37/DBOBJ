# DBOBJ 設計変更仕様書
Date: 2026-04-09

## 概要

旧設計（2026-04-05）からの方針変更。ストリーミング系 API を廃止し、シンプルな一括取得に統一する。Spool への書き出しを新規追加する。

## 変更の背景

- `fetch` / `fetch_hr` / `fetch_group` / `groups` などのストリーミング系は複雑すぎる
- グループ化は TableTools の `group()` に任せれば DBOBJ が持つ必要がない
- データをメモリに載せたくない場合は Spool を使えば解決する
- DB の NULL と空文字の実質的な違いはないため、undef はすべて `''` に統一する

## API 変更

### 廃止

| メソッド | 理由 |
|---|---|
| `fetch()` | `arrays()` / `hashes()` で代替 |
| `fetch_hr()` | `hashes()` で代替 |
| `fetch_group(@key_cols)` | `hashes()` + TableTools `group()` で代替 |
| `groups(@key_cols)` | `hashes()` + TableTools `group()` で代替 |
| `rows()` | 件数は `list()` / `arrays()` の件数、または `hashes()` の count で取得する。0件時は配列の件数で判断する |
| `_next_row()` | ストリーミング廃止に伴い不要 |
| `_group()` | ストリーミング廃止に伴い不要 |

### 新規追加

| メソッド | 役割 | 出力 |
|---|---|---|
| `arrays()` | 全件を AoA で返す | AoA または `[]` |
| `spool($spool_id)` | Spool への書き出し | ― |

### 変更

| メソッド | 役割 | 出力 |
|---|---|---|
| `hashes()` | 全件をメタ付き AoH で返す。meta に `count` を追加 | `[{'#' => {...}}, {row}, ...]` または `[]`（0件時） |

### 変更なし

`new`, `prepare`, `execute`, `run`, `get`, `list`, `psql`, `close`

## 設計方針

### DB 接続

`new($dbname)` に dbname は必須。`PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD` の4環境変数も必須。いずれか未設定の場合は die する。`PGDATABASE` 環境変数は参照しない。

### DBI エラー処理

DBI の自動例外（`RaiseError`）は無効にし、エラーは手動検知して die する。

### DBI 準拠の挙動

`prepare` → `execute` の呼び出し順序、取得系 API の結果セット消費など、DBI の挙動に関わる制御は DBI の仕様に委ねる。DBOBJ 側で独自に制御しない。

### データ取得の4形式

- `get()` ― スカラー1値（1行1列以外は die）
- `list()` ― 単一カラム全件をフラット配列（1列以外は die）
- `arrays()` ― 全件を AoA で
- `hashes()` ― 全件をメタ付き AoH で

### meta の形式

```perl
{'#' => {
    attrs => {col => 'str', ...},  # DBI 型情報から判定。REAL/INTEGER/NUMERIC 系は 'num'、それ以外は 'str'
    order => ['col', ...],         # カラムの並び順
    count => N,                    # データ行数
}}
```

DBI の `sth->{TYPE}` が返す SQL 型コードを `attrs` の `num` / `str` に正規化する。REAL・INTEGER・NUMERIC 系に対応する型コードは `num` とし、それ以外の型コードは `str` とする。

### undef の扱い

DBOBJ が返却するデータ値に `undef` は存在しない。DB の NULL を含め、取得した値の `undef` はすべて `''` に変換してから返す。内部状態（`sth` 等）は対象外。

### Spool 書き出し

`spool($spool_id)` は Spool.pm 経由で `/tmp/spool/<spool_id>` に書き出す。結果をメモリに展開しない。`Spool->open(spool_id)` → 全行 `add()` → `Spool->meta(meta)` → `close()` の順で処理する。0件でも `attrs` と `order` は SQL のステートメントハンドルから取得して meta に渡す。`count` は 0 とする。

### run() の bind なし仕様

`run($sql)` は bind を取らない。bind が必要な場合は `prepare($sql)` → `execute(@bind)` を使う。

### psql の NOTICE 扱いと接続情報

`psql($sqlfile)` は `dbname` と `PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD` を使って psql を別プロセスで起動する。`--set ON_ERROR_STOP=1` オプションにより SQL エラー時は非0終了するが、NOTICE は出力されるだけでエラーにならない。

### グループ化

DBOBJ は関与しない。呼び出し側が TableTools の `group()` を使う。

## テスト方針

- 実 PostgreSQL DB（`develop`）を使う結合テスト（モックなし）
- 環境変数（`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`）が設定済みであること

### テストケース

| # | テスト内容 |
|---|---|
| 1 | 接続成功・`close()` |
| 2 | 環境変数未設定で `die` |
| 3 | dbname 未指定で `die` |
| 4 | `PGDATABASE` に別値が入っていても `new($dbname)` の dbname が接続先として使われること |
| 5 | `run` + `get`（スカラー1値） |
| 6 | `get` で1行1列以外は `die` |
| 7 | `run` + `list`（単一カラム） |
| 8 | `list` で1列以外は `die` |
| 9 | `run` + `arrays`（AoA） |
| 10 | `arrays` 0件なら `[]` |
| 11 | `run` + `hashes`（メタ付き AoH・attrs/order/count 確認。count は meta 自身を含まないデータ行数） |
| 12 | `hashes` 0件なら `[]` |
| 13 | NULL → `''` への変換確認（get/list/arrays/hashes） |
| 14 | `prepare` + `execute` バインド変数 |
| 15 | DML（INSERT/UPDATE/DELETE）実行 |
| 16 | `run` で SQL 構文エラーが発生した場合 `die` すること（DBI 手動検知） |
| 17 | `prepare` + `execute` で SQL エラーが発生した場合 `die` すること（DBI 手動検知） |
| 18 | `psql($sqlfile)` ファイル実行 |
| 19 | `psql` でファイル不在の場合 `die` |
| 20 | `psql` で終了コード非0の場合 `die` |
| 21 | `psql` で NOTICE が出ても die しないこと |
| 22 | `spool($spool_id)` 書き出し・Spool から読み返して確認 |
| 23 | `spool` 0件でも spool が作成され attrs/order が保持され count が0であること |
| 24 | `spool` で NULL を含む行を書き出した場合、Spool から読み返した値が `''` になること |
