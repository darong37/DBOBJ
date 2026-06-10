# DBOBJ Spec
Date: 2026-06-11

現在の仕様・出力契約を定義する。設計の意図と用語は
[design-concept.md](design/design-concept.md) を唯一の正解として参照すること。

## 概要

DBOBJ は DBI の薄いラッパーである。PostgreSQL 専用。
DBI の挙動を独自に作り替えず、SQL を書いてすぐ使える形を提供する。

- データ取得は `get()`、`list()`、`arrays()`、`hashes()` の4形式に限定する
- グループ化は呼び出し側が metaAoh の `group()` で行う。DBOBJ は関与しない
- DB から取得した値の `undef`（NULL）は、返却時にすべて空文字 `''` へ置き換える
- 巨大な結果セットは `spool()` で metaAoh を作らずに 1 行ずつ Spool へ退避できる（仕様は `lib/Spool.spec.md` に従う）

CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は `lib/CommonIO.spec.md` に従う。

## 接続

- 接続は `new($dbname)` でのみ行う。`$dbname` は必須
- 環境変数 `PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD` は必須。未設定なら CommonIO の `dying()` で die する
- `PGDATABASE` 環境変数は参照しない
- DBI の自動例外（`RaiseError`）は無効にし、エラーは手動検知して CommonIO の `dying()` でエラーログを残して die する
- 接続時に `SET client_min_messages = WARNING` を実行する

接続オブジェクトの内部状態は次のとおり。

```perl
{
    dbname => $dbname,  # データベース名
    dbh => $dbh,      # DBI データベースハンドル
    sth => undef,     # 実行済みステートメントハンドル
    sql => undef,     # 直近に prepare した SQL（spool() の ORDER BY 解析に使う）
    ordercols => [],  # 直近の spool() で解析したソート列名（ordercols）
}
```

## API

記号は次のとおり。

- `$dbname`: 接続先 PostgreSQL データベース名
- `$sql`: SQL 文字列
- `@bind`: バインド値のリスト
- `$sqlfile`: SQL が記述されたファイルのパス
- `metaAoh`: MetaAoh オブジェクト。meta（`order`・`cols`・`attrs`・`grouped`）を持ち、件数は `count()` メソッドで得る
- `$spool_id`: Spool の spool_id（`[A-Za-z0-9]+`。仕様は `lib/Spool.spec.md` に従う）

| API | 役割 | 入力 | 出力 |
|---|---|---|---|
| `new($dbname)` | 接続・生成 | `$dbname` | `DBOBJ` |
| `prepare($sql)` | プリペア | `$sql` | `$self` |
| `execute(@bind)` | 実行 | `@bind` | `$self` |
| `run($sql)` | bind なしの prepare + execute | `$sql` | `$self` |
| `get()` | スカラー1値取得 | ― | 1値 |
| `list()` | 単一カラム全件 | ― | フラット配列 |
| `arrays()` | 全件（AoA） | ― | `[]` または AoA |
| `hashes()` | 全件（metaAoh） | ― | `metaAoh`（0件でも空の metaAoh） |
| `spool($spool_id)` | 全件を Spool へ退避 | `$spool_id` | `$spool_id` |
| `psql($sqlfile)` | SQL ファイル実行 | `$sqlfile` | ― |
| `close()` | DB 接続を閉じる | ― | ― |

## 出力契約

### 実行系

- `prepare($sql)` → `execute(@bind)` の呼び出し順序、結果セット消費などの挙動は
  DBI の仕様に従う。DBOBJ は独自に制御しない
- `prepare($sql)` は `$sql` を内部状態 `sql` に保持する（`spool()` の `ORDER BY` 解析に使う）
- `run($sql)` は bind を取らない。bind が必要な場合は `prepare()` → `execute()` を使う
- prepare / execute の失敗は手動検知して CommonIO の `dying()` で die する

### get()

- 結果が 1行1列のときだけスカラー1値を返す
- 0行・複数行・複数列はすべて die する

