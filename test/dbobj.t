use strict;
use warnings;
use Test::More;
use Test::Exception;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Encode qw(decode);
use DBOBJ;
use MetaAoh;
use Spool;
use CommonIO qw(read_do out_file);

# テスト用テーブル名（他テストと衝突しないよう一意にする）
my $TBL = 'dbobj_test_' . $$;

# テスト用 spool_id の接頭辞（[A-Za-z0-9]+ のみ有効）
my $SPID = 'dbobjtest' . $$;

# in() テスト用のテーブル一式の親ディレクトリ（テスト終了時に自動削除）
my $DIR = tempdir(CLEANUP => 1);

# in() テスト用の標準 DDL のフォーマット（drop & re-create。Table の生成物と同じ構成）
my $DDL = "DROP TABLE IF EXISTS public.%s;\nCREATE TABLE public.%s (id INT, val TEXT);\n";

# in() テスト用のテーブル一式（DDL・TSV・keys）を $dir/$name/ 配下に作る。
# %file は拡張子 => 内容（例: ddl => "CREATE ...", tsv => "1\ta"）
sub mkset {
    my ($dir, $name, %file) = @_;
    make_path("$dir/$name");
    out_file('>', "$dir/$name/$name.$_", $file{$_}) for keys %file;
}

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

    # get の検証
    $db->run("SELECT val FROM ${TBL}_null");
    is($db->get(), '', 'get() で NULL → ""');

    # list の検証
    $db->run("SELECT val FROM ${TBL}_null");
    my @l = $db->list();
    is($l[0], '', 'list() で NULL → ""');

    # arrays の検証
    $db->run("SELECT val FROM ${TBL}_null");
    my $a = $db->arrays();
    is($a->[0][0], '', 'arrays() で NULL → ""');

    # hashes() は metaAoh を返す。0 行目が最初のデータ行
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

# --- spec#24. spool records 確定（退避 → 確定 → 取得）---
subtest 'spool records 確定' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}A";
    $db->run("CREATE TEMP TABLE ${TBL}_sp (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_sp VALUES ('a', 1), ('a', 2), ('b', 3)");
    $db->run("SELECT dept, id FROM ${TBL}_sp ORDER BY dept, id");
    is($db->spool($sid, 'dept'), $sid, 'spool() が spool_id を返す');

    is(Spool::count($sid), 2, 'records で確定済み（dept のグループ数）');
    is_deeply(Spool::get($sid, 0),
        [{dept => 'a', id => 1}, {dept => 'a', id => 2}],
        '1件目のグループが DB の内容と一致');
    is_deeply(Spool::get($sid, 1),
        [{dept => 'b', id => 3}],
        '2件目のグループが DB の内容と一致');
    Spool::remove($sid);
    $db->close();
};

# --- spec#25. spool lines 確定（引数なし・ORDER BY 不要）---
subtest 'spool lines 確定' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}B";
    $db->run("CREATE TEMP TABLE ${TBL}_ln (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_ln VALUES (1, 'a'), (2, 'b'), (3, 'c')");
    $db->run("SELECT id, val FROM ${TBL}_ln");
    is($db->spool($sid), $sid, 'ORDER BY のない SQL でも spool_id を返す');

    is(Spool::count($sid), 3, 'lines で行単位に確定');
    is(ref Spool::get($sid, 0), 'HASH', 'item は行ハッシュ');
    Spool::remove($sid);
    $db->close();
};

# --- spec#26. spool grouping 確定（配列リファレンス指定）---
subtest 'spool grouping 確定' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}C";
    $db->run("CREATE TEMP TABLE ${TBL}_gp (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_gp VALUES ('a', 1), ('a', 2), ('b', 3)");
    $db->run("SELECT dept, id FROM ${TBL}_gp ORDER BY dept, id");
    $db->spool($sid, ['dept']);

    is(Spool::count($sid), 2, 'grouping で dept ごとに確定');
    is_deeply(Spool::get($sid, 0),
        {dept => 'a', '*' => [{id => 1}, {id => 2}]},
        '階層 item（キー列 + "*" 配下）になっている');
    Spool::remove($sid);
    $db->close();
};

