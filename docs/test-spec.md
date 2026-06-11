# DBOBJ Test Spec
Date: 2026-06-12

テストスイートの仕様を定義する。仕様本体は [spec.md](spec.md) を参照すること。

## テスト方針

- 実 PostgreSQL DB（`develop`）を使う結合テスト。モックは使わない
- テーブルは `CREATE TEMP TABLE` で作成し、テーブル名にプロセス ID を含めて
  他テストとの衝突を避ける（`in()` のテストは psql 別プロセスが投入するため
  実テーブルを作成し、subtest 内で DROP して後始末する）
- 環境変数（`PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD`）が設定済みであること。
  定義元は `.claude/settings.json` の `env` とする
- spool_id にはプロセス ID を含めて他テストとの衝突を避け、テストで作成した spool は
  `Spool::remove` で後始末する
- `in()` テスト用のテーブル一式（DDL・TSV・keys）は `File::Temp` の一時ディレクトリに
  テスト内で生成する（ヘルパー `mkset`。テスト終了時に自動削除）
- テストは DBOBJ の公開 API 経由で行い、DBOBJ::Psql・Spool 連動はその経路で検証する
- 日本語（UTF-8）データが DB のカラム値として化けずに通ることを検証に含める（テストポリシーの DB 要件）

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
| 20 | `psql` でファイル不在の場合 `die`（psql 自身の非 0 終了による） |
| 21 | `psql` で終了コード非0の場合 `die` |
| 22 | `psql` で NOTICE が出ても die しないこと |
| 23 | `hashes` の返り値に対して呼び出し側で `group()` が機能すること（DBOBJ の出力が MetaAoh の前提条件を満たす統合確認） |
| 24 | records 確定：`spool($spool_id, 'dept')` が確定まで行い `$spool_id` を返すこと。`Spool::count` / `get` で内容が DB と一致すること |
| 25 | lines 確定：引数なしの `spool($spool_id)` が `ORDER BY` のない SQL でも通り、行単位の item で確定すること |
| 26 | grouping 確定：`spool($spool_id, ['dept'])` が階層 item（キー列 + `'*'` 配下）で確定すること |
| 27 | schema 生成：spool の `meta.do` の `order` が num カラム `NAME#`・str カラム `NAME` の規則で生成されていること |
| 28 | NULL を含む行が `''` へ置き換えられて spool され、取得値が `''` であること |
| 29 | ソート漏れ：キー順に並んでいないデータの `records` 確定が die すること（Spool のキー再出現 die） |
| 30 | grouping の順序違反：グループ列が連続していないデータの `grouping` 確定が die すること |
| 31 | schema 外の列名指定で die すること（Spool 側の検知） |
| 32 | 形の混在（文字列と配列リファレンス）で die すること（Spool 側の検知） |
| 33 | `prepare` + `execute`（bind 付き）経由の `spool()` が動作すること |
| 34 | `prepare` を経ずに `spool()` を呼ぶと die すること |
| 35 | 0件の結果でも確定でき、`count == 0` となること |
| 36 | 既存の spool_id と重複した場合に die すること（Spool の die が伝播） |
| 37 | 単一 TSV：`in($dir, $tbl)` が DDL 実行・`\copy` 投入・keys 付与を行い、投入した行数・内容が DB と一致すること。戻り値が `$self` であること |
| 38 | 分割 TSV：`$tbl.0000.tsv`・`$tbl.0001.tsv` を順に投入し、全行が DB に入ること。番号が途切れたところで終了すること（`0003.tsv` だけ置いても投入されないこと） |
| 39 | `schema.name` 形式：schema 付きテーブルへ投入され、ディレクトリ名・ファイル名には name 部分のみが使われること |
| 40 | DDL の優先順：`$tbl.sql` と `$tbl.ddl` の両方があるとき `$tbl.sql` が使われること |
| 41 | DDL ファイルがどちらも存在しない場合に die すること（`Psql.in` の die） |
| 42 | TSV が存在しない場合は投入をスキップし、die しないこと（テーブルは 0 件で作成される） |
| 43 | keys ファイルが存在しない場合はスキップし、die しないこと |
| 44 | keys ファイルが存在する場合に PRIMARY KEY が付与されること |
| 45 | DDL の SQL エラー（不正な SQL）で die すること（`ON_ERROR_STOP=1` の検証） |
| 46 | `\copy` の失敗（TSV の列数不一致など）で die すること |
| 47 | 日本語データ（マルチバイト文字）が化けずに DB のカラム値として取得できること |
| 48 | NULL（`\N`）を含む TSV が投入でき、取得時に既存規則で `''` へ置き換えられること |
| 49 | `new()` 後に `PGHOST`・`PGPORT`・`PGUSER` を壊しても `psql()` が動くこと（DBI と psql の接続情報が `new()` 時の取り込み値で連動していることの検証） |
