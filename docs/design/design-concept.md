# Design Concept
Date: 2026-06-12

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
    host => $host,    # 接続先ホスト（new() 時に PGHOST から取り込む）
    port => $port,    # 接続先ポート（new() 時に PGPORT から取り込む）
    user => $user,    # 接続ユーザー（new() 時に PGUSER から取り込む）
    dbh => $dbh,      # DBI データベースハンドル
    sth => undef,     # 実行済みステートメントハンドル
}
```

- 接続は `new($dbname)` でのみ行う
- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` を使い、`PGDATABASE` は参照しない
- 接続情報の取り込みは `new()` の1箇所だけで行う。`PGHOST`・`PGPORT`・`PGUSER` は内部状態（`host`・`port`・`user`）へ取り込み、DBI 接続も psql 起動もこの値を使う
- DBI の自動例外は使わず、エラーは手動検知して CommonIO の `dying()` でエラーログを残して die する
- 呼び出し順序や結果セット消費などの挙動は DBI の仕様に従い、独自に制御しない

CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は `lib/CommonIO.spec.md` に従う。

### 第二コンセプト：psql との連動

SQL ファイルを psql プロセス経由で実行できる。DBI では扱いにくい DDL・トランザクション・`\copy` などを psql に任せることができ、DBOBJ と psql を組み合わせた運用を想定している。

DBI でやるもの（接続・SQL 実行・取得系）と psql プロセスでやるものは責務が別であるため、psql 連動の実体は独立パッケージ **DBOBJ::Psql** が担う。パッケージは分離するが、ファイルは `src/DBOBJ.pm` 1つにまとめ、その中に `package DBOBJ::Psql` として置く。bind の配布単位（`lib/DBOBJ.pm` 1ファイル）を保ち、消費側プロジェクトでのファイル追加・版ズレを避けるためである。`use DBOBJ` だけで DBOBJ::Psql もロードされる。

Psql の単独利用は想定しない。psql 連動が動く道筋は「`DBOBJ->new($dbname)` で接続オブジェクトを作り、それを経由する」の1本だけである。psql の起動（`ON_ERROR_STOP=1`：SQL エラー時に非 0 終了、NOTICE では終了しない。終了コード非 0 での `dying()`）は `DBOBJ::Psql::run` に集約し、接続情報は DBOBJ オブジェクトが `new()` で取り込んだ値（`dbname`・`host`・`port`・`user`）を使う。Psql は `%ENV` を直接読まない。例外は `PGPASSWORD` のみで、オブジェクトには保持せず環境変数のまま psql 子プロセスへ引き継ぐ。これにより `new()` 後に環境変数が変わっても、DBI と psql の接続先は常に一致する。Psql は内部関数を持たない。事前検証はせず、ファイル不在や SQL の誤りは psql 自身の非 0 終了で検知する。

`DBOBJ::Psql::in($dbo, $dir, $tbl)` はこのコンセプトの具体化であり、Table プロジェクトが生成するテーブル一式（`$dir` 配下の DDL・TSV・keys ファイル）を psql 経由で DB へ一括投入する。DDL 実行（CREATE TABLE 等）、TSV の `\copy` 投入（単一・分割をファイルの存在から自動判別）、keys ファイルの実行（PRIMARY KEY・UNIQUE・INDEX）の順に処理する。`$tbl` は `schema.name` 形式を許容し、schema 省略時は `public` とする。各 psql 実行の前に、実行内容を CommonIO の `log('info', ...)` で表示する。

DBOBJ の `psql($sqlfile)`・`in($dir, $tbl)` は、`$self` をそのまま渡して Psql を呼ぶ公開 API である。

### 第三コンセプト：Spool との連動

巨大な結果セットを metaAoh としてメモリに作らず、fetch ループで 1 行ずつ Spool へ退避できる。Spool の扱いは Spool（`lib/Spool.pm`）に従う。仕様は `lib/Spool.spec.md` を参照する。