# --- spec#27. schema 生成（meta.do の order が NAME#/NAME 規則）---
subtest 'spool の schema 生成' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}D";
    $db->run("CREATE TEMP TABLE ${TBL}_sm (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_sm VALUES (1, 'a')");
    $db->run("SELECT id, val FROM ${TBL}_sm ORDER BY id");
    $db->spool($sid, 'id');

    my $meta = read_do("/tmp/spool/$sid/meta.do");
    is_deeply($meta->{order}, ['id#', 'val'], 'order は num が NAME#・str が NAME');
    Spool::remove($sid);
    $db->close();
};

# --- spec#28. NULL → '' で spool される ---
subtest 'spool で NULL を空文字に変換' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}E";
    $db->run("CREATE TEMP TABLE ${TBL}_sn (id INT, val TEXT)");
    $db->run("INSERT INTO ${TBL}_sn VALUES (1, NULL)");
    $db->run("SELECT id, val FROM ${TBL}_sn ORDER BY id");
    lives_ok { $db->spool($sid) } 'NULL を含む行でも add() で die しない';

    is(Spool::get($sid, 0)->{val}, '', 'NULL は "" として spool される');
    Spool::remove($sid);
    $db->close();
};

# --- spec#29. ソート漏れの records 確定で die ---
subtest 'spool はソート漏れの records 確定で die' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}F";
    $db->run("CREATE TEMP TABLE ${TBL}_us (id INT, dept TEXT)");
    $db->run("INSERT INTO ${TBL}_us VALUES (1, 'b'), (2, 'a'), (3, 'b')");
    $db->run("SELECT dept, id FROM ${TBL}_us ORDER BY id");
    dies_ok { $db->spool($sid, 'dept') } 'キー再出現で die（Spool の検知）';
    Spool::remove($sid);
    $db->close();
};

# --- spec#30. grouping の順序違反で die ---
subtest 'spool は grouping の順序違反で die' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}G";
    $db->run("CREATE TEMP TABLE ${TBL}_ug (id INT, dept TEXT)");
    $db->run("INSERT INTO ${TBL}_ug VALUES (1, 'b'), (2, 'a'), (3, 'b')");
    $db->run("SELECT dept, id FROM ${TBL}_ug ORDER BY id");
    dies_ok { $db->spool($sid, ['dept']) } 'グループ列の再出現で die（Spool の検知）';
    Spool::remove($sid);
    $db->close();
};

# --- spec#31. schema 外の列名で die ---
subtest 'spool は schema 外の列名で die' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}H";
    $db->run("CREATE TEMP TABLE ${TBL}_nc (id INT)");
    $db->run("INSERT INTO ${TBL}_nc VALUES (1)");
    $db->run("SELECT id FROM ${TBL}_nc ORDER BY id");
    dies_ok { $db->spool($sid, 'nocol') } '存在しない列名で die（Spool の検知）';
    Spool::remove($sid);
    $db->close();
};

# --- spec#32. confirm の形の混在で die ---
subtest 'spool は confirm の形の混在で die' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}I";
    $db->run("CREATE TEMP TABLE ${TBL}_mx (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_mx VALUES ('a', 1)");
    $db->run("SELECT dept, id FROM ${TBL}_mx ORDER BY dept, id");
    dies_ok { $db->spool($sid, 'dept', ['id']) } '文字列と配列リファレンスの混在で die';
    Spool::remove($sid);
    $db->close();
};

# --- spec#33. bind 付き prepare + execute 経由の spool ---
subtest 'spool は bind 付きでも動作する' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}J";
    $db->run("CREATE TEMP TABLE ${TBL}_bd (dept TEXT, id INT)");
    $db->run("INSERT INTO ${TBL}_bd VALUES ('a', 1), ('b', 2), ('c', 0)");
    $db->prepare("SELECT dept, id FROM ${TBL}_bd WHERE id > ? ORDER BY dept");
    $db->execute(0);
    $db->spool($sid, 'dept');

    is(Spool::count($sid), 2, 'bind で絞り込んだ結果が spool される');
    Spool::remove($sid);
    $db->close();
};

