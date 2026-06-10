# Design Concept
Date: 2026-06-11

## Instruction
この文書は設計を決めるための単一の指示書である。
内容は `Concept`、`API`、`Rules` の順で定める。

- `Concept`: このプロジェクトの設計方針を書く
- `API`: その方針を外から見える操作として定める
- `Rules`: その方針と API を支える制約を、Perl のコメント文として書く
- `Concept` は何を大事にするかを書く。個別メソッドの細かな制約は `Rules` に書く
- `Rules` は実装時に迷わないための拘束条件を書く。方針説明は `Concept` に寄せる

`Concept` には、何を大事にし、どのように作るかを書く。
`Concept` や `API` を変更・追加したときは、必ずその内容を `Rules` に反映する。コードでは `Rules` を `package` 宣言の直下に置く。

## Concept

### 第一コンセプト：DBI の薄いラッパー

DBI をそのまま使うには冗長な手順が多い。DBOBJ は DBI を簡潔なオブジェクトに包み、SQL を書いてすぐ使える形にする。

データ取得は次の4形式に限定する。

- `get()` ― スカラー1値
- `list()` ― 単一カラム全件をフラット配列で
- `arrays()` ― 全件を AoA で
- `hashes()` ― 全件を metaAoh（MetaAoh オブジェクト）で

グループ化は呼び出し側が metaAoh の `group()` で行う。

メタ付き AoH の扱いは MetaAoh（`lib/MetaAoh.pm`）に従う。仕様は `lib/MetaAoh.spec.md` を参照する。DB のステートメントハンドルから得られるカラム情報（名前・型・順序）で MetaAoh のカラム指定を組み立て、`MetaAoh->new` に渡す。`hashes()` は 0件でも空の metaAoh を返す（カラム情報は保持し `count() == 0`）。

DB から取得した値に `undef` が含まれていた場合は、返却時にすべて空文字 `''` に置き換える。これは MetaAoh の「値に `undef` を含まない」条件とも整合する。

`attrs` の型判定は DBI の型情報をもとに行う。REAL・INTEGER・NUMERIC 系（`smallint`、`integer`、`bigint`、`real`、`double precision`、`numeric` など）は `'num'`、それ以外はすべて `'str'` とする。`'num'` のカラムは `NAME#`、`'str'` のカラムは `NAME` として MetaAoh のカラム指定に変換する。

接続オブジェクトの内部状態は次のとおり。

```perl
{
    dbname => $dbname,  # データベース名
    dbh => $dbh,      # DBI データベースハンドル
    sth => undef,     # 実行済みステートメントハンドル
    sql => undef,     # 直近に prepare した SQL（spool() の ORDER BY 解析に使う）
    ordercols => [],   # 直近の spool() で解析したソート列名（ordercols）
}
```

