# DBOBJ

[English version](README.md)

Perl 向けの軽量 PostgreSQL データアクセスオブジェクト。DBI をシンプルで一貫した API でラップします。

## 必要環境

- Perl 5
- DBI, DBD::Pg
- `psql` コマンド（`psql()`・`in()` が使用）
- PostgreSQL 環境変数: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`
- `lib/MetaAoh.pm`・`lib/CommonIO.pm`・`lib/Spool.pm`（`lib/` に同梱）
- ログディレクトリ `output/logs` が実行時に存在すること（CommonIO が使用）

## インストール

`src/DBOBJ.pm` をプロジェクトの `lib/` ディレクトリにコピーします。
このファイルには `DBOBJ::Psql` パッケージも含まれており、1ファイルだけで完結します。

## API

| メソッド | 説明 |
|---|---|
| `new($dbname)` | PostgreSQL データベースに接続 |
| `prepare($sql)` | SQL 文をプリペア |
| `execute(@bind)` | バインド値を指定して実行 |
| `run($sql)` | バインドなしでプリペア＆実行 |
| `get()` | 1行1列をスカラーで取得 |
| `list()` | 単一カラムの全行をフラット配列で取得 |
| `arrays()` | 全行を AoA（配列の配列）で取得 |
| `hashes()` | 全行を metaAoh（MetaAoh オブジェクト）で取得 |
| `hashing()` | 全行を素の AoH で取得（**非推奨・レガシー対応専用** — 新規は `hashes()` を使う） |
| `spool($spool_id, @confirm)` | 全行を Spool へ退避・確定して spool_id を返す |
| `psql($sqlfile)` | SQL ファイルを psql サブプロセスで実行 |
| `in($dir, $tbl)` | テーブル一式（DDL・TSV・keys）を psql 経由で DB へ投入 |
| `close()` | データベース接続を閉じる |

psql 連動の実体は同一ファイル内の `DBOBJ::Psql` パッケージが持ちます。単独利用は
想定しておらず、`new()` で作った DBOBJ オブジェクトを経由する道筋だけをサポートします。

## 使い方

```perl
use DBOBJ;

my $db = DBOBJ->new('mydb');

# スカラー1値
$db->run("SELECT COUNT(*) FROM orders");
my $count = $db->get();

# フラット配列
$db->run("SELECT name FROM users ORDER BY name");
my @names = $db->list();

# 配列の配列
$db->run("SELECT id, name FROM users");
my $rows = $db->arrays();  # [[1, 'Alice'], [2, 'Bob']]

# metaAoh（MetaAoh オブジェクト）
$db->run("SELECT id, name FROM users");
my $m = $db->hashes();
$m->count();              # 2
$m->meta();               # {order=>['id#','name'], cols=>['id','name'], attrs=>{id=>'num',name=>'str'}, grouped=>0}
$m->[0]{name};            # 'Alice'
my $t = $m->group(['id']);  # グループ化は呼び出し側が行う

# バインド変数
$db->prepare("SELECT name FROM users WHERE id = ?");
$db->execute(42);
my $name = $db->get();

# Spool（巨大な結果セットをディスクへ退避して確定まで行う）
$db->run("SELECT dept, id FROM users ORDER BY dept, id");
$db->spool('job001', 'dept');        # records: 連続同一キーのグループ化
$db->run("SELECT id, name FROM users");
$db->spool('job002');                # lines: 行単位・順序不問
$db->run("SELECT dept, id FROM users ORDER BY dept, id");
$db->spool('job003', ['dept']);      # grouping: 階層グループ
my $n = Spool::count('job001');      # 確定済み
my $g = Spool::get('job001', 0);     # [{dept=>..., id=>...}, ...]

# SQL ファイル実行
$db->psql('path/to/schema.sql');

# Table プロジェクトが生成したテーブル一式の投入
# （$dir/users/users.ddl, users.tsv（または users.0000.tsv ...）, users.keys）
$db->in('path/to/tables', 'users');
$db->in('path/to/tables', 'app.users');  # schema 付き

$db->close();
```

## 注意事項

- `NULL` 値はすべて `''`（空文字）として返される
- `get()` は結果が正確に1行1列でない場合 die する
- `list()` は結果が1列でない場合 die する
- `arrays()` は0件なら `[]` を返す
- `hashes()` は0件でも空の metaAoh を返す（`[]` ではない）。カラム情報は保持される
- `spool()` は結果セットをメモリに作らずに 1 行ずつ流し、Spool の確定まで行う。
  確定モードは spool_id の後ろの引数の形で決まる：なし = `lines`、カラム名の並び =
  `records`、配列リファレンスの並び = `grouping`。DBOBJ は列名や並び順を事前に
  チェックしない。ソート済みデータを流すのは呼び出し側の責務で（SQL に `ORDER BY`
  を書く）、違反は実行時に Spool 側の die（キー再出現の検出）が捕まえる。
  DBOBJ は SQL を書き換えない
- 接続情報（`host`・`port`・`user`）は `new()` で一度だけ取り込まれ、その後に
  環境変数が変わっても DBI と psql の接続先は常に一致する。`PGPASSWORD` は
  オブジェクトに保持せず、環境変数のまま psql 子プロセスへ引き継がれる
- `in()` は DDL（`<name>.sql` 優先、なければ `<name>.ddl`。どちらもなければ die）を
  実行し、単一 TSV または `%04d` 連番の TSV を `\copy` で投入し（自動判別。なければ
  スキップ）、`<name>.keys` があれば適用する。各実行は CommonIO の
  `log('info', ...)` で表示される
- エラーは CommonIO の `dying()` 経由で発生し、エラーログを残してから例外を投げる
- psql は `--set ON_ERROR_STOP=1` で起動する。NOTICE はエラーにならない

## テスト

```bash
prove -lr test/
```

環境変数による PostgreSQL 接続が必要です。