# --- spec#34. prepare を経ずに spool で die ---
subtest 'spool は prepare なしで die' => sub {
    my $db = DBOBJ->new('develop');
    dies_ok { $db->spool("${SPID}K") } 'prepare していない状態で die';
    $db->close();
};

# --- spec#35. 0件でも確定でき count == 0 ---
subtest 'spool 0件' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}L";
    $db->run("CREATE TEMP TABLE ${TBL}_z (id INT)");
    $db->run("SELECT id FROM ${TBL}_z ORDER BY id");
    is($db->spool($sid, 'id'), $sid, '0件でも spool_id を返す');

    is(Spool::count($sid), 0, '0 件で確定できる');
    Spool::remove($sid);
    $db->close();
};

# --- spec#36. spool_id 重複で die（Spool の die が伝播）---
subtest 'spool は spool_id 重複で die' => sub {
    my $db = DBOBJ->new('develop');
    my $sid = "${SPID}M";
    $db->run("CREATE TEMP TABLE ${TBL}_dup (id INT)");
    $db->run("INSERT INTO ${TBL}_dup VALUES (1)");
    $db->run("SELECT id FROM ${TBL}_dup ORDER BY id");
    $db->spool($sid, 'id');

    $db->run("SELECT id FROM ${TBL}_dup ORDER BY id");
    dies_ok { $db->spool($sid, 'id') } '既存の spool_id で die';
    Spool::remove($sid);
    $db->close();
};

# --- spec#37. in() 単一 TSV（DDL・\copy・keys・戻り値）---
subtest 'in 単一 TSV' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in1";
    mkset($DIR, $name,
        ddl  => sprintf($DDL, $name, $name),
        tsv  => "1\ta\n2\tb",
        keys => "ALTER TABLE public.$name ADD PRIMARY KEY (id);\n",
    );
    is($db->in($DIR, $name), $db, 'in() が $self を返す');

    $db->run("SELECT id, val FROM public.$name ORDER BY id");
    is_deeply($db->arrays(), [[1, 'a'], [2, 'b']], '投入した行数・内容が DB と一致');
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#38. in() 分割 TSV（連番投入・途切れで終了）---
subtest 'in 分割 TSV' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in2";
    mkset($DIR, $name,
        ddl        => sprintf($DDL, $name, $name),
        '0000.tsv' => "1\ta",
        '0001.tsv' => "2\tb",
        '0003.tsv' => "9\tz",
    );
    $db->in($DIR, $name);

    $db->run("SELECT id FROM public.$name ORDER BY id");
    is_deeply([$db->list()], [1, 2], '0000・0001 が投入され、番号が途切れた 0003 は投入されない');
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#39. in() schema.name 形式 ---
subtest 'in schema.name 形式' => sub {
    my $db = DBOBJ->new('develop');
    my $schema = "dbobj_s$$";
    my $name = "${TBL}_in3";
    $db->run("CREATE SCHEMA $schema");
    # ディレクトリ名・ファイル名は name 部分のみ（schema は付かない）
    mkset($DIR, $name,
        ddl => "CREATE TABLE $schema.$name (id INT, val TEXT);\n",
        tsv => "1\ta",
    );
    $db->in($DIR, "$schema.$name");

    $db->run("SELECT val FROM $schema.$name WHERE id = 1");
    is($db->get(), 'a', 'schema 付きテーブルへ投入される');
    $db->run("DROP SCHEMA $schema CASCADE");
    $db->close();
};

# --- spec#40. in() DDL の優先順（.sql > .ddl）---
subtest 'in は .sql を .ddl より優先する' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in4";
    # .ddl が使われたら SQL エラーで die するため、.sql の優先が検証できる
    mkset($DIR, $name,
        sql => sprintf($DDL, $name, $name),
        ddl => "THIS IS NOT SQL;\n",
    );
    lives_ok { $db->in($DIR, $name) } '.sql が使われ die しない';

    $db->run("SELECT COUNT(*) FROM public.$name");
    is($db->get(), 0, '.sql の DDL でテーブルが作られている');
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#41. in() DDL ファイル不在で die ---
subtest 'in は DDL 不在で die' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in5";
    mkset($DIR, $name, tsv => "1\ta");
    throws_ok { $db->in($DIR, $name) } qr/Psql\.in/, 'DDL がどちらも存在せず die';
    $db->close();
};

