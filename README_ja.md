# DBOBJ

[English version](README.md)

Perl 向けの軽量 PostgreSQL データアクセスオブジェクト。DBI をシンプルで一貫した API でラップします。

## 必要環境

- Perl 5
- DBI, DBD::Pg
- PostgreSQL 環境変数: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`
- `lib/MetaAoh.pm` および `lib/CommonIO.pm`（`lib/` に同梱）
- ログディレクトリ `output/logs` が実行時に存在すること（CommonIO が使用）

## インストール

`src/DBOBJ.pm` をプロジェクトの `lib/` ディレクトリにコピーします。

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
| `psql($sqlfile)` | SQL ファイルを psql サブプロセスで実行 |
| `close()` | データベース接続を閉じる |

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

# SQL ファイル実行
$db->psql('path/to/schema.sql');

$db->close();
```

## 注意事項

- `NULL` 値はすべて `''`（空文字）として返される
- `get()` は結果が正確に1行1列でない場合 die する
- `list()` は結果が1列でない場合 die する
- `arrays()` は0件なら `[]` を返す
- `hashes()` は0件でも空の metaAoh を返す（`[]` ではない）。カラム情報は保持される
- エラーは CommonIO の `dying()` 経由で発生し、エラーログを残してから例外を投げる
- `psql()` は `--set ON_ERROR_STOP=1` を使用。NOTICE はエラーにならない

## テスト

```bash
prove -lr test/
```

環境変数による PostgreSQL 接続が必要です。
