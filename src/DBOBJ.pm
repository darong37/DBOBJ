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
