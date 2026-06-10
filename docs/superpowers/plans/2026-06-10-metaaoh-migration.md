# MetaAoh 移行・spool() 廃止 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `hashes()` が metaAoh（MetaAoh オブジェクト）を返すようにし、`spool()` を廃止し、エラー処理を CommonIO の `dying()` に統一する。

**Architecture:** 変更対象は `src/DBOBJ.pm` と `test/dbobj.t` の2ファイルのみ。仕様は [2026-06-10-design.md](../specs/2026-06-10-design.md) と [design-concept.md](../../design/design-concept.md) に従う。テスト先行（red → green）で機能単位に進める。

**Tech Stack:** Perl 5.38.5 / DBI + DBD::Pg / MetaAoh（`lib/`）/ CommonIO（`lib/`）/ Test::More + Test::Exception / 実 PostgreSQL DB `develop`

**運用上の注意（プロジェクトルール優先）:**

- コミットは各タスクでは行わない。全タスク完了 → ユーザーのコードレビュー → **明示的 OK が出てから**まとめてコミットする（CLAUDE.md の規定がテンプレートの frequent commits より優先）
- テスト実行は常に `prove -lr test/`（環境変数は `.claude/settings.json` の `env` から供給。コマンドに直接書かない）
- `lib/` のファイルは変更しない（ユーザー管理）
- `lib/MetaAoh.spec.md`・`lib/CommonIO.spec.md` を実装前に読むこと（参照ルール）
- CommonIO は `LOGDIR`（`output/logs`、相対パス）の実在を要求する。存在しないと **compile 時に die** する。ディレクトリは作成済みだが git 管理外なので、新規環境では `mkdir -p output/logs` が必要（appset 化はユーザー判断）

**テスト番号の対応（変更仕様書のテストケース表に合わせる）:**

| 旧 spec# | 新 spec# | 内容 |
|---|---|---|
| 1〜10 | 1〜10 | 変更なし |
| 11 | 11・12 | metaAoh 返却検証と meta 内容検証に分割 |
| 12 | 13 | hashes 0件 → 空の metaAoh に変更 |
| 13 | 14 | NULL → ''（hashes の行アクセスを変更） |
| 14〜21 | 15〜22 | 番号のみ繰り下げ |
| 22〜24 | （削除） | spool 系テスト |
| ― | 23 | group() 統合確認（新規） |

---

### Task 1: hashes() の metaAoh 化

**Files:**
- Modify: `test/dbobj.t`（旧 spec#11〜13 の subtest を置換、spec#14 以降の番号コメントを繰り下げ）
- Modify: `src/DBOBJ.pm`（`use MetaAoh` 追加、`hashes()` 書き換え、`_build_meta` → `_order_spec` 置換）

- [ ] **Step 1: 失敗するテストを書く**

`test/dbobj.t` の冒頭の `use Spool;` の下に `use MetaAoh;` を追加する（`use Spool;` は Task 2 で消すのでここでは触らない）。

旧「spec#11. run + hashes」「spec#12. hashes 0件」「spec#13. NULL → ''」の3 subtest を次の4 subtest に置き換える：

