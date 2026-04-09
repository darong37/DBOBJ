package DBOBJ;

# Terms:
# DBOBJ は DBI の薄いラッパーであり、DBI の挙動を独自に作り替えない
# データ取得は get(), list(), arrays(), hashes(), spool() に限定する
# DB から取得した値に undef が含まれていた場合は、返却時に '' へ置き換える
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
# new() に dbname（接続先 PostgreSQL データベース名）は必須。PGHOST, PGPORT, PGUSER, PGPASSWORD は必須。PGDATABASE 環境変数は参照しない
# DBI の自動例外は無効にし、エラーは手動検知して die する
# DB から取得した値に undef が含まれていた場合は、get(), list(), arrays(), hashes(), spool() の返却時に '' へ置き換える
# prepare() -> execute() の呼び出し順序、取得系 API の結果セット消費、呼び出し順序に関する挙動は DBI の仕様に従う。DBOBJ は独自に制御しない
# run(sql) は bind を取らない。bind が必要な場合は prepare(sql) -> execute(@bind) を使う
# attrs の型は DBI の型情報をもとに判定する。REAL・INTEGER・NUMERIC 系（smallint, integer, bigint, real, double precision, numeric など）は 'num'、それ以外は 'str'
# get() は結果が 1行1列でない場合 die する。0行でも複数行でも複数列でも die する
# list() は結果が 1列でない場合 die する
# arrays() は 0件なら [] を返す
# hashes() は先頭に meta を持つメタ付き AoH で返す。0件なら [] を返す（meta も含まない）。count はデータ行数であり、meta 自身は数えない
# グループ化は TableTools の group() で行う。DBOBJ は関与しない
# psql(sqlfile) は dbname と PGHOST, PGPORT, PGUSER, PGPASSWORD を使って psql を別プロセスで起動する。sqlfile が存在しない場合は die する。SQL エラー時に非 0 終了する設定で起動し、NOTICE では終了しない。終了コードが 0 以外の場合は die する
# spool(spool_id) は 0件でも spool を作成し、attrs と order を保持し、count は 0 とする。Spool->open(spool_id) で開き、全行を add() した後に Spool->meta() で meta を渡して close() する。結果をメモリに展開しない
# close() は DB 接続を閉じる

use strict;
use warnings;
use DBI;
use Spool;

# DBI の sth->{TYPE} が返す SQL 型コードを DBOBJ の attrs 型へ正規化する。
# ここにない型コードはすべて 'str' とする。
my %TYPE_CLASS = (
    2  => 'num',  # SQL_NUMERIC
    4  => 'num',  # SQL_INTEGER
    5  => 'num',  # SQL_SMALLINT
    6  => 'num',  # SQL_FLOAT
    7  => 'num',  # SQL_REAL
    8  => 'num',  # SQL_DOUBLE
    -5 => 'num',  # SQL_BIGINT
    -6 => 'num',  # SQL_TINYINT
);

sub new {
    my ($class, $dbname) = @_;
    die "DBOBJ.new: dbname is required" unless defined $dbname && $dbname ne '';

    for my $var (qw(PGHOST PGPORT PGUSER PGPASSWORD)) {
        die "DBOBJ.new: $var is not set" unless defined $ENV{$var} && $ENV{$var} ne '';
    }

    my $dsn = "dbi:Pg:dbname=$dbname;host=$ENV{PGHOST};port=$ENV{PGPORT}";
    my $dbh = DBI->connect($dsn, $ENV{PGUSER}, $ENV{PGPASSWORD}, {
        RaiseError          => 0,
        PrintError          => 0,
        pg_enable_utf8      => 1,
        AutoInactiveDestroy => 1,
    }) or die "DBOBJ.new: " . DBI->errstr;

    $dbh->do("SET client_min_messages = WARNING")
        or die "DBOBJ.new: " . $dbh->errstr;

    return bless {
        dbname => $dbname,
        dbh    => $dbh,
        sth    => undef,
    }, $class;
}

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

# DB 取得値の undef を返却用に空文字へ正規化する。
sub _normalize {
    my ($val) = @_;
    return defined $val ? $val : '';
}

sub get {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref();
    die sprintf("DBOBJ.get: expected 1 row and 1 col, got %d rows, %d cols",
        scalar(@$rows),
        $rows->[0] ? scalar(@{$rows->[0]}) : 0)
        unless @$rows == 1 && @{$rows->[0]} == 1;
    return _normalize($rows->[0][0]);
}

sub list {
    my ($self) = @_;
    my $ncols = $self->{sth}{NUM_OF_FIELDS};
    die "DBOBJ.list: no active statement" unless defined $ncols;
    die "DBOBJ.list: expected 1 col, got $ncols" unless $ncols == 1;
    my $rows = $self->{sth}->fetchall_arrayref();
    return map { _normalize($_->[0]) } @$rows;
}

sub arrays {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref();
    return [] unless @$rows;
    return [ map { [ map { _normalize($_) } @$_ ] } @$rows ];
}

# statement handle の列情報から hashes()/spool() 用の meta を組み立てる。
sub _build_meta {
    my ($sth, $count) = @_;
    my $names = $sth->{NAME};
    my $types = $sth->{TYPE};
    my %attrs;
    for my $i (0 .. $#$names) {
        $attrs{$names->[$i]} = $TYPE_CLASS{$types->[$i]} // 'str';
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
    my $rows = $self->{sth}->fetchall_arrayref({});
    return [] unless @$rows;

    # undef を '' に変換
    for my $row (@$rows) {
        for my $key (keys %$row) {
            $row->{$key} = '' unless defined $row->{$key};
        }
    }

    my $meta = _build_meta($self->{sth}, scalar(@$rows));
    return [$meta, @$rows];
}

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
        '-d', $self->{dbname},
        '-f', $sqlfile,
    );
    system(@cmd);
    die "DBOBJ.psql: exit code " . ($? >> 8) if $? != 0;
    return $self;
}

sub spool {
    my ($self, $spool_id) = @_;
    my $sth = $self->{sth};
    my $sp = Spool->open($spool_id);

    my $count = 0;
    while (my $row = $sth->fetchrow_hashref()) {
        for my $key (keys %$row) {
            $row->{$key} = '' unless defined $row->{$key};
        }
        $sp->add($row);
        $count++;
    }

    my $meta = _build_meta($sth, $count);
    $sp->meta($meta);
    $sp->close();
    return $self;
}

sub close {
    my ($self) = @_;
    $self->{sth}->finish() if $self->{sth};
    $self->{dbh}->disconnect() if $self->{dbh};
    return $self;
}

1;
