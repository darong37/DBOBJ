package DBOBJ;

# Terms:
# DBOBJ は DBI の薄いラッパーであり、DBI の挙動を独自に作り替えない
# データ取得は get(), list(), arrays(), hashes() に限定する
# DB から取得した値に undef が含まれていた場合は、返却時に '' へ置き換える
# AoH     : ハッシュリファレンスの配列リファレンス
# AoA     : 配列リファレンスの配列リファレンス
# metaAoh : MetaAoh オブジェクト。meta（order, cols, attrs, grouped）を持ち、件数は count() メソッドで得る。仕様は lib/MetaAoh.spec.md に従う
# dbname  : 接続先 PostgreSQL データベース名
# spool_id : Spool の spool_id（[A-Za-z0-9]+）。仕様は lib/Spool.spec.md に従う
# ordercols : SQL のトップレベル ORDER BY から解析したソート列名のリスト。直近の spool() の結果を内部状態に保持する
#
# Rules:
# CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は lib/CommonIO.spec.md に従う
# new() に dbname（接続先 PostgreSQL データベース名）は必須。PGHOST, PGPORT, PGUSER, PGPASSWORD は必須。PGDATABASE 環境変数は参照しない
# DBI の自動例外は無効にし、エラーは手動検知して CommonIO の dying() でエラーログを残して die する
# DB から取得した値に undef が含まれていた場合は、get(), list(), arrays(), hashes() の返却時に '' へ置き換える
# prepare() -> execute() の呼び出し順序、取得系 API の結果セット消費、呼び出し順序に関する挙動は DBI の仕様に従う。DBOBJ は独自に制御しない
# run(sql) は bind を取らない。bind が必要な場合は prepare(sql) -> execute(@bind) を使う
# attrs の型は DBI の型情報をもとに判定する。REAL・INTEGER・NUMERIC 系（smallint, integer, bigint, real, double precision, numeric など）は 'num'、それ以外は 'str'
# hashes() は DBI の型情報から MetaAoh のカラム指定（'str' は NAME、'num' は NAME#）を組み立てて MetaAoh->new に渡す
# get() は結果が 1行1列でない場合 die する。0行でも複数行でも複数列でも die する
# list() は結果が 1列でない場合 die する
# arrays() は 0件なら [] を返す
# hashes() は metaAoh を返す。0件でも空の metaAoh を返す（カラム情報は保持し count() == 0）
# グループ化は呼び出し側が metaAoh の group() で行う。DBOBJ は関与しない
# prepare(sql) は sql を内部状態に保持する（spool() の ORDER BY 解析に使う）
# spool(spool_id) は実行済みステートメントハンドルから fetch ループで 1 行ずつ Spool->open / add / close へ流し、spool_id を返す。結果セットを metaAoh としてメモリに作らない
# spool() の schema は hashes() と同じ規則（'str' は NAME、'num' は NAME#）で DBI の列情報から自動生成して Spool->open に渡す
# spool() は fetch した値の undef を '' へ置き換えてから Spool の add() に渡す
# spool() は prepare() で保持した SQL のトップレベル ORDER BY を解析してソート列を得る。ORDER BY がない SQL は die する
# ORDER BY の解析は大文字小文字や書式の規約に依存しない。位置指定（ORDER BY 1）や式など列名として解決できない指定、SELECT 句の列に存在しない列は die する。文字列リテラル・コメント・括弧内（サブクエリ等）の ORDER BY はトップレベルとして扱わない
# DBOBJ は渡された SQL を書き換えない。ORDER BY の自動付与はしない
# 解析で得たソート列は ordercols として内部状態に保持し、Spool の records 確定のキー列として利用・検証できる形にする。解析をすり抜けた順序違反は Spool 側の再出現 die が二段目の安全網として捕まえる
# psql(sqlfile) は dbname と PGHOST, PGPORT, PGUSER, PGPASSWORD を使って psql を別プロセスで起動する。sqlfile が存在しない場合は die する。SQL エラー時に非 0 終了する設定で起動し、NOTICE では終了しない。終了コードが 0 以外の場合は die する
# close() は DB 接続を閉じる

use strict;
use warnings;
use DBI;
use CommonIO qw(dying);
use MetaAoh;
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
    dying("DBOBJ.new: dbname is required") unless defined $dbname && $dbname ne '';

    for my $var (qw(PGHOST PGPORT PGUSER PGPASSWORD)) {
        dying("DBOBJ.new: $var is not set") unless defined $ENV{$var} && $ENV{$var} ne '';
    }

    my $dsn = "dbi:Pg:dbname=$dbname;host=$ENV{PGHOST};port=$ENV{PGPORT}";
    my $dbh = DBI->connect($dsn, $ENV{PGUSER}, $ENV{PGPASSWORD}, {
        RaiseError          => 0,
        PrintError          => 0,
        pg_enable_utf8      => 1,
        AutoInactiveDestroy => 1,
    }) or dying("DBOBJ.new: " . DBI->errstr);

    $dbh->do("SET client_min_messages = WARNING")
        or dying("DBOBJ.new: " . $dbh->errstr);

    return bless {
        dbname   => $dbname,
        dbh      => $dbh,
        sth      => undef,
        sql      => undef,
        ordercols => [],
    }, $class;
}

sub prepare {
    my ($self, $sql) = @_;
    $self->{sth}->finish() if $self->{sth};
    $self->{sth} = $self->{dbh}->prepare($sql)
        or dying("DBOBJ.prepare: " . $self->{dbh}->errstr);
    # Keep the SQL text so spool() can parse its top-level ORDER BY.
    $self->{sql} = $sql;
    return $self;
}

