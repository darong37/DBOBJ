# DBOBJ Initial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DBOBJ.pm を新設計（2026-04-09-dbobj-redesign.md）に基づき実装する。

**Architecture:** 単一モジュール `DBOBJ.pm` に全機能を実装する。DBI の薄いラッパーとして、接続・SQL 実行・データ取得（4形式）・psql 連動・Spool 書き出しを提供する。

**Tech Stack:** Perl 5、DBI、DBD::Pg、TableTools（lib/）、Spool（lib/）

---

## ファイル構成

| ファイル | 操作 | 役割 |
|---|---|---|
| `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm` | 作成 | モジュール本体 |
| `.claude/worktrees/feature-initial-impl/test/dbobj.t` | 作成 | 全テスト |

**作業ディレクトリ:** `.claude/worktrees/feature-initial-impl`

**テスト実行コマンド:**
```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

**前提:** 環境変数 `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` が設定済みで、`develop` データベースが存在すること。

---

## Task 1: テスト用セットアップと接続

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`

- [ ] **Step 1: テストの骨格と接続テストを書く（失敗確認）**

`test/dbobj.t` を以下の内容に書き換える:

```perl
use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBOBJ;

# テスト用テーブル名（他テストと衝突しないよう一意にする）
my $TBL = 'dbobj_test_' . $$;

# --- 1. 接続成功・close() ---
subtest '接続成功・close()' => sub {
    my $db = DBOBJ->new('develop');
    isa_ok($db, 'DBOBJ');
    lives_ok { $db->close() } 'close() が die しない';
};

# --- 2. 環境変数未設定で die ---
subtest '環境変数未設定で die' => sub {
    local $ENV{PGHOST} = '';
    dies_ok { DBOBJ->new('develop') } 'PGHOST 未設定で die';
};

# --- 3. dbname 未指定で die ---
subtest 'dbname 未指定で die' => sub {
    dies_ok { DBOBJ->new() } 'dbname 未指定で die';
};

done_testing;
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t 2>&1 | head -20
```

期待: `Can't locate object method "new"` など、モジュール未実装のエラー。

- [ ] **Step 3: DBOBJ.pm の骨格と new()・close() を実装する**

`src/DBOBJ.pm` を以下の内容に書き換える:

```perl
package DBOBJ;

# Terms:
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
# new() に dbname（接続先 PostgreSQL データベース名）は必須。PGDATABASE 環境変数は参照しない
# PGHOST, PGPORT, PGUSER, PGPASSWORD は必須。未設定なら die
# DBI の自動例外は無効にし、エラーは手動検知して die
# get(), list(), arrays(), hashes(), spool() が返すすべての値において undef は存在しない。undef は '' に変換する
# prepare() -> execute() の呼び出し順序は DBI の仕様に従う。DBOBJ 側で強制しない
# get() は結果が 1行1列でない場合 die する
# list() は結果が 1列でない場合 die する
# arrays() は 0件なら [] を返す
# hashes() は先頭に meta を持つメタ付き AoH で返す。0件なら [] を返す（meta も含まない）。count はデータ行数
# attrs の型は DBI の型情報をもとに判定する。REAL・INTEGER・NUMERIC 系は 'num'、それ以外は 'str'
# グループ化は TableTools の group() で行う。DBOBJ は関与しない
# psql(sqlfile) は dbname と PGHOST, PGPORT, PGUSER, PGPASSWORD を使って psql を別プロセスで起動する
# psql() は --set ON_ERROR_STOP=1 で起動する。NOTICE はエラーにならない
# psql() は sqlfile が存在しない場合 die する
# psql() は psql の終了コードが 0 以外の場合 die する
# spool(spool_id) は Spool->open(spool_id) でスプールを開き、Spool->meta() で meta を渡してから全行を add() して close() する
# spool() は結果をメモリに展開しない
# close() は DB 接続を閉じる

use strict;
use warnings;
use DBI;

# DBI 数値型コード（REAL/INTEGER/NUMERIC 系）
my %NUM_TYPES = map { $_ => 1 } (
    4,   # SQL_INTEGER
    5,   # SQL_SMALLINT
    6,   # SQL_FLOAT
    7,   # SQL_REAL
    8,   # SQL_DOUBLE
    2,   # SQL_NUMERIC
    -5,  # SQL_BIGINT
    -6,  # SQL_TINYINT
);

sub new {
    my ($class, $dbname) = @_;
    die "DBOBJ.new: dbname is required" unless defined $dbname && $dbname ne '';

    for my $var (qw(PGHOST PGPORT PGUSER PGPASSWORD)) {
        die "$var is not set" unless defined $ENV{$var} && $ENV{$var} ne '';
    }

    my $dsn = "dbi:Pg:dbname=$dbname;host=$ENV{PGHOST};port=$ENV{PGPORT}";
    my $dbh = DBI->connect($dsn, $ENV{PGUSER}, $ENV{PGPASSWORD}, {
        RaiseError          => 0,
        PrintError          => 0,
        pg_enable_utf8      => 1,
        AutoInactiveDestroy => 1,
    }) or die "DBOBJ.new: " . DBI->errstr;

    $dbh->do("SET client_min_messages = WARNING");

    return bless {
        dbn => $dbname,
        dbh => $dbh,
        sth => undef,
    }, $class;
}

sub close {
    my ($self) = @_;
    $self->{sth}->finish() if $self->{sth};
    $self->{dbh}->disconnect() if $self->{dbh};
    return $self;
}

1;
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

期待: `ok 1 - 接続成功・close()` など全テスト pass。

- [ ] **Step 5: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add src/DBOBJ.pm test/dbobj.t
git commit -m "feat: add DBOBJ new() and close() with tests"
```

