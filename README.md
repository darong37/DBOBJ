# DBOBJ

[日本語版はこちら](README_ja.md)

A lightweight PostgreSQL data access object for Perl. Wraps DBI with a simple, consistent API.

## Requirements

- Perl 5
- DBI, DBD::Pg
- PostgreSQL environment variables: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`

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
| `hashes()` | Fetch all rows as AoH with meta header |
| `spool($spool_id)` | Write result to Spool without loading into memory |
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

# Array of hashes with meta
$db->run("SELECT id, name FROM users");
my $result = $db->hashes();
# [{'#' => {attrs=>{id=>'num',name=>'str'}, order=>['id','name'], count=>2}},
#  {id=>1, name=>'Alice'}, {id=>2, name=>'Bob'}]

# Bind variables
$db->prepare("SELECT name FROM users WHERE id = ?");
$db->execute(42);
my $name = $db->get();

# Spool (memory-efficient)
$db->run("SELECT id, name FROM large_table");
$db->spool('my_spool_id');  # writes to /tmp/spool/my_spool_id/

# Execute SQL file
$db->psql('path/to/schema.sql');

$db->close();
```

## Notes

- `NULL` values are always returned as `''` (empty string)
- `get()` dies unless result is exactly 1 row and 1 column
- `list()` dies unless result has exactly 1 column
- `arrays()` and `hashes()` return `[]` for empty results
- `psql()` uses `--set ON_ERROR_STOP=1`; NOTICE messages do not cause errors

## Testing

```bash
prove test/dbobj.t
```

Requires a live PostgreSQL connection via environment variables.
