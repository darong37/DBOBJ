use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBOBJ;
use MetaAoh;
use Spool;
use CommonIO qw(read_do);

# テスト用テーブル名（他テストと衝突しないよう一意にする）
my $TBL = 'dbobj_test_' . $$;

# テスト用 spool_id の接頭辞（[A-Za-z0-9]+ のみ有効）
my $SPID = 'dbobjtest' . $$;

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

# --- spec#24. spool 正常系（退避 → records 確定 → 取得）---
subtest 'spool 正常系' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}A";
    $db->run("CREATE TEMP TABLE ${TBL}_sp (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_sp VALUES ('a', 1), ('a', 2), ('b', 3)");
    $db->run("SELECT dept, id FROM ${TBL}_sp ORDER BY dept, id");
    my $ret = $db->spool($sid);
    is($ret, $sid, 'spool() が spool_id を返す');

    my $count = Spool::records($sid, 'dept');
    is($count, 2, 'records 確定で dept のグループ数');
    is_deeply(Spool::get($sid, 0),
        [{dept => 'a', id => 1}, {dept => 'a', id => 2}],
        '1件目のグループが DB の内容と一致');
    is_deeply(Spool::get($sid, 1),
        [{dept => 'b', id => 3}],
        '2件目のグループが DB の内容と一致');
    Spool::remove($sid);
    $db->close();
};

# --- spec#25. ordercols の保持と records キー列への利用 ---
subtest 'spool の ordercols' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}B";
    $db->run("CREATE TEMP TABLE ${TBL}_sc (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_sc VALUES ('a', 1), ('b', 2)");
    $db->run("SELECT dept, id FROM ${TBL}_sc ORDER BY dept, id");
    $db->spool($sid);

    is_deeply($db->{ordercols}, ['dept', 'id'], 'ordercols が ORDER BY の列名と一致');
    my $count = Spool::records($sid, @{$db->{ordercols}});
    is($count, 2, 'ordercols を records のキー列として使える');
    Spool::remove($sid);
    $db->close();
};

# --- spec#26. schema 生成（meta.do の order が NAME#/NAME 規則）---
subtest 'spool の schema 生成' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}C";
    $db->run("CREATE TEMP TABLE ${TBL}_sm (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_sm VALUES (1, 'a')");
    $db->run("SELECT id, val FROM ${TBL}_sm ORDER BY id");
    $db->spool($sid);

    my $meta = read_do("/tmp/spool/$sid/meta.do");
    is_deeply($meta->{order}, ['id#', 'val'], 'order は num が NAME#・str が NAME');
    Spool::remove($sid);
    $db->close();
};

# --- spec#27. NULL → '' で spool される ---
subtest 'spool で NULL を空文字に変換' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}D";
    $db->run("CREATE TEMP TABLE ${TBL}_sn (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_sn VALUES (1, NULL)");
    $db->run("SELECT id, val FROM ${TBL}_sn ORDER BY id");
    lives_ok { $db->spool($sid) } 'NULL を含む行でも add() で die しない';

    Spool::records($sid, 'id');
    is(Spool::get($sid, 0)->[0]{val}, '', 'NULL は "" として spool される');
    Spool::remove($sid);
    $db->close();
};

# --- spec#28. ORDER BY なしで die ---
subtest 'spool は ORDER BY なしで die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_no (id INT)");
    $db->run("SELECT id FROM ${TBL}_no");
    throws_ok { $db->spool("${SPID}E") } qr/DBOBJ\.spool/, 'ORDER BY がない SQL で die';
    $db->close();
};

# --- spec#29. 位置指定（ORDER BY 1）で die ---
subtest 'spool は位置指定 ORDER BY で die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_pos (id INT)");
    $db->run("SELECT id FROM ${TBL}_pos ORDER BY 1");
    throws_ok { $db->spool("${SPID}F") } qr/DBOBJ\.spool/, '位置指定で die';
    $db->close();
};

# --- spec#30. 式の ORDER BY で die ---
subtest 'spool は式の ORDER BY で die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_ex (val TEXT)");
    $db->run("SELECT val FROM ${TBL}_ex ORDER BY lower(val)");
    throws_ok { $db->spool("${SPID}G") } qr/DBOBJ\.spool/, '式で die';
    $db->close();
};