---

## Task 2: prepare / execute / run

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`

- [ ] **Step 1: テストを追加する（失敗確認）**

`done_testing;` の直前に追加:

```perl
# --- 12. prepare + execute バインド変数 ---
subtest 'prepare + execute バインド変数' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE $TBL (id INT, val TEXT)");
    $db->run("INSERT INTO $TBL VALUES (1, 'a'), (2, 'b')");

    $db->prepare("SELECT val FROM $TBL WHERE id = ?");
    $db->execute(1);
    my @rows = $db->list();
    is_deeply(\@rows, ['a'], 'バインド変数で絞り込める');
    $db->close();
};
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t 2>&1 | grep -E "not ok|Can't"
```

- [ ] **Step 3: prepare / execute / run を実装する**

`close()` の前に追加:

```perl
sub prepare {
    my ($self, $sql) = @_;
    $self->{sth}->finish() if $self->{sth};
    $self->{sth} = $self->{dbh}->prepare($sql)
        or die "DBOBJ.prepare: " . $self->{dbh}->errstr;
    return $self;
}

sub execute {
    my ($self, @bind) = @_;
    $self->{sth}->execute(@bind)
        or die "DBOBJ.execute: " . $self->{sth}->errstr;
    return $self;
}

sub run {
    my ($self, $sql) = @_;
    $self->prepare($sql)->execute();
    return $self;
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

- [ ] **Step 5: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add src/DBOBJ.pm test/dbobj.t
git commit -m "feat: add prepare/execute/run with tests"
```

---

## Task 3: get() と list()

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`

- [ ] **Step 1: テストを追加する（失敗確認）**

`done_testing;` の直前に追加:

```perl
# --- 4. run + get（スカラー1値）---
subtest 'get スカラー1値' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("SELECT 42");
    my $val = $db->get();
    is($val, 42, 'get() で1値取得');
    $db->close();
};

# --- 5. get で1行1列以外は die ---
subtest 'get で1行1列以外は die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("SELECT 1, 2");
    dies_ok { $db->get() } '複数列で die';

    $db->run("CREATE TEMP TABLE ${TBL}_g (id INT)");
    $db->run("INSERT INTO ${TBL}_g VALUES (1), (2)");
    $db->run("SELECT id FROM ${TBL}_g");
    dies_ok { $db->get() } '複数行で die';
    $db->close();
};

# --- 6. run + list（単一カラム）---
subtest 'list 単一カラム全件' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_l (id INT)");
    $db->run("INSERT INTO ${TBL}_l VALUES (1), (2), (3)");
    $db->run("SELECT id FROM ${TBL}_l ORDER BY id");
    my @vals = $db->list();
    is_deeply(\@vals, [1, 2, 3], 'list() で全件取得');
    $db->close();
};

# --- 7. list で1列以外は die ---
subtest 'list で1列以外は die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("SELECT 1, 2");
    dies_ok { $db->list() } '複数列で die';
    $db->close();
};
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t 2>&1 | grep -E "not ok|Can't"
```

- [ ] **Step 3: get() と list() を実装する**

`run()` の後に追加:

```perl
sub _normalize {
    my ($val) = @_;
    return defined $val ? $val : '';
}

sub get {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref();
    die "DBOBJ.get: expected 1 row and 1 col, got "
        . scalar(@$rows) . " rows " . ($rows->[0] ? scalar(@{$rows->[0]}) : 0) . " cols"
        unless @$rows == 1 && @{$rows->[0]} == 1;
    return _normalize($rows->[0][0]);
}

sub list {
    my ($self) = @_;
    my $ncols = $self->{sth}{NUM_OF_FIELDS};
    die "DBOBJ.list: expected 1 col, got $ncols" unless $ncols == 1;
    my $rows = $self->{sth}->fetchall_arrayref();
    return map { _normalize($_->[0]) } @$rows;
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

- [ ] **Step 5: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add src/DBOBJ.pm test/dbobj.t
git commit -m "feat: add get() and list() with tests"
```

---

## Task 4: arrays()

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`

- [ ] **Step 1: テストを追加する（失敗確認）**

`done_testing;` の直前に追加:

```perl
# --- 8. run + arrays（AoA）---
subtest 'arrays 全件AoA' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_a (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_a VALUES (1, 'x'), (2, 'y')");
    $db->run("SELECT id, val FROM ${TBL}_a ORDER BY id");
    my $result = $db->arrays();
    is_deeply($result, [[1, 'x'], [2, 'y']], 'arrays() で AoA 取得');
    $db->close();
};

subtest 'arrays 0件で空配列' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_a0 (id INT)");
    $db->run("SELECT id FROM ${TBL}_a0");
    my $result = $db->arrays();
    is_deeply($result, [], '0件なら []');
    $db->close();
};
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t 2>&1 | grep -E "not ok|Can't"
```

- [ ] **Step 3: arrays() を実装する**

`list()` の後に追加:

```perl
sub arrays {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref();
    return [] unless @$rows;
    return [ map { [ map { _normalize($_) } @$_ ] } @$rows ];
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

- [ ] **Step 5: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add src/DBOBJ.pm test/dbobj.t
git commit -m "feat: add arrays() with tests"
```

---

## Task 5: hashes()

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`

- [ ] **Step 1: テストを追加する（失敗確認）**

`done_testing;` の直前に追加:

```perl
# --- 9. run + hashes（メタ付き AoH・attrs/order/count 確認）---
subtest 'hashes メタ付きAoH' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_h (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_h VALUES (1, 'a'), (2, 'b')");
    $db->run("SELECT id, val FROM ${TBL}_h ORDER BY id");
    my $result = $db->hashes();

    is(ref($result), 'ARRAY', '配列リファレンス');
    is(scalar(@$result), 3, 'meta + 2行 = 3要素');

    my $meta = $result->[0]{'#'};
    is_deeply($meta->{order}, ['id', 'val'], 'order が正しい');
    is($meta->{attrs}{id},  'num', 'id は num');
    is($meta->{attrs}{val}, 'str', 'val は str');
    is($meta->{count}, 2, 'count が正しい');

    is_deeply($result->[1], {id => 1, val => 'a'}, '1行目のデータ');
    is_deeply($result->[2], {id => 2, val => 'b'}, '2行目のデータ');
    $db->close();
};

# --- 10. hashes 0件なら [] ---
subtest 'hashes 0件で空配列' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_h0 (id INT)");
    $db->run("SELECT id FROM ${TBL}_h0");
    my $result = $db->hashes();
    is_deeply($result, [], '0件なら []');
    $db->close();
};
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t 2>&1 | grep -E "not ok|Can't"
```

- [ ] **Step 3: hashes() と _build_meta() を実装する**

`arrays()` の後に追加:

```perl
sub _build_meta {
    my ($sth, $count) = @_;
    my $names = $sth->{NAME};
    my $types = $sth->{TYPE};
    my %attrs;
    for my $i (0 .. $#$names) {
        $attrs{$names->[$i]} = $NUM_TYPES{$types->[$i]} ? 'num' : 'str';
    }
    return {
        '#' => {
            attrs => \%attrs,
            order => [@$names],
            count => $count,
        }
    };
}

sub hashes {
    my ($self) = @_;
    my $names = $self->{sth}{NAME};
    my $meta_base = _build_meta($self->{sth}, 0);  # count は後で確定

    my $rows = $self->{sth}->fetchall_arrayref({});
    return [] unless @$rows;

    # undef を '' に変換
    for my $row (@$rows) {
        for my $key (keys %$row) {
            $row->{$key} = '' unless defined $row->{$key};
        }
    }

    $meta_base->{'#'}{count} = scalar(@$rows);
    return [$meta_base, @$rows];
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

- [ ] **Step 5: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add src/DBOBJ.pm test/dbobj.t
git commit -m "feat: add hashes() with meta (attrs/order/count) and tests"
```

---

## Task 6: NULL → '' 変換の確認テスト

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`

- [ ] **Step 1: NULL 変換テストを追加する**

`done_testing;` の直前に追加:

```perl
# --- 11. NULL → '' への変換確認 ---
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

    # hashes
    $db->run("SELECT val FROM ${TBL}_null");
    my $h = $db->hashes();
    is($h->[1]{val}, '', 'hashes() で NULL → ""');

    $db->close();
};
```

- [ ] **Step 2: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

- [ ] **Step 3: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add test/dbobj.t
git commit -m "test: add NULL normalization tests"
```

