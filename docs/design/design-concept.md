# Design Concept
Date: 2026-04-08

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

## TODO

### 未実装仕様：TableTools の meta に `count` を追加する

これは未実装だが、将来の仕様として先に定めておく。

- TableTools の `meta` には `count` を必須項目として持たせる
- `count` はデータ行数であり、meta 自身は数えない
- `validate()` は rows を検証し終えた時点で `count` を必ず計算して `meta->{'#'}{count}` に入れる
- `order` は任意だが、`count` は必須とする
- `attach()` / `detach()` は `count` を含む meta をそのまま扱う
- `orderby()` は件数が変わらないため `count` を変更しない
- `group()` は結果の構造が変わるため `count` を再計算する
- `expand()` は結果の件数が変わるため `count` を再計算する
- 0件の場合は従来どおり `[]` を返し、meta は持たない

この TODO を実装した後、その内容を `Concept`、`API`、`Rules` に反映する。

## Concept

### 第一コンセプト：DBI の薄いラッパー

DBI をそのまま使うには冗長な手順が多い。DBOBJ は DBI を簡潔なオブジェクトに包み、SQL を書いてすぐ使える形にする。

データ取得は次の4形式に限定する。

- `get()` ― スカラー1値
- `list()` ― 単一カラム全件をフラット配列で
- `arrays()` ― 全件を AoA で
- `hashes()` ― 全件をメタ付き AoH で。メタ行に件数（`count`）を持つ

グループ化は呼び出し側が TableTools の `group()` で行う。

出力は TableTools・Spool の規約に可能な限り合わせる。ただし TableTools の `validate()` は使わない。DB のステートメントハンドルから得られるカラム情報（名前・型・順序）で meta を組み立てる。`hashes()` は 0件なら `[]` を返し、meta も含まない。

DB から取得した値に `undef` が含まれていた場合は、返却時にすべて空文字 `''` に置き換える。

`attrs` の型判定は DBI の型情報をもとに行う。REAL・INTEGER・NUMERIC 系（`smallint`、`integer`、`bigint`、`real`、`double precision`、`numeric` など）は `'num'`、それ以外はすべて `'str'` とする。

接続オブジェクトの内部状態は次のとおり。

```perl
{
    dbname => $dbname,  # データベース名
    dbh => $dbh,     # DBI データベースハンドル
    sth => undef,    # 実行済みステートメントハンドル
}
```

- 接続は `new($dbname)` でのみ行う
- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` を使い、`PGDATABASE` は参照しない
- DBI の自動例外は使わず、エラーは手動検知して `die` する
- 呼び出し順序や結果セット消費などの挙動は DBI の仕様に従い、独自に制御しない

### 第二コンセプト：psql との連動

SQL ファイルを psql プロセス経由で実行できる。DBI では扱いにくい DDL・トランザクション・`\copy` などを psql に任せることができ、DBOBJ と psql を組み合わせた運用を想定している。

### 第三コンセプト：Spool への書き出し

`spool($spool_id)` はクエリ結果を Spool.pm 経由で `/tmp/spool/<spool_id>` に書き出す。結果をメモリに展開しないため、親プロセスのメモリが膨らまず、フォーク後の子プロセスもスプールから読める。

## API
記号は次のとおり。

- `$dbname`: 接続先 PostgreSQL データベース名
- `$sql`: SQL 文字列
- `@bind`: バインド値のリスト
- `$spool_id`: スプールの識別子（英数字）。`/tmp/spool/<spool_id>` に対応
- `$sqlfile`: SQL が記述されたファイルのパス
- `meta`: `hashes()` の先頭要素に置くメタデータ。`attrs`、`order`、`count` を持つ

| API | 役割 | 入力 | 出力 |
|---|---|---|---|
| `new($dbname)` | 接続・生成 | `$dbname` | `DBOBJ` |
| `prepare($sql)` | プリペア | `$sql` | `$self` |
| `execute(@bind)` | 実行 | `@bind` | `$self` |
| `run($sql)` | bind なしの prepare + execute | `$sql` | `$self` |
| `get()` | スカラー1値取得 | ― | 1値 |
| `list()` | 単一カラム全件 | ― | フラット配列 |
| `arrays()` | 全件（AoA） | ― | `[]` または AoA |
| `hashes()` | 全件（メタ付き AoH） | ― | `[]` または `[meta, rows...]` |
| `spool($spool_id)` | Spool への書き出し | `$spool_id` | ― |
| `psql($sqlfile)` | SQL ファイル実行 | `$sqlfile` | ― |
| `close()` | DB 接続を閉じる | ― | ― |

## 廃止メソッド

廃止メソッド一覧は [deprecated-methods.md](/Users/darong/PRJDEV/DBOBJ/docs/design/deprecated-methods.md) を参照する。

## Rules
```perl
# Terms:
# DBOBJ は DBI の薄いラッパーであり、DBI の挙動を独自に作り替えない
# データ取得は get(), list(), arrays(), hashes(), spool() に限定する
# DB から取得した値に undef が含まれていた場合は、返却時に '' へ置き換える
# AoH  : ハッシュリファレンスの配列リファレンス
# AoA  : 配列リファレンスの配列リファレンス
# meta : メタ付き AoH の先頭に置くハッシュリファレンス。形式は次のとおり
#   {'#' => {
#       attrs => {col => 'str', ...},  # カラム名と型（'str' または 'num'）
#       order => ['col', ...],         # カラムの並び順
#       count => N,                    # 件数
#   }}
# dbname   : 接続先 PostgreSQL データベース名
# spool_id : スプールの識別子（英数字）。/tmp/spool/<spool_id> に対応
#
# Rules:
# new() に dbname（接続先 PostgreSQL データベース名）は必須。PGHOST, PGPORT, PGUSER, PGPASSWORD は必須。PGDATABASE 環境変数は参照しない
# DBI の自動例外は無効にし、エラーは手動検知して die する
# DB から取得した値に undef が含まれていた場合は、get(), list(), arrays(), hashes(), spool() の返却時に '' へ置き換える
# prepare() -> execute() の呼び出し順序、取得系 API の結果セット消費、呼び出し順序に関する挙動は DBI の仕様に従う。DBOBJ は独自に制御しない
# run(sql) は bind を取らない。bind が必要な場合は prepare(sql) -> execute(@bind) を使う
# attrs の型は DBI の型情報をもとに判定する。REAL・INTEGER・NUMERIC 系（smallint, integer, bigint, real, double precision, numeric など）は 'num'、それ以外は 'str'
# get() は結果が 1行1列でない場合 die する。0行でも複数行でも複数列でも die する
# list() は結果が 1列でない場合 die する
# arrays() は 0件なら [] を返す
# hashes() は先頭に meta を持つメタ付き AoH で返す。0件なら [] を返す（meta も含まない）。count はデータ行数であり、meta 自身は数えない
# グループ化は TableTools の group() で行う。DBOBJ は関与しない
# psql(sqlfile) は dbname と PGHOST, PGPORT, PGUSER, PGPASSWORD を使って psql を別プロセスで起動する。sqlfile が存在しない場合は die する。SQL エラー時に非 0 終了する設定で起動し、NOTICE では終了しない。終了コードが 0 以外の場合は die する
# spool(spool_id) は 0件でも spool を作成し、attrs と order を保持し、count は 0 とする。Spool->open(spool_id) で開き、全行を add() した後に Spool->meta() で meta を渡して close() する。結果をメモリに展開しない
# close() は DB 接続を閉じる
```
