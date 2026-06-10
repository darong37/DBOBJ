# DBOBJ Design Spec
Date: 2026-04-05

## 概要

PostgreSQL 専用の軽量データアクセスモジュール。SQL をシンプルに実行し、用途に応じた形式（配列・ハッシュ・ストリーミング・TableTools 形式等）で結果を取得できる。psql との併用を想定した設計。

## アーキテクチャ

単一モジュール `DBOBJ.pm` にすべての機能を実装する。

### 内部状態

```perl
{
    dbn   => $dbname,  # データベース名（psql 等で再利用）
    dbh   => $dbh,     # DBI データベースハンドル
    sth   => undef,    # 実行済みステートメントハンドル
    state => undef,    # 状態管理（'prepared' | 'executed' | undef）
}
```

### 接続

- `new($dbname)` の第一引数 `$dbname` は**必須**
- `PGDATABASE` 環境変数は参照しない
- 以下の環境変数は必須。未設定の場合は `die`

| 環境変数 | 用途 |
|---|---|
| `PGHOST` | ホスト |
| `PGPORT` | ポート |
| `PGUSER` | ユーザー |
| `PGPASSWORD` | パスワード |

### DBI 設定

```perl
RaiseError        => 0
PrintError        => 0
pg_enable_utf8    => 1
AutoInactiveDestroy => 1
```

接続後に `SET client_min_messages = WARNING` を実行する。

## API

### 接続・実行系

| メソッド | シグネチャ | 戻り値 | 動作 |
|---|---|---|---|
| `new` | `new($dbname)` | `DBOBJ` | 接続・オブジェクト生成 |
| `prepare` | `prepare($sql)` | `$self` | SQL をプリペア（バインド変数用） |
| `execute` | `execute(@bind)` | `$self` | プリペア済み SQL をバインド値で実行 |
| `run` | `run($sql)` | `$self` | prepare + execute のショートハンド（バインドなし） |

### ストリーミング系（1行ずつ取得）

| メソッド | シグネチャ | 戻り値 | 動作 |
|---|---|---|---|
| `fetch` | `fetch()` | `arrayref \| undef` | 1行を配列リファレンスで取得。終端で `undef` |
| `fetch_hr` | `fetch_hr()` | `hashref \| undef` | 1行をハッシュリファレンスで取得。終端で `undef` |
| `fetch_group` | `fetch_group(@key_cols)` | `hashref \| undef` | 取得順のまま走査し、`@key_cols` の値が変わるまでの行を1グループとして返す（`'@'` キーに子行リスト）。終端で `undef` |

`fetch_group` の返値イメージ（キー列: `filepath`）:
```perl
{ filepath => 'a.txt', '@' => [ {line => 1}, {line => 2} ] }
```

#### グループ化の内部構造

`fetch_group()` と `groups()` は共通の内部関数群で構成する。

| 内部関数 | 責務 |
|---|---|
| `_next_row()` | 次の1行を取得し、NULL 正規化（`undef` → `''`）まで行う。終端で `undef` |
| `_group(@key_cols)` | `_next_row` を使って現在位置から `@key_cols` の値が変わるまでを1グループとして組み立て返す。直前に読んだ「次グループ先頭行」を内部バッファに保持する |
| `fetch_group(@key_cols)` | `_group` の結果を1件返す公開 API |
| `groups(@key_cols)` | `_group` を繰り返し呼び出して全件を返す。過去に出現したキーが後続グループで再出現した場合は並び順不正として `die` |

**呼び出し側と DBOBJ の責務分担：**

- 呼び出し側：SQL に `ORDER BY @key_cols` を付けること
- DBOBJ：その順序を前提に逐次グループ化すること

**`fetch_group()` の制限事項：**  
SQL が `@key_cols` でソートされていない場合、同一キーのグループが複数に分断されても `die` しない。分断は `fetch_group()` の利用者責任とする。

**`groups()` の追加検証：**  
全体を一括取得できるため、過去に出現済みのキーが後続グループで再出現した場合を並び順不正と判定して `die` する。

TableTools の `group` は主処理には使用しない。グループ化の核は DBOBJ 内の `_next_row` / `_group` で完結する。TableTools は補助的な用途（メタ情報の `attach` 等）にのみ使用する可能性がある。

### 一括取得系

| メソッド | シグネチャ | 戻り値 | 動作 |
|---|---|---|---|
| `list` | `list()` | `@array` | 単一カラムの全値をフラット配列で返す |
| `hashes` | `hashes()` | `arrayref（TableTools形式）` | 全行を TableTools 形式で返す（先頭要素がメタ行） |
| `groups` | `groups(@key_cols)` | `arrayref` | 取得順のまま全行をグループ化して一括返却。同一キーが非連続に再出現した場合は並び順不正として `die` |
| `get` | `get()` | `scalar` | 単一値取得。結果が1行1列である場合のみ値を返し、それ以外はすべて `die` |