```perl
# --- spec#11. hashes が metaAoh を返す ---
subtest 'hashes は metaAoh を返す' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_h (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_h VALUES (1, 'a'), (2, 'b')");
    $db->run("SELECT id, val FROM ${TBL}_h ORDER BY id");
    my $m = $db->hashes();

    ok(MetaAoh::is_metaAOH($m), 'metaAoh である');
    is($m->count(), 2, 'count() はデータ行数');
    is_deeply($m->[0], {id => 1, val => 'a'}, '1行目に添字アクセスできる');
    is_deeply($m->[1], {id => 2, val => 'b'}, '2行目に添字アクセスできる');
    $db->close();
};

# --- spec#12. hashes の meta 確認 ---
subtest 'hashes の meta' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_hm (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_hm VALUES (1, 'a')");
    $db->run("SELECT id, val FROM ${TBL}_hm");
    my $meta = $db->hashes()->meta();

    is_deeply($meta->{order}, ['id#', 'val'], 'order は num が NAME#・str が NAME');
    is_deeply($meta->{cols},  ['id', 'val'],  'cols はカラム順');
    is_deeply($meta->{attrs}, {id => 'num', val => 'str'}, 'attrs は型');
    ok(!$meta->{grouped}, 'grouped は偽');
    $db->close();
};

# --- spec#13. hashes 0件なら空の metaAoh ---
subtest 'hashes 0件で空の metaAoh' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_h0 (id INT, val TEXT)");
    $db->run("SELECT id, val FROM ${TBL}_h0");
    my $m = $db->hashes();

    ok(MetaAoh::is_metaAOH($m), '0件でも metaAoh である');
    is($m->count(), 0, 'count() は 0');
    is_deeply($m->meta()->{cols},  ['id', 'val'], 'cols は保持される');
    is_deeply($m->meta()->{attrs}, {id => 'num', val => 'str'}, 'attrs は保持される');
    $db->close();
};

# --- spec#14. NULL → '' への変換確認 ---
subtest 'NULL を空文字に変換' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_null (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_null VALUES (1, NULL)");

    # get
    $db->run("SELECT val FROM ${TBL}_null");
    is($db->get(), '', 'get() で NULL → ""');

    # list
    $db->run("SELECT val FROM ${TBL}_null");
    my @l = $db->list();
    is($l[0], '', 'list() で NULL → ""');

    # arrays
    $db->run("SELECT val FROM ${TBL}_null");
    my $a = $db->arrays();
    is($a->[0][0], '', 'arrays() で NULL → ""');

    # hashes（メタ行がないため先頭要素がデータ行）
    $db->run("SELECT val FROM ${TBL}_null");
    my $m = $db->hashes();
    is($m->[0]{val}, '', 'hashes() で NULL → ""');

    $db->close();
};
```

続けて、旧 spec#14〜21 の番号コメントを spec#15〜22 に書き換える（内容は変更しない）。例：`# --- spec#14. prepare + execute バインド変数 ---` → `# --- spec#15. prepare + execute バインド変数 ---`。

- [ ] **Step 2: テストが失敗することを確認する**

Run: `prove -lr test/`
Expected: FAIL。旧 `hashes()` は `[{'#' => ...}, ...]` の素の配列を返すため、`MetaAoh::is_metaAOH` が偽・`count()` メソッド呼び出しが "Can't locate object method" で失敗する。

- [ ] **Step 3: 最小実装を書く**

`src/DBOBJ.pm` の `use Spool;` の下に追加：

```perl
use MetaAoh;
```

`_build_meta` を削除し、代わりに次を置く（`spool()` が一時的に `_build_meta` を失うため、Task 2 完了までは `_build_meta` を残したままでもよい。残す場合もテストは通る）：

```perl
# Build MetaAoh column specs (NAME for str, NAME# for num) from the statement handle.
sub _order_spec {
    my ($sth) = @_;
    my $names = $sth->{NAME};
    my $types = $sth->{TYPE};
    my @spec;
    for my $i (0 .. $#$names) {
        my $type = $TYPE_CLASS{$types->[$i]} // 'str';
        push @spec, $type eq 'num' ? "$names->[$i]#" : $names->[$i];
    }
    return @spec;
}
```

`hashes()` を次に置き換える：

```perl
sub hashes {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref({});
    for my $row (@$rows) {
        for my $key (keys %$row) {
            $row->{$key} = '' unless defined $row->{$key};
        }
    }
    return MetaAoh->new($rows, _order_spec($self->{sth}));
}
```

0件の場合も同じ経路で空の metaAoh が返る（分岐を作らない）。

- [ ] **Step 4: テストが通ることを確認する**

Run: `prove -lr test/`
Expected: PASS（spool 系の旧テストは Task 2 までは旧実装のまま残っているので通る）

---

### Task 2: spool() の廃止

