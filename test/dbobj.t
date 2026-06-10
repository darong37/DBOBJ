use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBOBJ;
use MetaAoh;

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

    # hashes() returns metaAoh; row 0 is the first data row
    $db->run("SELECT val FROM ${TBL}_null");
    my $m = $db->hashes();
    is($m->[0]{val}, '', 'hashes() で NULL → ""');

    $db->close();
};

# --- spec#15. prepare + execute バインド変数 ---
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

# --- spec#16. DML（INSERT/UPDATE/DELETE）---
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

# --- spec#17. run で SQL 構文エラー時 die ---
subtest 'run SQL 構文エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->run("SELCT * FROOOM nowhere") } 'SQL 構文エラーで die';
    $db->close();
};

# --- spec#18. prepare + execute で SQL エラー時 die ---
subtest 'prepare + execute SQL エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok {
        $db->prepare("SELECT val FROM nonexistent_table_xyz WHERE id = ?");
        $db->execute(1);
    } 'prepare + execute で SQL エラー時 die';
    $db->close();
};

# --- spec#19. psql($sqlfile) ファイル実行 ---
subtest 'psql SQLファイル実行' => sub {
    my $db = DBOBJ->new('develop');
    lives_ok { $db->psql('test/insert.sql') } 'psql() が die しない';
    $db->close();
};

# --- spec#20. psql でファイル不在の場合 die ---
subtest 'psql ファイル不在で die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->psql('test/nonexistent.sql') } 'ファイル不在で die';
    $db->close();
};

# --- spec#21. psql で終了コード非0の場合 die ---
subtest 'psql SQL エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->psql('test/error.sql') } 'SQL エラーで die';
    $db->close();
};

# --- spec#22. psql で NOTICE が出ても die しない ---
subtest 'psql NOTICE は die しない' => sub {
    my $db = DBOBJ->new('develop');
    lives_ok { $db->psql('test/notice.sql') } 'NOTICE があっても die しない';
    $db->close();
};

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

done_testing;