#### TableTools 形式（`hashes` の返値）

```perl
[
  { '#' => { attrs => { col => 'str'|'num', ... }, order => [...] } },  # メタ行
  { col1 => val1, col2 => val2, ... },  # データ行
  ...
]
```

### ユーティリティ

| メソッド | シグネチャ | 戻り値 | 動作 |
|---|---|---|---|
| `rows` | `rows()` | `int` | DML（INSERT/UPDATE/DELETE）の影響行数を返す。SELECT に対する値は保証しない |
| `psql` | `psql($file)` | ― | .sql ファイルを psql 別プロセスで実行 |
| `close` | `close()` | ― | sth・dbh をクローズ |

`psql` は `dbn` を使って接続し、`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` 環境変数を利用する。

## エラー処理

DBI の自動例外は無効（`RaiseError => 0, PrintError => 0`）。エラーは手動検知して `die`。

| 状況 | メッセージ例 |
|---|---|
| 必須環境変数が未設定 | `PGHOST is not set` |
| `new()` に dbname が未指定 | `dbname is required` |
| DB 接続失敗 | `DBOBJ.new: <DBI error>` |
| SQL 実行失敗 | `DBOBJ.run: <DBI error>` |
| `get()` で結果が1行1列でない | `DBOBJ.get: expected 1 row and 1 col, got N rows M cols` |
| `psql()` でファイルが存在しない | `DBOBJ.psql: file not found: <path>` |
| `psql()` 実行失敗 | `DBOBJ.psql: exit code N` |
| `execute()` を `prepare()` 前に呼んだ | `DBOBJ.execute: prepare() not called` |
| fetch 系を実行済みクエリなしで呼んだ | `DBOBJ.fetch: no query executed` |
| 不正な状態遷移（その他） | `DBOBJ.<method>: invalid state` |
| `groups()` でキーが非連続に再出現 | `DBOBJ.groups: rows are not ordered by key columns` |

## NULL の正規化

DB から取得した `NULL` は、返却前に DBOBJ 内で空文字 `''` に変換する。返却データ中に `undef` を残さない。

対象メソッド：`fetch`, `fetch_hr`, `fetch_group`, `hashes`, `groups`, `list`, `get`

これにより TableTools の前提（`undef` なし）と整合する。

## 状態遷移

内部状態は `undef` → `prepared` → `executed` の順に遷移する。

```
undef ──prepare()──▶ prepared ──execute()──▶ executed
                                               │
                         ◀──run() で直接遷移──┘
新しい run() または prepare() を呼ぶと前の sth を破棄して再遷移
```

**不正な呼び出しは `die`：**

- `execute()` を `prepare()` 前（state が `prepared` でない）に呼んだ場合
- `fetch()` / `fetch_hr()` / `fetch_group()` を state が `executed` でない状態で呼んだ場合
- `list()` / `hashes()` / `groups()` / `get()` / `rows()` を state が `executed` でない状態で呼んだ場合

**新しい実行で自動リセット：**

- `run()` または `prepare()` を呼ぶと前の `sth` を `finish()` してから破棄し、状態をリセットする

## テスト方針

- 実 PostgreSQL DB を使う結合テスト（モックなし）
- テスト用データベース：`develop`
- 接続：`DBOBJ->new('develop')`
- テスト実行前に環境変数（`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`）が設定済みであること

### テストケース

| # | テスト内容 |
|---|---|
| 1 | 接続成功・`close()` |
| 2 | 環境変数未設定で `die` |
| 3 | dbname 未指定で `die` |
| 4 | `run` + `hashes`（TableTools 形式確認） |
| 5 | `run` + `list`（単一カラム） |
| 6 | `run` + `get`（スカラー1値） |
| 7 | `get` で行数が1でない場合 `die` |
| 8 | `run` + `fetch` ストリーミング |
| 9 | `run` + `fetch_hr` ストリーミング |
| 10 | `run` + `fetch_group`：ORDER BY 済みデータで期待通りのグループが返る |
| 10b | `run` + `fetch_group`：未整列データで同一キーが分断されてもエラーにならない |
| 11 | `run` + `groups`：ORDER BY 済みデータで全件グループ化して返る |
| 11b | `run` + `groups`：同一キーが非連続に再出現した場合に `die` |
| 12 | `run` + `rows` 行数確認 |
| 13 | `prepare` + `execute` バインド変数 |
| 14 | DML（INSERT/UPDATE/DELETE）実行 |
| 15 | `psql($file)` ファイル実行 |
| 16 | DB NULL → 空文字 `''` への正規化確認 |
| 17 | `execute()` を `prepare()` 前に呼んで `die` |
| 18 | fetch 系を実行前に呼んで `die` |
| 19 | `get()` で複数行・複数列の場合 `die` |

## 依存モジュール

- `DBI`
- `DBD::Pg`
- `TableTools`（`lib/` に配置）