---

## Task 7: DML と psql()

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`
- Create: `.claude/worktrees/feature-initial-impl/test/insert.sql`（テスト用 SQL ファイル）

- [ ] **Step 1: テストを追加する（失敗確認）**

`done_testing;` の直前に追加:

```perl
# --- 13. DML（INSERT/UPDATE/DELETE）---
subtest 'DML 実行' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_dml (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_dml VALUES (1, 'a')");
    $db->run("UPDATE ${TBL}_dml SET val = 'b' WHERE id = 1");
    $db->run("SELECT val FROM ${TBL}_dml");
    is($db->get(), 'b', 'UPDATE が反映されている');
    $db->run("DELETE FROM ${TBL}_dml WHERE id = 1");
    $db->run("SELECT COUNT(*) FROM ${TBL}_dml");
    is($db->get(), 0, 'DELETE 後は0件');
    $db->close();
};

# --- 14. psql($sqlfile) ファイル実行 ---
subtest 'psql SQLファイル実行' => sub {
    my $db = DBOBJ->new('develop');
    lives_ok { $db->psql('test/insert.sql') } 'psql() が die しない';
    $db->close();
};

# --- 15. psql でファイル不在の場合 die ---
subtest 'psql ファイル不在で die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->psql('test/nonexistent.sql') } 'ファイル不在で die';
    $db->close();
};