# --- spec#31. SELECT 句にない列の ORDER BY で die ---
subtest 'spool は SELECT 句にない列の ORDER BY で die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_nc (dept TEXT, id INT)");
    $db->run("SELECT dept FROM ${TBL}_nc ORDER BY id");
    throws_ok { $db->spool("${SPID}H") } qr/DBOBJ\.spool/, 'SELECT 句にない列で die';
    $db->close();
};

# --- spec#32. サブクエリ内にしか ORDER BY がない SQL で die ---
subtest 'spool はサブクエリ内のみの ORDER BY で die' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_sub (id INT)");
    $db->run("SELECT id FROM (SELECT id FROM ${TBL}_sub ORDER BY id) s");
    throws_ok { $db->spool("${SPID}I") } qr/DBOBJ\.spool/, 'トップレベルに ORDER BY がなく die';
    $db->close();
};

# --- spec#33. 文字列リテラル内の order by を誤認しない ---
subtest 'spool は文字列リテラル内の order by を誤認しない' => sub {
    my $db = DBOBJ->new('develop');
    $db->run("CREATE TEMP TABLE ${TBL}_lit (id INT)");
    $db->run("SELECT id, 'order by id' AS note FROM ${TBL}_lit");
    throws_ok { $db->spool("${SPID}J") } qr/DBOBJ\.spool/, 'リテラル内はトップレベルと見なさない';
    $db->close();
};

# --- spec#34. 小文字・修飾付き・複数列・LIMIT 付きの解析 ---
subtest 'spool の ORDER BY 解析は書式に依存しない' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}K";
    $db->run("CREATE TEMP TABLE ${TBL}_fmt (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_fmt VALUES ('a', 1), ('b', 2)");
    $db->run("select dept, id from ${TBL}_fmt order by dept desc nulls last,\n id asc limit 10");
    $db->spool($sid);

    is_deeply($db->{ordercols}, ['dept', 'id'], '修飾・改行・LIMIT があっても列名へ解決される');
    Spool::remove($sid);
    $db->close();
};

# --- spec#35. bind 付き prepare + execute 経由の spool ---
subtest 'spool は bind 付きでも動作する' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}L";
    $db->run("CREATE TEMP TABLE ${TBL}_bd (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_bd VALUES ('a', 1), ('b', 2), ('c', 0)");
    $db->prepare("SELECT dept, id FROM ${TBL}_bd WHERE id > ? ORDER BY dept");
    $db->execute(0);
    $db->spool($sid);

    is(Spool::records($sid, 'dept'), 2, 'bind で絞り込んだ結果が spool される');
    Spool::remove($sid);
    $db->close();
};

# --- spec#36. prepare を経ずに spool で die ---
subtest 'spool は prepare なしで die' => sub {
    my $db = DBOBJ->new('develop');
    throws_ok { $db->spool("${SPID}M") } qr/DBOBJ\.spool/, 'prepare していない状態で die';
    $db->close();
};

# --- spec#37. 0件でも spool は作られ records で 0 件確定 ---
subtest 'spool 0件' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}N";
    $db->run("CREATE TEMP TABLE ${TBL}_z (id INT)");
    $db->run("SELECT id FROM ${TBL}_z ORDER BY id");
    my $ret = $db->spool($sid);
    is($ret, $sid, '0件でも spool_id を返す');

    Spool::records($sid, 'id');
    is(Spool::count($sid), 0, 'records で 0 件確定できる');
    Spool::remove($sid);
    $db->close();
};

# --- spec#38. spool_id 重複で die（Spool の die が伝播）---
subtest 'spool は spool_id 重複で die' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}O";
    $db->run("CREATE TEMP TABLE ${TBL}_dup (id INT)");
    $db->run("INSERT INTO ${TBL}_dup VALUES (1)");
    $db->run("SELECT id FROM ${TBL}_dup ORDER BY id");
    $db->spool($sid);

    $db->run("SELECT id FROM ${TBL}_dup ORDER BY id");
    dies_ok { $db->spool($sid) } '既存の spool_id で die';
    Spool::remove($sid);
    $db->close();
};

done_testing;
