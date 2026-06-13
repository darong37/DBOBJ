package DBOBJ;

# Terms:
# DBOBJ は DBI の薄いラッパーであり、DBI の挙動を独自に作り替えない
# データ取得は get(), list(), arrays(), hashes() に限定する
# DB から取得した値に undef が含まれていた場合は、返却時に '' へ置き換える
# AoH     : ハッシュリファレンスの配列リファレンス
# AoA     : 配列リファレンスの配列リファレンス
# metaAoh : MetaAoh オブジェクト。meta（order, cols, attrs, grouped）を持ち、件数は count() メソッドで得る。仕様は lib/MetaAoh.spec.md に従う
# dbname  : 接続先 PostgreSQL データベース名
# dbo     : 接続済みの DBOBJ オブジェクト（new(dbname) の戻り値）
# spool_id : Spool の spool_id（[A-Za-z0-9]+）。仕様は lib/Spool.spec.md に従う
# confirm : spool() の確定モード指定。空 = lines、文字列（カラム名）の並び = records、配列リファレンスの並び = grouping
# Psql    : psql プロセス連動の独立パッケージ DBOBJ::Psql（src/DBOBJ.pm 内に置く）。run と in を持ち、内部関数を持たない。Rules では DBOBJ::Psql を Psql と略記する
#
# Rules:
# CommonIO はすべての基盤となるライブラリであり、積極的に使用する。仕様は lib/CommonIO.spec.md に従う
# new() に dbname（接続先 PostgreSQL データベース名）は必須。PGHOST, PGPORT, PGUSER, PGPASSWORD は必須。PGDATABASE 環境変数は参照しない
# 接続情報の取り込みは new() の1箇所だけで行う。PGHOST, PGPORT, PGUSER は内部状態（host, port, user）へ取り込み、DBI 接続も psql 起動もこの値を使う
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
# spool(spool_id, @confirm) は実行済みステートメントハンドルから fetch ループで 1 行ずつ Spool->open / add / close へ流し、続けて Spool の確定まで行って spool_id を返す。結果セットを metaAoh としてメモリに作らない
# spool() の schema は hashes() と同じ規則（'str' は NAME、'num' は NAME#）で DBI の列情報から自動生成して Spool->open に渡す
# spool() は fetch した値の undef を '' へ置き換えてから Spool の add() に渡す
# spool() の確定モードは @confirm の形で判別する。空なら lines、文字列（カラム名）の並びなら records、配列リファレンスの並びなら grouping。判別は先頭要素の形のみで行う
# spool() は引数・順序・列名の正しさを事前にチェックしない。schema 外の列名・ソート漏れ（キー再出現）・形の混在などの誤りは、実行時に Spool / MetaAoh の die が検知する
# 並び順の指定はグループ指定と別には設けない。records のキー列の並び・grouping の配列リファレンスに出てきた列の並び（level1…level2…の連結順）を、そのままデータに要求される並び順の前提とする。連続性が保たれていれば昇順・降順は問わない
# DBOBJ は渡された SQL を書き換えない
# psql プロセスの起動は Psql::run(dbo, @args) に集約する。接続情報は dbo が new() で取り込んだ値（dbname, host, port, user）を使い、SQL エラー時に非 0 終了する設定（ON_ERROR_STOP=1）で起動し、NOTICE では終了しない。終了コードが 0 以外の場合は die する
# Psql の単独利用は想定しない。psql 連動は DBOBJ->new で作った接続オブジェクト経由の1本だけとする
# Psql は %ENV を直接読まない。例外は PGPASSWORD のみで、オブジェクトには保持せず環境変数のまま psql 子プロセスへ引き継ぐ
# 事前検証はしない。sqlfile の不在や SQL の誤りは psql 自身が非 0 終了で検知し、終了コード経由で die する
# DBOBJ の psql(sqlfile) は Psql::run('-f') を、in(dir, tbl) は Psql::in を、$self をそのまま渡して呼び、$self を返す
# Psql::in(dbo, dir, tbl) は dir 配下のテーブル一式（DDL・TSV・keys）を psql 経由で DB へ投入する
# Psql::in の tbl が schema.name 形式（/^(\w+)\.(\w+)$/）なら schema と name に分離する。形式でなければ schema は public、name は tbl のまま。ディレクトリ名・ファイル名には name 部分のみを使う
# Psql::in の DDL は dir/name/name.sql を優先し、なければ dir/name/name.ddl を使う。どちらも存在しなければ die する。決定した DDL ファイルを -f で実行する
# Psql::in のデータ投入は dir/name/name.tsv が存在すればそれを \copy schema.name from ... で投入する（単一 TSV）。なければ dir/name/name.0000.tsv から連番（%04d）で存在するファイルを順に \copy で投入し、番号が途切れたところで終了する（分割 TSV）。どちらも存在しなければ投入をスキップする。\copy は -c で実行する
# Psql::in は dir/name/name.keys が存在すれば -f で実行する。存在しなければスキップする
# Psql::in は各 psql 実行の前に、実行内容を CommonIO の log('info', ...) で表示する
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

    # 接続情報はここで一度だけ取り込む。DBI も psql もこの値を使うため、
    # 以後 %ENV が変わっても両者の接続先がズレることはない。
    my ($host, $port, $user) = @ENV{qw(PGHOST PGPORT PGUSER)};

    my $dsn = "dbi:Pg:dbname=$dbname;host=$host;port=$port";
    my $dbh = DBI->connect($dsn, $user, $ENV{PGPASSWORD}, {
        RaiseError          => 0,
        PrintError          => 0,
        pg_enable_utf8      => 1,
        AutoInactiveDestroy => 1,
    }) or dying("DBOBJ.new: " . DBI->errstr);

    $dbh->do("SET client_min_messages = WARNING")
        or dying("DBOBJ.new: " . $dbh->errstr);

    return bless {
        dbname => $dbname,
        host   => $host,
        port   => $port,
        user   => $user,
        dbh    => $dbh,
        sth    => undef,
    }, $class;
}