# --- 16. psql で終了コード非0の場合 die ---
subtest 'psql SQL エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->psql('test/error.sql') } 'SQL エラーで die';
    $db->close();
};

# --- 17. psql で NOTICE が出ても die しない ---
subtest 'psql NOTICE は die しない' => sub {
    my $db = DBOBJ->new('develop');
    lives_ok { $db->psql('test/notice.sql') } 'NOTICE があっても die しない';
    $db->close();
};
```

- [ ] **Step 2: テスト用 SQL ファイルを作成する**

`test/insert.sql`:
```sql
SELECT 1;
```

`test/error.sql`:
```sql
SELECT no_such_column FROM no_such_table;
```

`test/notice.sql`:
```sql
DO $$BEGIN RAISE NOTICE 'test notice'; END$$;
```

- [ ] **Step 3: テストが失敗することを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t 2>&1 | grep -E "not ok|Can't"
```

- [ ] **Step 4: psql() を実装する**

`hashes()` の後に追加:

```perl
sub psql {
    my ($self, $sqlfile) = @_;
    die "DBOBJ.psql: file not found: $sqlfile" unless -f $sqlfile;

    local $ENV{PGPASSWORD} = $ENV{PGPASSWORD};
    my @cmd = (
        'psql',
        '--set', 'ON_ERROR_STOP=1',
        '-h', $ENV{PGHOST},
        '-p', $ENV{PGPORT},
        '-U', $ENV{PGUSER},
        '-d', $self->{dbn},
        '-f', $sqlfile,
    );
    system(@cmd);
    die "DBOBJ.psql: exit code " . ($? >> 8) if $? != 0;
    return $self;
}
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

- [ ] **Step 6: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add src/DBOBJ.pm test/dbobj.t test/insert.sql test/error.sql test/notice.sql
git commit -m "feat: add psql() with tests"
```

---

