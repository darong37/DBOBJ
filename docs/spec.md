# DBOBJ Spec
Date: 2026-06-12

現在の仕様・出力契約を定義する。設計の意図と用語は
[design-concept.md](design/design-concept.md) を唯一の正解として参照すること。

## 概要

DBOBJ は DBI の薄いラッパーである。PostgreSQL 専用。
DBI の挙動を独自に作り替えず、SQL を書いてすぐ使える形を提供する。

- データ取得は `get()`、`list()`、`arrays()`、`hashes()` の4形式に限定する
- グループ化は呼び出し側が metaAoh の `group()` で行う。DBOBJ は関与しない
- DB から取得した値の `undef`（NULL）は、返却時にすべて空文字 `''` へ置き換える
- 巨大な結果セットは `spool()` で metaAoh を作らずに 1 行ずつ Spool へ退避し、確定（confirm）まで行える（仕様は `lib/Spool.spec.md` に従う）
- psql プロセスとの連動（SQL ファイル実行・テーブル一式投入）は独立パッケージ **DBOBJ::Psql** が担う（`src/DBOBJ.pm` 内に同居。単独利用は想定しない）

CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は `lib/CommonIO.spec.md` に従う。

## 接続

- 接続は `new($dbname)` でのみ行う。`$dbname` は必須
- 環境変数 `PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD` は必須。未設定なら CommonIO の `dying()` で die する
- `PGDATABASE` 環境変数は参照しない
- 接続情報の取り込みは `new()` の1箇所だけで行う。`PGHOST`・`PGPORT`・`PGUSER` は内部状態（`host`・`port`・`user`）へ取り込み、DBI 接続も psql 起動もこの値を使う。`new()` 後に環境変数が変わっても、DBI と psql の接続先は常に一致する
- `PGPASSWORD` は内部状態に保持しない。DBI へは接続時に渡し、psql へは環境変数のまま子プロセスへ引き継ぐ
- DBI の自動例外（`RaiseError`）は無効にし、エラーは手動検知して CommonIO の `dying()` でエラーログを残して die する
- 接続時に `SET client_min_messages = WARNING` を実行する

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
- `$tbl`: テーブル名。`schema.name` 形式を許容し、schema 省略時は `public` とする

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

psql 連動の実体は DBOBJ::Psql（`src/DBOBJ.pm` 内の独立パッケージ）が持つ。DBOBJ の `psql()`・`in()` は `$self` をそのまま渡してこれを呼ぶ。単独利用は想定しない。psql 連動が動く道筋は「`DBOBJ->new($dbname)` で接続オブジェクトを作り、それを経由する」の1本だけである。

| API | 役割 | 入力 | 出力 |
|---|---|---|---|
| `DBOBJ::Psql::run($dbo, @args)` | psql 起動（`-f`・`-c` 等の引数をそのまま渡す） | `$dbo`, `@args` | ― |
| `DBOBJ::Psql::in($dbo, $dir, $tbl)` | テーブル一式（DDL・TSV・keys）の DB 投入 | `$dbo`, `$dir`, `$tbl` | ― |

## 出力契約

### 実行系

- `prepare($sql)` → `execute(@bind)` の呼び出し順序、結果セット消費などの挙動は
  DBI の仕様に従う。DBOBJ は独自に制御しない
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

### spool($spool_id, @confirm)

- 実行済みステートメントハンドルから fetch ループで 1 行ずつ `Spool->open` / `add` / `close` へ流し、続けて Spool の確定（confirm）まで行って `$spool_id` を返す。結果セットを metaAoh や配列としてメモリに作らない
- `Spool->open` に渡す schema（MetaAoh の order 記法）は `hashes()` と同じ規則（`'str'` は `NAME`、`'num'` は `NAME#`）で DBI の列情報から自動生成する
- fetch した値の `undef` は `''` へ置き換えてから `add()` に渡す（Spool の「`undef` は `add()` で die」契約と両立する）
- 確定モードは `@confirm` の形で判別する。Spool の confirm API の引数の形と1対1に対応する