# --- spec#42. in() TSV 不在はスキップ（0件で作成）---
subtest 'in は TSV 不在をスキップする' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in6";
    mkset($DIR, $name, ddl => sprintf($DDL, $name, $name));
    lives_ok { $db->in($DIR, $name) } 'TSV がなくても die しない';

    $db->run("SELECT COUNT(*) FROM public.$name");
    is($db->get(), 0, 'テーブルは 0 件で作成される');
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#43. in() keys 不在はスキップ ---
subtest 'in は keys 不在をスキップする' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in7";
    mkset($DIR, $name,
        ddl => sprintf($DDL, $name, $name),
        tsv => "1\ta",
    );
    lives_ok { $db->in($DIR, $name) } 'keys がなくても die しない';
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#44. in() keys で PRIMARY KEY 付与 ---
subtest 'in は keys で PRIMARY KEY を付与する' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in8";
    mkset($DIR, $name,
        ddl  => sprintf($DDL, $name, $name),
        tsv  => "1\ta",
        keys => "ALTER TABLE public.$name ADD PRIMARY KEY (id);\n",
    );
    $db->in($DIR, $name);

    $db->run("SELECT COUNT(*) FROM pg_constraint"
        . " WHERE conrelid = 'public.$name'::regclass AND contype = 'p'");
    is($db->get(), 1, 'PRIMARY KEY 制約が付与されている');
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#45. in() DDL の SQL エラーで die（ON_ERROR_STOP=1）---
subtest 'in は DDL の SQL エラーで die' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in9";
    mkset($DIR, $name, ddl => "THIS IS NOT SQL;\n");
    throws_ok { $db->in($DIR, $name) } qr/exit code/, '不正な SQL で die';
    $db->close();
};

# --- spec#46. in() \copy の失敗で die ---
subtest 'in は copy の失敗で die' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in10";
    # 2 カラムのテーブルに 3 カラムの TSV を投入して失敗させる
    mkset($DIR, $name,
        ddl => sprintf($DDL, $name, $name),
        tsv => "1\ta\tEXTRA",
    );
    throws_ok { $db->in($DIR, $name) } qr/exit code/, '列数不一致で die';
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#47. in() 日本語データが化けない ---
subtest 'in は日本語データが化けない' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in11";
    my $jp = decode('UTF-8', 'こんにちは世界');
    mkset($DIR, $name,
        ddl => sprintf($DDL, $name, $name),
        tsv => "1\t$jp",
    );
    $db->in($DIR, $name);

    $db->run("SELECT val FROM public.$name WHERE id = 1");
    is($db->get(), $jp, '日本語が DB のカラム値として化けずに取得できる');
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#48. in() NULL（\N）の投入と取得 ---
subtest 'in は NULL を投入でき取得時に空文字になる' => sub {
    my $db = DBOBJ->new('develop');
    my $name = "${TBL}_in12";
    mkset($DIR, $name,
        ddl => sprintf($DDL, $name, $name),
        tsv => "1\t\\N",
    );
    lives_ok { $db->in($DIR, $name) } 'NULL（\\N）を含む TSV が投入できる';

    $db->run("SELECT val FROM public.$name WHERE id = 1");
    is($db->get(), '', 'NULL は既存規則で空文字として取得される');
    $db->run("DROP TABLE public.$name");
    $db->close();
};

# --- spec#49. 接続情報の連動（new() 後の環境変数変更に影響されない）---
subtest 'psql は new() 時の接続情報を使う' => sub {
    my $db = DBOBJ->new('develop');
    local @ENV{qw(PGHOST PGPORT PGUSER)} = ('broken_host', '1', 'broken_user');
    lives_ok { $db->psql('test/insert.sql') } 'new() 後に環境変数を壊しても psql() が動く';
    $db->close();
};

done_testing;