### list()

- 結果が 1列のときだけ、全行をフラット配列で返す
- 1列でない場合は die する

### arrays()

- 全件を AoA（配列リファレンスの配列リファレンス）で返す
- 0件なら `[]` を返す

### hashes()

- MetaAoh オブジェクト（metaAoh）を返す
- ステートメントハンドルの型情報（`sth->{TYPE}`）からカラム指定を組み立てて `MetaAoh->new` に渡す
  - REAL・INTEGER・NUMERIC 系（`smallint`、`integer`、`bigint`、`real`、`double precision`、`numeric` など）は `'num'` → カラム指定は `NAME#`
  - それ以外はすべて `'str'` → カラム指定は `NAME`
- カラムの並びはステートメントハンドルの `NAME` の順序に従う
- 返る metaAoh の meta は `order`・`cols`・`attrs`・`grouped` を持つ（MetaAoh の仕様による）
- 件数は `count()` メソッドで得る（meta に `count` は持たない）
- 0件でも空の metaAoh を返す（カラム情報は保持し `count() == 0`）。「0件なら `[]`」という旧仕様は廃止済み
- 行には `$m->[0]`、`$m->[1]` のように添字でアクセスする

### NULL の扱い

- `get()`、`list()`、`arrays()`、`hashes()` の返却値に `undef` は存在しない
- DB の NULL を含め、取得値の `undef` はすべて `''` に変換してから返す

### spool($spool_id)

- 実行済みステートメントハンドルから fetch ループで 1 行ずつ `Spool->open` / `add` / `close` へ流し、`$spool_id` を返す。結果セットを metaAoh や配列としてメモリに作らない
- `Spool->open` に渡す schema（MetaAoh の order 記法）は `hashes()` と同じ規則（`'str'` は `NAME`、`'num'` は `NAME#`）で DBI の列情報から自動生成する
- fetch した値の `undef` は `''` へ置き換えてから `add()` に渡す（Spool の「`undef` は `add()` で die」契約と両立する）
- `prepare()` で保持した SQL のトップレベル（括弧深度 0）の `ORDER BY` を解析してソート列を得る
  - トップレベルに `ORDER BY` がない SQL は die する
  - 解析は大文字小文字や書式に依存しない。文字列リテラル・コメント・括弧内（サブクエリ等）の `ORDER BY` は対象にしない
  - 裸の識別子（任意で `ASC` / `DESC`、`NULLS FIRST` / `NULLS LAST` 付き）だけを列名に解決する。位置指定（`ORDER BY 1`）・式・修飾名・引用識別子は die する
  - 解決した列が SELECT 句の列（`sth->{NAME}`）に存在しない場合は die する
- DBOBJ は渡された SQL を書き換えない。`ORDER BY` の自動付与はしない
- 解析したソート列は内部状態 `ordercols` に保持する。呼び出し側は `Spool::records($spool_id, @key_cols)` のキー列として利用・検証できる。解析をすり抜けた順序違反は Spool 側の再出現 die が二段目の安全網となる
- 0件でも die しない。`open` → `close` まで行い（Spool の仕様により `close` が warn を出す）、`$spool_id` を返す
- spool の確定（`Spool::records` / `lines` / `grouping`）は呼び出し側の責務。`spool()` は write フェーズまでを行う
- DBOBJ が検知するエラーは `dying()` で die し、Spool 自身の die（spool_id 不正・重複など）はそのまま伝播する

### psql($sqlfile)

- `dbname` と `PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD` を使って
  psql を別プロセスで起動する
- `$sqlfile` が存在しない場合は die する
- `--set ON_ERROR_STOP=1` で起動し、SQL エラー時は非0終了 → die する
- NOTICE は出力されるだけでエラーにならない

### close()

- ステートメントハンドルを finish し、DB 接続を閉じる

## 廃止メソッド

廃止メソッド一覧は [deprecated-methods.md](design/deprecated-methods.md) を参照する。