- 接続は `new($dbname)` でのみ行う
- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` を使い、`PGDATABASE` は参照しない
- DBI の自動例外は使わず、エラーは手動検知して CommonIO の `dying()` でエラーログを残して die する
- 呼び出し順序や結果セット消費などの挙動は DBI の仕様に従い、独自に制御しない

CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は `lib/CommonIO.spec.md` に従う。

### 第二コンセプト：psql との連動

SQL ファイルを psql プロセス経由で実行できる。DBI では扱いにくい DDL・トランザクション・`\copy` などを psql に任せることができ、DBOBJ と psql を組み合わせた運用を想定している。

### 第三コンセプト：Spool との連動

巨大な結果セットを metaAoh としてメモリに作らず、fetch ループで 1 行ずつ Spool へ退避できる。Spool の扱いは Spool（`lib/Spool.pm`）に従う。仕様は `lib/Spool.spec.md` を参照する。

`spool($spool_id)` は実行済みステートメントハンドルから 1 行ずつ `Spool->open` / `add` / `close` へ流し、`$spool_id` を返す。schema（MetaAoh の order 記法）は `hashes()` と同じ規則で DBI の列情報から自動生成する。`undef` は既存取得系と同じ規則で fetch 時に `''` へ置き換えてから Spool へ渡す。これにより Spool の「`undef` は `add()` で die」契約と両立する。

Spool へ流すデータはソート済みが前提のため、`prepare()` で保持した SQL のトップレベル `ORDER BY` を解析してソート列（ordercols）を得る。`ORDER BY` がない SQL はエラーとする。解析は大文字小文字や書式の規約に依存しない。規約は保証ではない。位置指定（`ORDER BY 1`）や式など、列名として解決できない指定は「順序を確認できない」としてエラーに倒す。DBOBJ は渡された SQL を書き換えない。`ORDER BY` の自動付与はしない。

解析で得た ordercols は内部状態に保持し、Spool の `records` 確定のキー列として利用・検証できる。解析をすり抜けた順序違反は Spool 側の再出現 die が二段目の安全網として捕まえる。

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

## 廃止メソッド

廃止メソッド一覧は [deprecated-methods.md](deprecated-methods.md) を参照する。

## Rules
```perl
# Terms:
# DBOBJ は DBI の薄いラッパーであり、DBI の挙動を独自に作り替えない
# データ取得は get(), list(), arrays(), hashes() に限定する
# DB から取得した値に undef が含まれていた場合は、返却時に '' へ置き換える
# AoH     : ハッシュリファレンスの配列リファレンス
# AoA     : 配列リファレンスの配列リファレンス
# metaAoh : MetaAoh オブジェクト。meta（order, cols, attrs, grouped）を持ち、件数は count() メソッドで得る。仕様は lib/MetaAoh.spec.md に従う
# dbname  : 接続先 PostgreSQL データベース名
# spool_id : Spool の spool_id（[A-Za-z0-9]+）。仕様は lib/Spool.spec.md に従う
# ordercols : SQL のトップレベル ORDER BY から解析したソート列名のリスト。直近の spool() の結果を内部状態に保持する
#
# Rules:
# CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は lib/CommonIO.spec.md に従う
# new() に dbname（接続先 PostgreSQL データベース名）は必須。PGHOST, PGPORT, PGUSER, PGPASSWORD は必須。PGDATABASE 環境変数は参照しない
# DBI の自動例外は無効にし、エラーは手動検知して CommonIO の dying() でエラーログを残して die する
# DB から取得した値に undef が含まれていた場合は、get(), list(), arrays(), hashes() の返却時に '' へ置き換える
# prepare() -> execute() の呼び出し順序、取得系 API の結果セット消費、呼び出し順序に関する挙動は DBI の仕様に従う。DBOBJ は独自に制御しない
# run(sql) は bind を取らない。bind が必要な場合は prepare(sql) -> execute(@bind) を使う
# attrs の型は DBI の型情報をもとに判定する。REAL・INTEGER・NUMERIC 系（smallint, integer, bigint, real, double precision, numeric など）は 'num'、それ以外は 'str'
# hashes() は DBI の型情報から MetaAoh のカラム指定（'str' は NAME、'num' は NAME#）を組み立てて MetaAoh->new に渡す
# get() は結果が 1行1列でない場合 die する。0行でも複数行でも複数列でも die する
# list() は結果が 1列でない場合 die する
# arrays() は 0件なら [] を返す
# hashes() は metaAoh を返す。0件でも空の metaAoh を返す（カラム情報は保持し count() == 0）
# グループ化は呼び出し側が metaAoh の group() で行う。DBOBJ は関与しない
# prepare(sql) は sql を内部状態に保持する（spool() の ORDER BY 解析に使う）
# spool(spool_id) は実行済みステートメントハンドルから fetch ループで 1 行ずつ Spool->open / add / close へ流し、spool_id を返す。結果セットを metaAoh としてメモリに作らない
# spool() の schema は hashes() と同じ規則（'str' は NAME、'num' は NAME#）で DBI の列情報から自動生成して Spool->open に渡す
# spool() は fetch した値の undef を '' へ置き換えてから Spool の add() に渡す
# spool() は prepare() で保持した SQL のトップレベル ORDER BY を解析してソート列を得る。ORDER BY がない SQL は die する
# ORDER BY の解析は大文字小文字や書式の規約に依存しない。位置指定（ORDER BY 1）や式など列名として解決できない指定、SELECT 句の列に存在しない列は die する。文字列リテラル・コメント・括弧内（サブクエリ等）の ORDER BY はトップレベルとして扱わない
# DBOBJ は渡された SQL を書き換えない。ORDER BY の自動付与はしない
# 解析で得たソート列は ordercols として内部状態に保持し、Spool の records 確定のキー列として利用・検証できる形にする。解析をすり抜けた順序違反は Spool 側の再出現 die が二段目の安全網として捕まえる
# psql(sqlfile) は dbname と PGHOST, PGPORT, PGUSER, PGPASSWORD を使って psql を別プロセスで起動する。sqlfile が存在しない場合は die する。SQL エラー時に非 0 終了する設定で起動し、NOTICE では終了しない。終了コードが 0 以外の場合は die する
# close() は DB 接続を閉じる
```
