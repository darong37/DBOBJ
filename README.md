# DBOBJ

[日本語版はこちら](README_ja.md)

A lightweight PostgreSQL data access object for Perl. Wraps DBI with a simple, consistent API.

## Requirements

- Perl 5
- DBI, DBD::Pg
- PostgreSQL environment variables: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`
- `lib/MetaAoh.pm` and `lib/CommonIO.pm` (bundled in `lib/`)
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
- Errors are raised via CommonIO `dying()`, which writes an error log before throwing

## Testing

```bash
prove -lr test/
```

Requires a live PostgreSQL connection via environment variables.
