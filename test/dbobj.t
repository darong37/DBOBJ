use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBOBJ;
use Spool;

# テスト用テーブル名（他テストと衝突しないよう一意にする）
my $TBL = 'dbobj_test_' . $$;

# --- spec#1. 接続成功・close() ---
subtest '接続成功・close()' => sub {
    my $db = DBOBJ->new('develop');
    isa_ok($db, 'DBOBJ');
    lives_ok { $db->close() } 'close() が die しない';
};

# --- spec#2. 環境変数未設定で die ---
subtest '環境変数未設定で die' => sub {
    local $ENV{PGHOST} = '';
    dies_ok { DBOBJ->new('develop') } 'PGHOST 未設定で die';
};

# --- spec#3. dbname 未指定で die ---
subtest 'dbname 未指定で die' => sub {
    dies_ok { DBOBJ->new() } 'dbname 未指定で die';
};

# --- spec#4. PGDATABASE を参照しない ---
subtest 'PGDATABASE を参照しない' => sub {
    local $ENV{PGDATABASE} = 'nonexistent_db_xyz';
    my $db = DBOBJ->new('develop');
    $db->run("SELECT 1");
    is($db->get(), 1, 'PGDATABASE ではなく dbname で接続される');
    $db->close();
};

# --- spec#5. run + get（スカラー1値）---
subtest 'get スカラー1値' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("SELECT 42");
    my $val = $db->get();
    is($val, 42, 'get() で1値取得');
    $db->close();
};

# --- spec#6. get で1行1列以外は die ---
subtest 'get で1行1列以外は die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("SELECT 1, 2");
    dies_ok { $db->get() } '複数列で die';

    $db->run("CREATE TEMP TABLE ${TBL}_g (id INT)");
    $db->run("INSERT INTO ${TBL}_g VALUES (1), (2)");
    $db->run("SELECT id FROM ${TBL}_g");
    dies_ok { $db->get() } '複数行で die';

    # 0件
    $db->run("CREATE TEMP TABLE ${TBL}_g0 (id INT)");
    $db->run("SELECT id FROM ${TBL}_g0");
    dies_ok { $db->get() } '0件で die';
    $db->close();
};

# --- spec#7. run + list（単一カラム）---
subtest 'list 単一カラム全件' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_l (id INT)");
    $db->run("INSERT INTO ${TBL}_l VALUES (1), (2), (3)");
    $db->run("SELECT id FROM ${TBL}_l ORDER BY id");
    my @vals = $db->list();
    is_deeply(\@vals, [1, 2, 3], 'list() で全件取得');
    $db->close();
};

# --- spec#8. list で1列以外は die ---
subtest 'list で1列以外は die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("SELECT 1, 2");
    dies_ok { $db->list() } '複数列で die';
    $db->close();
};

# --- spec#9. run + arrays（AoA）---
subtest 'arrays 全件AoA' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_a (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_a VALUES (1, 'x'), (2, 'y')");
    $db->run("SELECT id, val FROM ${TBL}_a ORDER BY id");
    my $result = $db->arrays();
    is_deeply($result, [[1, 'x'], [2, 'y']], 'arrays() で AoA 取得');
    $db->close();
};

# --- spec#10. arrays 0件なら [] ---
subtest 'arrays 0件で空配列' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_a0 (id INT)");
    $db->run("SELECT id FROM ${TBL}_a0");
    my $result = $db->arrays();
    is_deeply($result, [], '0件なら []');
    $db->close();
};

# --- spec#11. run + hashes（メタ付き AoH・attrs/order/count 確認）---
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
    is($meta->{count}, 2, 'count は meta 自身を含まないデータ行数');

    is_deeply($result->[1], {id => 1, val => 'a'}, '1行目のデータ');
    is_deeply($result->[2], {id => 2, val => 'b'}, '2行目のデータ');
    $db->close();
};

# --- spec#12. hashes 0件なら [] ---
subtest 'hashes 0件で空配列' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_h0 (id INT)");
    $db->run("SELECT id FROM ${TBL}_h0");
    my $result = $db->hashes();
    is_deeply($result, [], '0件なら []');
    $db->close();
};