## Task 8: spool()

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`
- Modify: `.claude/worktrees/feature-initial-impl/test/dbobj.t`

- [ ] **Step 1: テストを追加する（失敗確認）**

`done_testing;` の直前に追加:

```perl
# --- 18. spool() 書き出し・読み返し確認 ---
subtest 'spool 書き出しと読み返し' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = 'dbobjtest' . $$;

    $db->run("CREATE TEMP TABLE ${TBL}_s (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_s VALUES (1, 'x'), (2, 'y')");
    $db->run("SELECT id, val FROM ${TBL}_s ORDER BY id");
    lives_ok { $db->spool($sid) } 'spool() が die しない';

    # Spool から読み返す
    my $sp = Spool->new($sid);
    my $records = $sp->records();
    is(scalar(@$records), 2, '2件読み返せる');
    is($records->[0]{val}, 'x', '1件目の val');

    my $meta = $sp->get('meta');
    is($meta->{'#'}{count}, 2, 'count が正しい');
    is($meta->{'#'}{attrs}{id}, 'num', 'id は num');

    Spool->remove($sid);
    $db->close();
};

# --- 19. spool 0件でも作成・attrs/order 保持・count=0 ---
subtest 'spool 0件でも正しく作成' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = 'dbobjtest0' . $$;

    $db->run("CREATE TEMP TABLE ${TBL}_s0 (id INT, val TEXT)");
    $db->run("SELECT id, val FROM ${TBL}_s0");
    lives_ok { $db->spool($sid) } '0件でも die しない';

    my $sp = Spool->new($sid);
    my $meta = $sp->get('meta');
    is($meta->{'#'}{count}, 0, 'count は 0');
    ok(exists $meta->{'#'}{attrs}{id},  'attrs に id が存在');
    ok(exists $meta->{'#'}{attrs}{val}, 'attrs に val が存在');
    is_deeply($meta->{'#'}{order}, ['id', 'val'], 'order が正しい');

    Spool->remove($sid);
    $db->close();
};
```

テストファイル冒頭の `use` に `use Spool;` を追加する。

- [ ] **Step 2: テストが失敗することを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t 2>&1 | grep -E "not ok|Can't"
```

- [ ] **Step 3: spool() を実装する**

ファイル冒頭の `use DBI;` の後に追加:
```perl
use Spool;
```

`psql()` の後に追加:

```perl
sub spool {
    my ($self, $spool_id) = @_;
    my $sth = $self->{sth};
    my $meta = _build_meta($sth, 0);

    my $sp = Spool->open($spool_id);
    $sp->meta($meta);

    my $names = $sth->{NAME};
    my $count = 0;
    while (my $row = $sth->fetchrow_hashref()) {
        for my $key (keys %$row) {
            $row->{$key} = '' unless defined $row->{$key};
        }
        $sp->add($row);
        $count++;
    }

    # count を書き込む前に meta を更新
    $meta->{'#'}{count} = $count;
    $sp->close();
    return $self;
}
```

**注:** Spool の `meta()` は `close()` 前であれば更新可能か確認が必要。Spool の実装では `meta.do` は `close()` 時に書き出されるため、`$sp->close()` 前に `$meta->{'#'}{count}` を更新すれば反映される。

- [ ] **Step 4: テストが通ることを確認する**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

- [ ] **Step 5: コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add src/DBOBJ.pm test/dbobj.t
git commit -m "feat: add spool() with tests"
```

---

## Task 9: 全テスト通過確認と最終確認

**Files:**
- Modify: `.claude/worktrees/feature-initial-impl/src/DBOBJ.pm`（必要に応じて）

- [ ] **Step 1: 全テストを通す**

```bash
cd .claude/worktrees/feature-initial-impl
perl -Isrc -Ilib test/dbobj.t
```

期待: 全テスト pass、0 failures。

- [ ] **Step 2: Rules の自己確認**

`src/DBOBJ.pm` の package 宣言直下の Rules コメントを見て、コードと矛盾がないか確認する。

- [ ] **Step 3: /appset を実行する**

```bash
cd /Users/darong/PRJDEV/DBOBJ
bash $HOME/.claude/skills/appset/appset.sh
```

期待: ALL OK または FIX のみ（NG なし）。

- [ ] **Step 4: 最終コミット**

```bash
cd .claude/worktrees/feature-initial-impl
git add -u
git status
git commit -m "feat: DBOBJ initial implementation complete"
```