sub prepare {
    my ($self, $sql) = @_;
    $self->{sth}->finish() if $self->{sth};
    $self->{sth} = $self->{dbh}->prepare($sql)
        or dying("DBOBJ.prepare: " . $self->{dbh}->errstr);
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

sub get {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref();
    dying(sprintf("DBOBJ.get: expected 1 row and 1 col, got %d rows, %d cols",
        scalar(@$rows),
        $rows->[0] ? scalar(@{$rows->[0]}) : 0))
        unless @$rows == 1 && @{$rows->[0]} == 1;
    return $rows->[0][0] // '';
}

sub list {
    my ($self) = @_;
    my $ncols = $self->{sth}{NUM_OF_FIELDS};
    dying("DBOBJ.list: no active statement") unless defined $ncols;
    dying("DBOBJ.list: expected 1 col, got $ncols") unless $ncols == 1;
    my $rows = $self->{sth}->fetchall_arrayref();
    return map { $_->[0] // '' } @$rows;
}

sub arrays {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref();
    return [] unless @$rows;
    return [ map { [ map { $_ // '' } @$_ ] } @$rows ];
}

# ステートメントハンドルの列情報を MetaAoh の order 記法（str は NAME、
# num は NAME#）へ変換する。hashes() と spool() が共有する唯一の規則。
sub sth2order {
    my ($sth) = @_;
    my ($names, $types) = ($sth->{NAME}, $sth->{TYPE});
    my @order;
    for my $i (0 .. $#$names) {
        my $type = $TYPE_CLASS{$types->[$i]} // 'str';
        push @order, $type eq 'num' ? "$names->[$i]#" : $names->[$i];
    }
    return @order;
}

sub hashes {
    my ($self) = @_;
    my $rows = $self->{sth}->fetchall_arrayref({});
    # MetaAoh の「undef を含まない」契約を満たすため undef を '' へ置き換える。
    for my $row (@$rows) {
        $row->{$_} //= '' for keys %$row;
    }
    return MetaAoh->new($rows, sth2order($self->{sth}));
}

sub hashing {
    my ($self) = @_;
    # レガシー対応の非推奨メソッド。新規コードは hashes()(metaAoh)を使うこと。
    # hashes() の metaAoh を平坦化した素の AoH を返す。undef→'' 等の値の扱いは
    # hashes() に従い、独自の取得処理は持たない。0件なら空リスト。
    # レガシー専用のため効率最適化はしない(metaAoh 構築を経由する)。
    return @{ $self->hashes()->toAoh() };
}

sub spool {
    my ($self, $spool_id, @confirm) = @_;
    my $writer = Spool->open($spool_id, sth2order($self->{sth}));
    while (my $row = $self->{sth}->fetchrow_hashref()) {
        $row->{$_} //= '' for keys %$row;
        $writer->add($row);
    }
    dying("DBOBJ.spool: " . $self->{sth}->errstr) if $self->{sth}->err;
    $writer->close();

    # Spool の confirm API の引数の形に合わせて確定モードを振り分ける。
    # 列名や並び順の正しさはここでは確認しない。違反は Spool が実行時に
    # die で検知する。
    if    (!@confirm)                  { Spool::line($spool_id) }
    elsif (ref $confirm[0] eq 'ARRAY') { Spool::grouping($spool_id, @confirm) }
    else                               { Spool::records($spool_id, @confirm) }
    return $spool_id;
}

sub psql {
    my ($self, $sqlfile) = @_;
    DBOBJ::Psql::run($self, '-f', $sqlfile);
    return $self;
}

sub in {
    my ($self, $dir, $tbl) = @_;
    DBOBJ::Psql::in($self, $dir, $tbl);
    return $self;
}

sub close {
    my ($self) = @_;
    $self->{sth}->finish() if $self->{sth};
    $self->{dbh}->disconnect() if $self->{dbh};
    return $self;
}

package DBOBJ::Psql;

use CommonIO qw(dying);

# DBOBJ::Psql は PostgreSQL データベースと psql プロセスを連動させる。
# bind の配布単位を 1 ファイルに保つため DBOBJ とファイルを共有するが、
# 独立したパッケージであり、依存は CommonIO のみで DBI には触れない。
# 単独利用は想定しない。DBOBJ->new で作った接続オブジェクトを経由する
# 1 本だけが psql 連動の道筋である。
#   - run() は psql 起動の唯一の入口。接続情報は DBOBJ オブジェクト
#     （new() で取り込んだ dbname / host / port / user）を使い、
#     DBI と psql の接続先は常に一致する。%ENV はここでは読まない。
#     例外は PGPASSWORD のみで、環境変数のまま子プロセスへ引き継ぐ。
#     ON_ERROR_STOP=1 により SQL エラーで非 0 終了し（NOTICE は素通り）、
#     終了コードが 0 以外なら dying() で die する
#   - 事前検証はしない。ファイル不在や SQL の誤りは psql 自身が
#     終了コードで検知する
#   - in() は Table プロジェクトが生成するテーブル一式（$dir/<name>/ の
#     DDL・TSV・keys ファイル）を DDL → \copy → keys の順に投入し、
#     各実行の前に内容を CommonIO::log で表示する

sub run {
    my ($dbo, @args) = @_;
    system(
        'psql',
        '--set', 'ON_ERROR_STOP=1',
        '-h', $dbo->{host},
        '-p', $dbo->{port},
        '-U', $dbo->{user},
        '-d', $dbo->{dbname},
        @args,
    );
    dying("DBOBJ.Psql.run: exit code " . ($? >> 8)) if $? != 0;
    return;
}

sub in {
    my ($dbo, $dir, $tbl) = @_;
    # "schema.name" 形式を schema と name に分離する。schema なしは public。
    # ディレクトリ名・ファイル名には name 部分のみを使う。
    my ($schema, $name) = $tbl =~ /^(\w+)\.(\w+)$/ ? ($1, $2) : ('public', $tbl);
    my $base = "$dir/$name/$name";

    my $ddl = "$base.sql";
    $ddl = "$base.ddl" unless -f $ddl;
    dying("DBOBJ.Psql.in: DDL not exist: $base.sql or $base.ddl") unless -f $ddl;
    CommonIO::log('info', "sql> \\i $ddl");
    run($dbo, '-f', $ddl);

    # 単一 TSV を優先し、なければ %04d の連番を途切れるまで辿る。
    my @tsv;
    if (-f "$base.tsv") {
        @tsv = ("$base.tsv");
    }
    else {
        for (my $i = 0; ; $i++) {
            my $file = sprintf("%s.%04d.tsv", $base, $i);
            last unless -f $file;
            push @tsv, $file;
        }
    }
    for my $file (@tsv) {
        CommonIO::log('info', "sql> copy $schema.$name from $file");
        run($dbo, '-c', "\\copy $schema.$name from '$file'");
    }

    if (-f "$base.keys") {
        CommonIO::log('info', "sql> \\i $base.keys");
        run($dbo, '-f', "$base.keys");
    }
    return;
}

1;