`spool($spool_id, @confirm)` は実行済みステートメントハンドルから 1 行ずつ `Spool->open` / `add` / `close` へ流し、続けて Spool の確定（confirm）まで行って `$spool_id` を返す。確定モードは `@confirm` の形で判別し、Spool の confirm API の引数の形と1対1に対応する。空なら `lines`（行単位・順序不問）、文字列（カラム名）の並びなら `records`（連続同一キーのグループ化）、配列リファレンスの並びなら `grouping`（階層グループ）。

schema（MetaAoh の order 記法）は `hashes()` と同じ規則で DBI の列情報から自動生成する。`undef` は既存取得系と同じ規則で fetch 時に `''` へ置き換えてから Spool へ渡す。これにより Spool の「`undef` は `add()` で die」契約と両立する。

ソート済みデータを流すのは呼び出し側の責務であり、SQL に `ORDER BY` を書くのはその手段である。DBOBJ は引数・順序・列名の正しさを事前にチェックしない。誤りは実行時に Spool / MetaAoh の die が検知する（schema 外の列名、キー再出現によるソート漏れの検出など）。並び順の指定はグループ指定と別には設けない。`records` のキー列の並び・`grouping` の配列リファレンスに出てきた列の並び（level1…level2…の連結順）を、そのままデータに要求される並び順の前提とする。実行時の実体は Spool の累積キー組の連続性チェックであり、連続性が保たれていれば昇順・降順は問わない。DBOBJ は渡された SQL を書き換えない。

## API
記号は次のとおり。

- `$dbname`: 接続先 PostgreSQL データベース名
- `$dbo`: 接続済みの DBOBJ オブジェクト（`new($dbname)` の戻り値）
- `$sql`: SQL 文字列
- `@bind`: バインド値のリスト
- `$sqlfile`: SQL が記述されたファイルのパス
- `metaAoh`: MetaAoh オブジェクト。meta（`order`・`cols`・`attrs`・`grouped`）を持ち、件数は `count()` メソッドで得る
- `$spool_id`: Spool の spool_id（`[A-Za-z0-9]+`。仕様は `lib/Spool.spec.md` に従う）
- `@confirm`: spool の確定モード指定。空 = `lines`、文字列（カラム名）の並び = `records`、配列リファレンスの並び = `grouping`
- `$dir`: テーブル一式の親ディレクトリ。ファイルは `$dir/<name>/` 配下に置かれている
- `$tbl`: テーブル名。`schema.name` 形式を許容し、schema 省略時は `public` とする。`schema.name` 形式のときはディレクトリ名・ファイル名には name 部分のみを使う

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
| `spool($spool_id, @confirm)` | 全件を Spool へ退避し確定する | `$spool_id`, `@confirm` | `$spool_id` |
| `psql($sqlfile)` | SQL ファイル実行 | `$sqlfile` | ― |
| `in($dir, $tbl)` | テーブル一式（DDL・TSV・keys）の DB 投入 | `$dir`, `$tbl` | `$self` |
| `close()` | DB 接続を閉じる | ― | ― |

### Psql パッケージ

psql 連動の実体は DBOBJ::Psql（`src/DBOBJ.pm` 内の独立パッケージ）が持つ。DBOBJ の `psql()`・`in()` は `$self` をそのまま渡してこれを呼ぶ。単独利用は想定しない。