# --- spec#13. NULL → '' への変換確認 ---
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

# --- spec#14. prepare + execute バインド変数 ---
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

# --- spec#15. DML（INSERT/UPDATE/DELETE）---
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

# --- spec#16. run で SQL 構文エラー時 die ---
subtest 'run SQL 構文エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->run("SELCT * FROOOM nowhere") } 'SQL 構文エラーで die';
    $db->close();
};

# --- spec#17. prepare + execute で SQL エラー時 die ---
subtest 'prepare + execute SQL エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok {
        $db->prepare("SELECT val FROM nonexistent_table_xyz WHERE id = ?");
        $db->execute(1);
    } 'prepare + execute で SQL エラー時 die';
    $db->close();
};

# --- spec#18. psql($sqlfile) ファイル実行 ---
subtest 'psql SQLファイル実行' => sub {
    my $db = DBOBJ->new('develop');
    lives_ok { $db->psql('test/insert.sql') } 'psql() が die しない';
    $db->close();
};

# --- spec#19. psql でファイル不在の場合 die ---
subtest 'psql ファイル不在で die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->psql('test/nonexistent.sql') } 'ファイル不在で die';
    $db->close();
};

# --- spec#20. psql で終了コード非0の場合 die ---
subtest 'psql SQL エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->psql('test/error.sql') } 'SQL エラーで die';
    $db->close();
};

# --- spec#21. psql で NOTICE が出ても die しない ---
subtest 'psql NOTICE は die しない' => sub {
    my $db = DBOBJ->new('develop');
    lives_ok { $db->psql('test/notice.sql') } 'NOTICE があっても die しない';
    $db->close();
};

# --- spec#22. spool() 書き出し・読み返し確認 ---
subtest 'spool 書き出しと読み返し' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = 'dbobjtest' . $$;

    $db->run("CREATE TEMP TABLE ${TBL}_s (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_s VALUES (1, 'x'), (2, 'y')");
    $db->run("SELECT id, val FROM ${TBL}_s ORDER BY id");
    lives_ok { $db->spool($sid) } 'spool() が die しない';

    # rows.do を直接読み返す
    my $rows = do "/tmp/spool/$sid/rows.do";
    is(scalar(@$rows), 2, '2件読み返せる');
    is($rows->[0]{val}, 'x', '1件目の val');

    # meta.do を直接読み返す
    my $meta_wrap = do "/tmp/spool/$sid/meta.do";
    is($meta_wrap->{'#'}{count}, 2, 'count が正しい');
    is($meta_wrap->{'#'}{attrs}{id}, 'num', 'id は num');

    Spool::remove($sid);
    $db->close();
};

# --- spec#23. spool 0件でも作成・attrs/order 保持・count=0 ---
subtest 'spool 0件でも正しく作成' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = 'dbobjtest0' . $$;

    $db->run("CREATE TEMP TABLE ${TBL}_s0 (id INT, val TEXT)");
    $db->run("SELECT id, val FROM ${TBL}_s0");
    lives_ok { $db->spool($sid) } '0件でも die しない';

    my $meta_wrap = do "/tmp/spool/$sid/meta.do";
    is($meta_wrap->{'#'}{count}, 0, 'count は 0');
    ok(exists $meta_wrap->{'#'}{attrs}{id},  'attrs に id が存在');
    ok(exists $meta_wrap->{'#'}{attrs}{val}, 'attrs に val が存在');
    is_deeply($meta_wrap->{'#'}{order}, ['id', 'val'], 'order が正しい');

    Spool::remove($sid);
    $db->close();
};

# --- spec#24. spool 経由の NULL → '' ---
subtest 'spool 経由の NULL を空文字に変換' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = 'dbobjtestnull' . $$;

    $db->run("CREATE TEMP TABLE ${TBL}_sn (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_sn VALUES (1, NULL)");
    $db->run("SELECT val FROM ${TBL}_sn");
    $db->spool($sid);

    my $rows = do "/tmp/spool/$sid/rows.do";
    is($rows->[0]{val}, '', 'spool 経由の NULL は "" になる');

    Spool::remove($sid);
    $db->close();
};

done_testing;
