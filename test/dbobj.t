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

# --- spec#12. prepare + execute バインド変数 ---
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

done_testing;