| API | 役割 | 入力 | 出力 |
|---|---|---|---|
| `DBOBJ::Psql::run($dbo, @args)` | psql 起動（`-f`・`-c` 等の引数をそのまま渡す） | `$dbo`, `@args` | ― |
| `DBOBJ::Psql::in($dbo, $dir, $tbl)` | テーブル一式（DDL・TSV・keys）の DB 投入 | `$dbo`, `$dir`, `$tbl` | ― |

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
# dbo     : 接続済みの DBOBJ オブジェクト（new(dbname) の戻り値）
# spool_id : Spool の spool_id（[A-Za-z0-9]+）。仕様は lib/Spool.spec.md に従う
# confirm : spool() の確定モード指定。空 = lines、文字列（カラム名）の並び = records、配列リファレンスの並び = grouping
# Psql    : psql プロセス連動の独立パッケージ DBOBJ::Psql（src/DBOBJ.pm 内に置く）。run と in を持ち、内部関数を持たない。Rules では DBOBJ::Psql を Psql と略記する
#
# Rules:
# CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は lib/CommonIO.spec.md に従う
# new() に dbname（接続先 PostgreSQL データベース名）は必須。PGHOST, PGPORT, PGUSER, PGPASSWORD は必須。PGDATABASE 環境変数は参照しない
# 接続情報の取り込みは new() の1箇所だけで行う。PGHOST, PGPORT, PGUSER は内部状態（host, port, user）へ取り込み、DBI 接続も psql 起動もこの値を使う
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
# spool(spool_id, @confirm) は実行済みステートメントハンドルから fetch ループで 1 行ずつ Spool->open / add / close へ流し、続けて Spool の確定まで行って spool_id を返す。結果セットを metaAoh としてメモリに作らない
# spool() の schema は hashes() と同じ規則（'str' は NAME、'num' は NAME#）で DBI の列情報から自動生成して Spool->open に渡す
# spool() は fetch した値の undef を '' へ置き換えてから Spool の add() に渡す
# spool() の確定モードは @confirm の形で判別する。空なら lines、文字列（カラム名）の並びなら records、配列リファレンスの並びなら grouping。判別は先頭要素の形のみで行う
# spool() は引数・順序・列名の正しさを事前にチェックしない。schema 外の列名・ソート漏れ（キー再出現）・形の混在などの誤りは、実行時に Spool / MetaAoh の die が検知する
# 並び順の指定はグループ指定と別には設けない。records のキー列の並び・grouping の配列リファレンスに出てきた列の並び（level1…level2…の連結順）を、そのままデータに要求される並び順の前提とする。連続性が保たれていれば昇順・降順は問わない
# DBOBJ は渡された SQL を書き換えない
# psql プロセスの起動は Psql::run(dbo, @args) に集約する。接続情報は dbo が new() で取り込んだ値（dbname, host, port, user）を使い、SQL エラー時に非 0 終了する設定（ON_ERROR_STOP=1）で起動し、NOTICE では終了しない。終了コードが 0 以外の場合は die する
# Psql の単独利用は想定しない。psql 連動は DBOBJ->new で作った接続オブジェクト経由の1本だけとする
# Psql は %ENV を直接読まない。例外は PGPASSWORD のみで、オブジェクトには保持せず環境変数のまま psql 子プロセスへ引き継ぐ
# 事前検証はしない。sqlfile の不在や SQL の誤りは psql 自身が非 0 終了で検知し、終了コード経由で die する
# DBOBJ の psql(sqlfile) は Psql::run('-f') を、in(dir, tbl) は Psql::in を、$self をそのまま渡して呼び、$self を返す
# Psql::in(dbo, dir, tbl) は dir 配下のテーブル一式（DDL・TSV・keys）を psql 経由で DB へ投入する
# Psql::in の tbl が schema.name 形式（/^(\w+)\.(\w+)$/）なら schema と name に分離する。形式でなければ schema は public、name は tbl のまま。ディレクトリ名・ファイル名には name 部分のみを使う
# Psql::in の DDL は dir/name/name.sql を優先し、なければ dir/name/name.ddl を使う。どちらも存在しなければ die する。決定した DDL ファイルを -f で実行する
# Psql::in のデータ投入は dir/name/name.tsv が存在すればそれを \copy schema.name from ... で投入する（単一 TSV）。なければ dir/name/name.0000.tsv から連番（%04d）で存在するファイルを順に \copy で投入し、番号が途切れたところで終了する（分割 TSV）。どちらも存在しなければ投入をスキップする。\copy は -c で実行する
# Psql::in は dir/name/name.keys が存在すれば -f で実行する。存在しなければスキップする
# Psql::in は各 psql 実行の前に、実行内容を CommonIO の log('info', ...) で表示する
# close() は DB 接続を閉じる
```
