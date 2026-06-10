# DBOBJ

[日本語版はこちら](README_ja.md)

A lightweight PostgreSQL data access object for Perl. Wraps DBI with a simple, consistent API.

## Requirements

- Perl 5
- DBI, DBD::Pg
- PostgreSQL environment variables: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`
- `lib/MetaAoh.pm`, `lib/CommonIO.pm` and `lib/Spool.pm` (bundled in `lib/`)
- Log directory `output/logs` must exist at runtime (used by CommonIO)

## Installation

Copy `src/DBOBJ.pm` to your project's `lib/` directory.

## API

| Method | Description |
|---|---|
| `new($dbname)` | Connect to PostgreSQL database |
| `prepare($sql)` | Prepare a SQL statement |
| `execute(@bind)` | Execute with bind values |
| `run($sql)` | Prepare and execute without bind values |
| `get()` | Fetch exactly 1 row, 1 column as a scalar |
| `list()` | Fetch all rows of a single column as a flat array |
| `arrays()` | Fetch all rows as AoA (Array of Arrays) |
| `hashes()` | Fetch all rows as a metaAoh (MetaAoh object) |
| `spool($spool_id)` | Stream all rows into a Spool and return the spool_id |
| `psql($sqlfile)` | Execute a SQL file via psql subprocess |
| `close()` | Close the database connection |

## Usage

```perl
use DBOBJ;

my $db = DBOBJ->new('mydb');

# Scalar
$db->run("SELECT COUNT(*) FROM orders");
my $count = $db->get();

# Flat list
$db->run("SELECT name FROM users ORDER BY name");
my @names = $db->list();

# Array of arrays
$db->run("SELECT id, name FROM users");
my $rows = $db->arrays();  # [[1, 'Alice'], [2, 'Bob']]

# MetaAoh (MetaAoh object)
$db->run("SELECT id, name FROM users");
my $m = $db->hashes();
$m->count();              # 2
$m->meta();               # {order=>['id#','name'], cols=>['id','name'], attrs=>{id=>'num',name=>'str'}, grouped=>0}
$m->[0]{name};            # 'Alice'
my $t = $m->group(['id']);  # grouping is done by the caller

# Bind variables
$db->prepare("SELECT name FROM users WHERE id = ?");
$db->execute(42);
my $name = $db->get();

# Spool (stream a large result set to disk row by row)
$db->run("SELECT dept, id FROM users ORDER BY dept, id");
$db->spool('job001');               # returns 'job001'
my $count = Spool::records('job001', @{$db->{ordercols}});  # confirmed by the caller

# Execute SQL file
$db->psql('path/to/schema.sql');

$db->close();
```

## Notes

- `NULL` values are always returned as `''` (empty string)
- `get()` dies unless result is exactly 1 row and 1 column
- `list()` dies unless result has exactly 1 column
- `arrays()` returns `[]` for empty results
- `hashes()` returns an empty metaAoh for empty results (NOT `[]`); column info is preserved
- `spool()` streams rows without building the result set in memory; it requires a
  top-level `ORDER BY` whose entries resolve to plain column names (positions,
  expressions, qualified or quoted names die). The parsed sort columns are kept
  in `$db->{ordercols}`. DBOBJ never rewrites the SQL
- Errors are raised via CommonIO `dying()`, which writes an error log before throwing
- `psql()` runs with `--set ON_ERROR_STOP=1`; NOTICE messages are not errors

## Testing

```bash
prove -lr test/
```

Requires a live PostgreSQL connection via environment variables.