| `@confirm` の形 | 確定 | 意味 |
|---|---|---|
| なし（空） | `Spool::lines($spool_id)` | 行単位の確定。順序不問 |
| 文字列（カラム名）の並び | `Spool::records($spool_id, @confirm)` | 連続同一キーのグループ化。ソート済みが前提 |
| 配列リファレンスの並び | `Spool::grouping($spool_id, @confirm)` | 階層グループの構築 |

- 判別は先頭要素の形のみで行う（配列リファレンスなら `grouping`、文字列なら `records`、空なら `lines`）
- 引数・順序・列名の正しさは事前にチェックしない。schema 外の列名・ソート漏れ（キー再出現）・形の混在は、実行時に Spool / MetaAoh の die が検知する（Spool の confirm は fork 内で行われ、die は `confirm failed` として伝播する）
- 並び順の指定はグループ指定と別には設けない。`records` のキー列の並び・`grouping` の配列リファレンスに出てきた列の並び（level1…level2…の連結順）を、そのままデータに要求される並び順の前提とする。連続性が保たれていれば昇順・降順は問わない
- ソート済みデータを流すのは呼び出し側の責務であり、SQL に `ORDER BY` を書くのはその手段である。DBOBJ は渡された SQL を書き換えず、`ORDER BY` の解析・自動付与もしない
- 0件でも die しない。`open` → `close` → 確定まで行い（Spool の仕様により `close` が warn を出す）、`count == 0` で確定して `$spool_id` を返す
- fetch 中の DBI エラーは `dying()` で die し、Spool 自身の die（spool_id 不正・重複・確定時の検証違反など）はそのまま伝播する

### psql($sqlfile)

- `DBOBJ::Psql::run($self, '-f', $sqlfile)` を呼ぶ
- 事前のファイル存在チェックはしない。ファイル不在は psql 自身が非 0 終了で検知し、終了コード経由で die する

### in($dir, $tbl)

- `DBOBJ::Psql::in($self, $dir, $tbl)` を呼び、`$self` を返す（メソッドチェーン可能）
- 処理手順（`DBOBJ::Psql::in` の仕様）:
  1. **schema 分離**: `$tbl` が `schema.name` 形式（`/^(\w+)\.(\w+)$/`）なら schema と name に分離する。形式でなければ schema は `public`、name は `$tbl` のまま。ディレクトリ名・ファイル名には name 部分のみを使う
  2. **DDL 実行**: `$dir/<name>/<name>.sql` を優先し、なければ `$dir/<name>/<name>.ddl` を使う。どちらも存在しなければ die する。決定した DDL ファイルを `-f` で実行する
  3. **データ投入（`\copy`）— 自動判別**: `$dir/<name>/<name>.tsv` が存在すればそれを投入する（単一 TSV）。なければ `<name>.0000.tsv` から連番（`%04d`）で存在するファイルを順に投入し、番号が途切れたところで終了する（分割 TSV）。どちらも存在しなければ投入をスキップする。`\copy` は `-c` で実行する
  4. **キー付与**: `$dir/<name>/<name>.keys` が存在すれば `-f` で実行する（PRIMARY KEY・UNIQUE・INDEX）。存在しなければスキップする
- 各 psql 実行の前に、実行内容（`sql> \i <file>` / `sql> copy <schema>.<name> from <file>`）を CommonIO の `log('info', ...)` で表示する
- TSV は `\copy` のデフォルト形式（タブ区切り・`\N` = NULL）をそのまま使う。Psql 側でオプションは付与しない

### DBOBJ::Psql::run($dbo, @args)

- psql 起動の唯一の入口。接続情報は `$dbo` が `new()` で取り込んだ値（`dbname`・`host`・`port`・`user`）を使う。Psql は `%ENV` を直接読まない（例外は `PGPASSWORD` のみ。環境変数のまま psql 子プロセスへ引き継ぐ）
- `--set ON_ERROR_STOP=1` で起動し、SQL エラー時は非0終了 → `dying()` で die する
- NOTICE は出力されるだけでエラーにならない
- `@args` は psql への追加引数（`-f $sqlfile` または `-c $command`）

### close()

- ステートメントハンドルを finish し、DB 接続を閉じる

## 廃止メソッド

廃止メソッド一覧は [deprecated-methods.md](design/deprecated-methods.md) を参照する。