**Files:**
- Modify: `test/dbobj.t`（旧 spec#22〜24 の spool 系 subtest 3つと `use Spool;` を削除し、新 spec#23 を追加）
- Modify: `src/DBOBJ.pm`（`spool()` メソッドと `use Spool;` を削除。Task 1 で `_build_meta` を残した場合はここで削除）

- [ ] **Step 1: spool 系テストを削除し、group() 統合テストを追加する**

`test/dbobj.t` から次を削除する：
- `use Spool;` の行
- 「spec#22. spool() 書き出し・読み返し確認」「spec#23. spool 0件でも作成」「spec#24. spool 経由の NULL → ''」の3 subtest

ファイル末尾の `done_testing;` の前に追加する：

```perl
# --- spec#23. 呼び出し側で group() が機能する（統合確認）---
subtest 'hashes の metaAoh に group() が使える' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_grp (dept TEXT, name TEXT)");
    $db->run("INSERT INTO ${TBL}_grp VALUES ('a', 'x'), ('a', 'y'), ('b', 'z')");
    $db->run("SELECT dept, name FROM ${TBL}_grp ORDER BY dept, name");
    my $t = $db->hashes()->group(['dept']);

    ok($t->meta()->{grouped}, 'grouped が真');
    is($t->count(), 2, '最上位 tree node 数は dept の値の種類数');
    $db->close();
};
```

- [ ] **Step 2: テストが通ることを確認する（削除の確認）**

Run: `prove -lr test/`
Expected: PASS。spool 系テストが消え、新 spec#23 が通る（`group()` は MetaAoh の既存機能のため red にはならない。これは DBOBJ の出力が MetaAoh の前提条件を満たすことの統合確認）

- [ ] **Step 3: spool() を実装から削除する**

`src/DBOBJ.pm` から次を削除する：
- `use Spool;` の行
- `sub spool { ... }` 全体
- Task 1 で `_build_meta` を残していた場合は `sub _build_meta { ... }` 全体

- [ ] **Step 4: テストが通ることを確認する**

Run: `prove -lr test/`
Expected: PASS（参照が残っていれば compile エラーで検出される）

---

### Task 3: エラー処理を dying() に統一

**Files:**
- Modify: `src/DBOBJ.pm`（`use CommonIO` 追加、全 `die` を `dying()` に置換）

- [ ] **Step 1: use を追加する**

`use DBI;` の下に追加：

```perl
use CommonIO qw(dying);
```

- [ ] **Step 2: すべての die を dying() に置き換える**

対象は7箇所。置換後の形：

```perl
# new()
dying("DBOBJ.new: dbname is required") unless defined $dbname && $dbname ne '';
dying("DBOBJ.new: $var is not set") unless defined $ENV{$var} && $ENV{$var} ne '';
... or dying("DBOBJ.new: " . DBI->errstr);
... or dying("DBOBJ.new: " . $dbh->errstr);

# prepare()
... or dying("DBOBJ.prepare: " . $self->{dbh}->errstr);

# execute()
... or dying("DBOBJ.execute: " . $self->{sth}->errstr);

# get()
dying(sprintf("DBOBJ.get: expected 1 row and 1 col, got %d rows, %d cols",
    scalar(@$rows),
    $rows->[0] ? scalar(@{$rows->[0]}) : 0))
    unless @$rows == 1 && @{$rows->[0]} == 1;

# list()
dying("DBOBJ.list: no active statement") unless defined $ncols;
dying("DBOBJ.list: expected 1 col, got $ncols") unless $ncols == 1;

# psql()
dying("DBOBJ.psql: file not found: $sqlfile") unless -f $sqlfile;
dying("DBOBJ.psql: exit code " . ($? >> 8)) if $? != 0;
```

- [ ] **Step 3: テストが通ることを確認する**

Run: `prove -lr test/`
Expected: PASS。die 検証のテスト（spec#2・3・6・8・17・18・20・21）は `dying()` でも例外が投がるためそのまま通る。STDERR に `[ERROR]` ログ行が出るのは正常

---

