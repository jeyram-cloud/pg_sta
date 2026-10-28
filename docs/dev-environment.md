# Development environment

The environment `pg_sta` is developed and tested in, and the workflow for
changing the extension.

---

## 1. The environment

| Component | Value |
|---|---|
| Host | macOS (Apple Silicon) |
| Virtualisation | VirtualBox |
| Provisioning | HashiCorp Vagrant |
| Box | `bento/almalinux-9` version `202511.24.0` |
| Guest OS | AlmaLinux 9.8 aarch64 |
| Kernel | `5.14.0-687.54.1.el9_8.aarch64` |
| Database | PostgreSQL 17.11 |
| Machine name | `pgnode17` |
| SSH | `vagrant@127.0.0.1:2201` |
| Key | `~/.vagrant.d/insecure_private_key` |
| Socket | `/var/run/postgresql` |
| Port | 5432 |

The Vagrant project lives in `/Users/jey/postgres17` and the `pg_sta`
working tree lives in `/Users/jey/pg_sta`.

```bash
cd /Users/jey/postgres17
vagrant status
vagrant ssh pgnode17
```

The `pgnode17` name (instead of Vagrant's default `default`) is deliberate:
the machine must be identifiable by name in every script, log and
documentation, because several database clusters exist on this host and a
mistake on the wrong one is expensive.

---

## 2. Databases

The extension is developed against dedicated databases. Nothing in the
project touches the user's application databases.

| Database | Purpose |
|---|---|
| `postgres` | the default cluster database |
| `appdb` | the user's application database — **never** used by the test suites |
| `pg_sta_qa` | the QA suite fixture and assertions |
| `pg_sta_regress` | the `pg_regress` suite |

```bash
sudo -u postgres createdb pg_sta_qa
sudo -u postgres createdb pg_sta_regress
```

Both suites create and drop their own objects, and each runs in its own
schema, so a failed run leaves no more damage than a dropped schema.

---

## 3. The dev loop

### 3.1 The one-line loop

```bash
cd /Users/jey/pg_sta
./scripts/reload.sh pg_sta_qa        # sync + build + install + recreate
./scripts/psql.sh -d pg_sta_qa -c "SELECT * FROM sta.recommendations();"
```

`reload.sh` runs `sync.sh` (copy the tree to the VM), `build.sh install`
(compile and install into the PostgreSQL tree), and then drops and
recreates the extension. It is the fastest way to pick up a change to the
SQL script, because the script is re-executed from scratch on every run.

> `DROP EXTENSION pg_sta CASCADE` drops the `sta` schema and everything in
> it, including the snapshots. **Only run `reload.sh` against a scratch
> database.**

### 3.2 The full loop

| Step | Command | What it does |
|---|---|---|
| 1 | `./scripts/sync.sh` | copy the tree to `/home/vagrant/pg_sta` on the VM |
| 2 | `./scripts/build.sh` | compile on the VM |
| 3 | `./scripts/build.sh install` | compile and install into the PostgreSQL tree |
| 4 | `./scripts/reload.sh [db]` | 1 + 3 + drop/create the extension |
| 5 | `./scripts/psql.sh -d db` | a `psql` session as `postgres` on the VM |
| 6 | `./scripts/installcheck.sh` | run the regression suite and copy the diffs back |
| 7 | `./test/run_qa.sh` | run the QA suite |

`sync.sh` uses `rsync` when the workstation has one. The `rsync` that
ships with macOS is Apple's `openrsync`, which is not protocol compatible
with the `rsync` of the AlmaLinux guest; when the `rsync` fails, the
script falls back to a `tar` stream over `ssh`, which has no such
problem. Both paths exclude the build artefacts and the `.git` directory.

### 3.3 Running psql

```bash
./scripts/psql.sh -d pg_sta_qa -c "SELECT version();"
./scripts/psql.sh -d pg_sta_qa -f test/qa_setup.sql
cat some.sql | ./scripts/psql.sh -d pg_sta_qa
```

`psql.sh` connects as `postgres` with `ON_ERROR_STOP=1`, so a
failing script stops at the failing statement instead of running to the
end. It reaches the server over SSH when the development VM is reachable
and with the local `psql` client when the script runs on the database host
itself — see §3.4.

### 3.4 The connection helper

Every script in `scripts/` and `test/` reaches the database through the
same helper, `scripts/pg_sta_conn.sh`. It resolves the transport once:

| Mode | When it is used | How it connects |
|---|---|---|
| `ssh` | the VM is reachable: the private key is readable and the forwarded port answers | `ssh vagrant@127.0.0.1:2201` → `sudo -u postgres psql` |
| `local` | the script runs on the VM itself, or the VM is not reachable | the local `psql` client over the socket in `/var/run/postgresql`, as `postgres` |

The mode is chosen automatically, so the same command works on the
workstation and on the database host:

```bash
# on the workstation -> talks to the VM over SSH
./scripts/pg_sta_ctl --database appdb report

# on the database host -> uses the local psql client
./scripts/pg_sta_ctl --database appdb report
```

`--ssh` and `--local` force one of the two, and `PG_STA_MODE=ssh|local`
does the same for the helper scripts. When the fallback to the local client
happens, the scripts say so once:

```
pg_sta: no SSH access to 127.0.0.1:2201; using the local psql client
```

Two operations need privileges that the `postgres` user does not have:

* `make install` writes into the PostgreSQL tree, so it needs **root**.
  Run it as `root`, or as a user with passwordless sudo (on the
  development VM that is `vagrant`); the script says so and stops
  otherwise.
* `/var/lib/pgsql` is readable by `postgres` only, so a refresh of the
  tree under that path has to run through `sudo`.

### 3.5 Environment variables

Every script accepts these overrides:

| Variable | Default |
|---|---|
| `PG_STA_MODE` | `auto` (`ssh` or `local`, detected) |
| `PG_STA_HOST` | `127.0.0.1` |
| `PG_STA_SSH_PORT` | `2201` |
| `PG_STA_SSH_KEY` | `$HOME/.vagrant.d/insecure_private_key` |
| `PG_STA_REMOTE` | `/home/vagrant/pg_sta` |
| `PG_STA_PG_CONFIG` | `/usr/pgsql-17/bin/pg_config` |
| `PG_STA_PGDATABASE` | `pg_sta_qa` (the client) / `postgres` (the build scripts) |
| `PG_STA_TESTDB` | `pg_sta_regress` |
| `PG_STA_SRC` | the directory containing `scripts/` |

---

## 4. Building

```bash
./scripts/build.sh                    # compile only
./scripts/build.sh install            # compile and install
```

Or directly on the VM:

```bash
ssh -i ~/.vagrant.d/insecure_private_key -p 2201 vagrant@127.0.0.1
cd /home/vagrant/pg_sta
make PG_CONFIG=/usr/pgsql-17/bin/pg_config
sudo make PG_CONFIG=/usr/pgsql-17/bin/pg_config install
```

The PostgreSQL 17 installation on the guest is the PGDG build in
`/usr/pgsql-17`, so `pg_config` is at `/usr/pgsql-17/bin/pg_config` and
not on the default `PATH`. Every script passes it explicitly.

---

## 5. The regression suite

```bash
./scripts/installcheck.sh
```

`pg_regress` writes its results next to the input files, so the tree it
runs in must be writable by the database user. The synced tree is owned by
`vagrant`, so `installcheck.sh` runs the suite from a throw-away copy at
`/tmp/pg_sta_installcheck` owned by `postgres`. **The working tree is never
modified by the run.**

The results and the diff file are copied back to the host so a failure can
be inspected:

```
expected/pg_sta.out.actual    the output of the run
regression.diffs              the difference against expected/pg_sta.out
```

### Recording a new expected output

When a change is intentional and the new output is correct:

```bash
./scripts/installcheck.sh --record
```

This replaces `expected/pg_sta.out` with the output of the run. **Read the
diff before you record it** — recording hides a regression as easily as it
accepts an improvement.

---

## 6. The QA suite

```bash
./test/run_qa.sh
```

The QA suite:

1. creates the fixture `sta_qa` with deliberate defects,
2. evaluates 247 assertions in `test/qa_assertions.sql`,
3. prints a pass/fail line per assertion and a summary.

```
--------------------------------------------------------
total=247 passed=247 failed=0
==> QA PASSED
```

### 6.1 The phase structure

`test/qa_setup.sql` is split into phases with `-- @phase N` markers. The
runner splits the file locally with `awk` and runs **each phase in its own
`psql` session**.

This is not cosmetic — it is required for correctness. In PostgreSQL 17
the per-backend statistics entry is flushed into shared memory only when
the backend goes idle or the session ends, and the flush *adds deltas*.
If the fixture's DML and its `ANALYZE` share one session, the later flush
overwrites the `ANALYZE`'s absolute values, and the fixture silently stops
containing the defects it is supposed to contain. Splitting the phases
makes the statistics deterministic.

The header of `test/qa_setup.sql` explains this in full.

### 6.2 The assertion format

`test/qa_assertions.sql` holds one assertion per line:

```
assertion | expected | actual | passed
```

The values are pipe-delimited, so **a `|` must never appear inside an
expected or actual value** — it would shift the columns and break the
runner's parser.

### 6.3 What the fixture contains

| Object | Deliberate defect |
|---|---|
| `sta_qa.unanalysed` | 5 000 rows, never analyzed, no index, no primary key |
| `sta_qa.stale_stats` | 8 000 live rows, 12 000 dead rows, changed since the last analyze |
| `sta_qa.big_events` | 120 000 rows, a hot query with no supporting index |
| `sta_qa.hot_path` | 200 rows, executed very often |
| `sta_qa.lookup` | 200 rows, a selective predicate |
| `sta_qa.pa_fact`, `sta_qa.pa_dim1`, `sta_qa.pa_dim2` | the fact/dimension tables the plan-advice assertions plan against |

---

## 7. Safety rules for this environment

The host has several Vagrant environments and several database clusters.
The rules that keep them safe:

| Rule | Why |
|---|---|
| Never run `vagrant destroy` | It deletes the VM and its database. |
| Never delete a PostgreSQL data directory | It is the database. |
| Never reset an existing cluster | The user's `appdb` is not a test target. |
| Never change a production setting | `shared_buffers`, `work_mem` and friends affect the user's workload. |
| Never change a setting without recording it | Every change needs a documented rollback. |
| Use a dedicated database and isolated objects | The QA and regression suites use `pg_sta_qa` and `pg_sta_regress`. |
| Prefer reversible changes | `CREATE INDEX CONCURRENTLY`, session-level `SET`, and dropping what you created. |
| Never log credentials | The scripts use the `postgres` superuser over SSH with a key; no password appears in any log. |
| Never disable a security control to make a test pass | A test that needs a relaxed control is a bad test. |

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make: pg_config: command not found` | the PGDG install is not on `PATH` | use `/usr/pgsql-17/bin/pg_config` explicitly |
| `could not access file "$libdir/pg_sta"` | the `.so` is not installed | `./scripts/build.sh install` |
| `extension "pg_sta" already exists` | `reload.sh` was interrupted | `DROP EXTENSION IF EXISTS pg_sta CASCADE;` then `CREATE EXTENSION pg_sta;` |
| The regression suite cannot write `results/` | the tree is owned by `vagrant` | use `./scripts/installcheck.sh`, which copies to `/tmp` first |
| The QA suite reports unexpected counts | the fixture was not re-seeded, or a phase shared a session | re-run `./test/run_qa.sh` from the top |
| `pg_stat_statements` has no rows | the extension is not loaded | check `SHOW shared_preload_libraries;` |
| The SSH connection is refused | the VM is not running | `cd /Users/jey/postgres17 && vagrant up pgnode17` |
| `ssh: connect to host 127.0.0.1 port 2201: Connection refused` together with `Identity file ... not accessible` | the script runs **on the VM**, where the port forward does not exist and the workstation key is not present | the scripts fall back to the local `psql` client automatically and say so; force it with `--local` or `PG_STA_MODE=local` |

---

## 9. Adding a new finding

1. Add the rule to the relevant advice function in `sql/pg_sta--0.1.7.sql`.
2. Add the row to the `sta.advice_catalog` table in the same file — the
   severity of a finding should come from the catalogue, not from a
   literal in the function body.
3. Add the validation kind to `sta.validation_steps()` if it is new.
4. Add a threshold to `sta.threshold` if the rule needs one.
5. Add a fixture that triggers the finding to `test/qa_setup.sql`.
6. Add an assertion to `test/qa_assertions.sql`.
7. Re-run the QA suite and the regression suite.
8. Update `docs/advice-catalog.md`.

Step 6 matters most: a finding with no assertion is a finding nobody has
verified.