sub execute {
    my ($self, @bind) = @_;
    $self->{sth}->execute(@bind)
        or dying("DBOBJ.execute: " . $self->{sth}->errstr);
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
    dying(sprintf("DBOBJ.get: expected 1 row and 1 col, got %d rows, %d cols",
        scalar(@$rows),
        $rows->[0] ? scalar(@{$rows->[0]}) : 0))
        unless @$rows == 1 && @{$rows->[0]} == 1;
    return _normalize($rows->[0][0]);
}

sub list {
    my ($self) = @_;
    my $ncols = $self->{sth}{NUM_OF_FIELDS};
    dying("DBOBJ.list: no active statement") unless defined $ncols;
    dying("DBOBJ.list: expected 1 col, got $ncols") unless $ncols == 1;
    my $rows = $self->{sth}->fetchall_arrayref();
    return map { _normalize($_->[0]) } @$rows;
}

sub arrays {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref();
    return [] unless @$rows;
    return [ map { [ map { _normalize($_) } @$_ ] } @$rows ];
}

# Build MetaAoh column specs (NAME for str, NAME# for num) from the statement handle.
# $api is the caller's API name, used only for the error message.
sub _order_spec {
    my ($sth, $api) = @_;
    my $names = $sth->{NAME};
    my $types = $sth->{TYPE};
    dying("DBOBJ.$api: no column info (not a SELECT?)") unless defined $names && defined $types;
    my @spec;
    for my $i (0 .. $#$names) {
        my $type = $TYPE_CLASS{$types->[$i]} // 'str';
        push @spec, $type eq 'num' ? "$names->[$i]#" : $names->[$i];
    }
    return @spec;
}

sub hashes {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref({});
    # Replace undef with '' to satisfy MetaAoh's no-undef contract.
    for my $row (@$rows) {
        for my $key (keys %$row) {
            $row->{$key} = '' unless defined $row->{$key};
        }
    }
    return MetaAoh->new($rows, _order_spec($self->{sth}, 'hashes'));
}

# Blank out string literals, quoted identifiers and comments so that the
# ORDER BY scan never matches inside them. Lengths are preserved.
sub _masksql {
    my ($sql) = @_;
    $sql =~ s{('(?:[^']|'')*')|("(?:[^"]|"")*")|(--[^\n]*)|(/\*.*?\*/)}{' ' x length($&)}gse;
    return $sql;
}

# Parse the top-level ORDER BY of the SQL and return its sort column names.
# Anything that cannot be resolved to a plain column name dies: sorted input
# is a precondition for Spool, so unverifiable ordering is an error.
sub _ordercols {
    my ($sql) = @_;
    my $masked = _masksql($sql);

    # Locate the last ORDER BY at parenthesis depth 0 (subqueries are deeper).
    my $depth = 0;
    my $start = -1;
    while ($masked =~ /(\(|\)|\bORDER\s+BY\b)/gi) {
        my $tok = $1;
        if    ($tok eq '(') { $depth++ }
        elsif ($tok eq ')') { $depth-- }
        elsif ($depth == 0) { $start = pos($masked) }
    }
    dying("DBOBJ.spool: top-level ORDER BY not found") if $start < 0;

    # The clause ends at a trailing top-level keyword or at end of SQL.
    # Parenthesized sort specs are expressions and die below anyway.
    my $clause = substr($masked, $start);
    $clause =~ s/\b(?:LIMIT|OFFSET|FETCH|FOR)\b.*\z//is;

    my @cols;
    for my $item (split /,/, $clause) {
        $item =~ s/\A\s+|\s+\z//g;
        # A bare identifier with optional ASC/DESC and NULLS FIRST/LAST resolves
        # to a column name. Positions, expressions, qualified or quoted names die.
        dying("DBOBJ.spool: cannot resolve sort column: $item")
            unless $item =~ /\A([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:ASC|DESC))?(?:\s+NULLS\s+(?:FIRST|LAST))?\z/i;
        # PostgreSQL folds unquoted identifiers to lowercase, as does sth NAME.
        push @cols, lc $1;
    }
    return @cols;
}

sub spool {
    my ($self, $spool_id) = @_;
    dying("DBOBJ.spool: no prepared SQL") unless defined $self->{sql};

    my @ordercols = _ordercols($self->{sql});
    my @spec = _order_spec($self->{sth}, 'spool');
    my %cols = map { $_ => 1 } @{$self->{sth}{NAME}};
    for my $col (@ordercols) {
        dying("DBOBJ.spool: sort column not in result: $col") unless $cols{$col};
    }
    $self->{ordercols} = \@ordercols;

    my $writer = Spool->open($spool_id, @spec);
    while (my $row = $self->{sth}->fetchrow_hashref()) {
        for my $key (keys %$row) {
            $row->{$key} = '' unless defined $row->{$key};
        }
        $writer->add($row);
    }
    dying("DBOBJ.spool: " . $self->{sth}->errstr) if $self->{sth}->err;
    $writer->close();
    return $spool_id;
}

sub psql {
    my ($self, $sqlfile) = @_;
    dying("DBOBJ.psql: file not found: $sqlfile") unless -f $sqlfile;

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
    dying("DBOBJ.psql: exit code " . ($? >> 8)) if $? != 0;
    return $self;
}

sub close {
    my ($self) = @_;
    $self->{sth}->finish() if $self->{sth};
    $self->{dbh}->disconnect() if $self->{dbh};
    return $self;
}

1;