### Task 4: ソース冒頭の Terms / Rules コメント同期

**Files:**
- Modify: `src/DBOBJ.pm:3-32`（package 宣言直下のコメントブロック）

- [ ] **Step 1: design-concept.md の Rules をコピーする**

`src/DBOBJ.pm` の package 宣言直下のコメントブロック（`# Terms:` から `# close() は DB 接続を閉じる` まで）を、[design-concept.md](../../design/design-concept.md) の `## Rules` コードブロックの内容（`# Terms:` 〜 `# close() は DB 接続を閉じる`）で**そのまま置き換える**。design-concept が SSoT であり、逐語一致させる。

- [ ] **Step 2: テストが通ることを確認する**

Run: `prove -lr test/`
Expected: PASS（コメントのみの変更）

---

### Task 5: ドキュメント整合（spec.md / test-spec.md / README）

**Files:**
- Modify: `docs/spec.md`
- Modify: `docs/test-spec.md`
- Modify: `README.md` / `README_ja.md`

- [ ] **Step 1: docs/spec.md を更新する**

変更箇所：
- 概要の「データ取得は `get()`、`list()`、`arrays()`、`hashes()`、`spool()` に限定」→ 4形式（spool 除外）に変更し、「グループ化は呼び出し側が metaAoh の `group()` で行う」に変更
- エラー処理：「エラーは手動検知して die する」→「手動検知して CommonIO の `dying()` でエラーログを残して die する」。CommonIO 積極使用の方針を追記
- API 表から `spool()` 行を削除、`hashes()` の出力を「`metaAoh`（0件でも空の metaAoh）」に変更。記号定義から `$spool_id`・旧 meta を削除し `metaAoh`（`order`・`cols`・`attrs`・`grouped`、件数は `count()`）を追加
- 「### hashes()」の出力契約を metaAoh 仕様（`MetaAoh->new` への受け渡し、`NAME`/`NAME#` 変換、0件時は空の metaAoh）に書き換え
- 「### spool($spool_id)」セクションを削除し、NULL の扱いから spool への言及を除去

- [ ] **Step 2: docs/test-spec.md を更新する**

- テストケース表を変更仕様書 [2026-06-10-design.md](../specs/2026-06-10-design.md) の23ケース表で置き換える
- テストファイル表から spool 関連の記述を除去（`insert.sql`・`error.sql`・`notice.sql` は psql 用なので残す）

- [ ] **Step 3: README.md / README_ja.md を同期更新する**

両ファイルで：
- API 表から `spool($spool_id)` 行を削除、`hashes()` の説明を「全行を metaAoh（MetaAoh オブジェクト）で取得」に変更
- 使い方の `hashes()` 例を metaAoh に書き換え（`$m->count()`・`$m->meta()`・`$m->[0]{name}`・`$m->group([...])`）、Spool の例を削除
- 必要環境に「`lib/MetaAoh.pm`・`lib/CommonIO.pm`（同梱ライブラリ）」「`LOGDIR` ディレクトリ（`output/logs`）」を追記
- 注意事項の「`arrays()` と `hashes()` は0件なら `[]`」→「`arrays()` は0件なら `[]`、`hashes()` は0件でも空の metaAoh」に変更
- `README.md` 冒頭の `README_ja.md` リンクを維持

- [ ] **Step 4: 全テストと appset を確認する**

Run: `prove -lr test/` → Expected: PASS（23 subtests）
Run: `bash $HOME/.claude/skills/appset/appset.sh` → Expected: `Result : ALL OK`

---

### Task 6: 完了処理（ユーザーゲート）

- [ ] **Step 1: AGENTS.md / perl-coding.md のルール自己確認**（違反があれば該当タスクに戻る）
- [ ] **Step 2: ユーザーにコードレビューを依頼**（NG なら指摘に応じて Task 1〜5 に戻る）
- [ ] **Step 3: 明示的 OK 後、許可を得てコミット**（design-concept.md の To Do セクション削除もこのタイミング。push も許可制）
