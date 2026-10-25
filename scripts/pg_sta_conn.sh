#!/usr/bin/env bash
# pg_sta_conn.sh -- shared connection helpers for the pg_sta scripts.
#
# The pg_sta tree is used from two places:
#
#   * on the macOS workstation, which drives the AlmaLinux development VM
#     over SSH on the forwarded port 2201;
#   * on the development VM itself, where the psql client talks to the local
#     server over its unix socket.
#
# The scripts must work in both places without extra flags, so this file
# resolves the transport once and exposes the helpers that the other
# scripts use.  Source it, do not execute it.
#
#   pg_sta_resolve_mode          resolve PG_STA_MODE to "ssh" or "local"
#   pg_sta_ssh CMD               run a shell command string on the target
#   pg_sta_push SRC DST          copy a file or tree to the target
#   pg_sta_pull SRC DST          copy a file or tree back from the target
#   pg_sta_psql DB FLAGS         run psql against a database (stdin forwarded)
#   pg_sta_note MSG              write an informational message to stderr
#
# Environment:
#   PG_STA_MODE        auto (default) | ssh | local
#   PG_STA_HOST        host of the development VM          (127.0.0.1)
#   PG_STA_SSH_PORT    forwarded SSH port of the VM         (2201)
#   PG_STA_SSH_KEY     private key used for the SSH hop     ($HOME/.vagrant.d/insecure_private_key)
#   PG_STA_REMOTE      path of the source tree on the VM    (/home/vagrant/pg_sta)
#   PG_STA_PG_CONFIG   pg_config used by the build          (/usr/pgsql-17/bin/pg_config)
#   PG_STA_PGDATABASE  default database                     (postgres)

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------
PG_STA_HOST=${PG_STA_HOST:-127.0.0.1}
PG_STA_SSH_PORT=${PG_STA_SSH_PORT:-2201}
PG_STA_SSH_KEY=${PG_STA_SSH_KEY:-$HOME/.vagrant.d/insecure_private_key}
PG_STA_REMOTE=${PG_STA_REMOTE:-/home/vagrant/pg_sta}
PG_STA_PG_CONFIG=${PG_STA_PG_CONFIG:-/usr/pgsql-17/bin/pg_config}
PG_STA_PGDATABASE=${PG_STA_PGDATABASE:-postgres}
PG_STA_MODE=${PG_STA_MODE:-auto}

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------
pg_sta_note() { echo "pg_sta: $*" >&2; }

# The root of the source tree that contains this file.
pg_sta_root() {
    local here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    (cd "$here/.." && pwd)
}

# The tree that the scripts operate on.  In "local" mode the target machine
# is this machine, so the tree is the one the script was started from.
pg_sta_target_tree() {
    if [ "$PG_STA_MODE" = "local" ]; then
        pg_sta_root
    else
        printf '%s\n' "$PG_STA_REMOTE"
    fi
}

# --------------------------------------------------------------------------
# Transport resolution
# --------------------------------------------------------------------------
pg_sta_ssh_ready() {
    [ -n "$PG_STA_SSH_KEY" ] && [ -r "$PG_STA_SSH_KEY" ] || return 1
    (exec 3<>"/dev/tcp/$PG_STA_HOST/$PG_STA_SSH_PORT") 2>/dev/null || return 1
    return 0
}

# Resolve PG_STA_MODE into "ssh" or "local".  In "auto" mode the SSH hop is
# used when it is actually usable -- the key must be readable and the
# forwarded port must answer.  When the scripts run on the VM itself the
# forward does not exist, and the local psql client is used instead.
pg_sta_resolve_mode() {
    case "$PG_STA_MODE" in
        ssh|local)
            export PG_STA_MODE
            return 0
            ;;
    esac

    if pg_sta_ssh_ready; then
        PG_STA_MODE=ssh
    else
        PG_STA_MODE=local
        # The nested scripts (sync.sh, build.sh, ...) run in their own
        # processes, so the note is printed once per chain of scripts.
        if [ -z "${PG_STA_MODE_NOTED:-}" ]; then
            pg_sta_note "no SSH access to $PG_STA_HOST:$PG_STA_SSH_PORT; using the local psql client"
            export PG_STA_MODE_NOTED=1
        fi
    fi
    export PG_STA_MODE
    return 0
}

# --------------------------------------------------------------------------
# Running commands
# --------------------------------------------------------------------------

# Run a shell command string on the target machine.
pg_sta_ssh() {
    local cmd="$1"
    if [ "$PG_STA_MODE" = "ssh" ]; then
        ssh -i "$PG_STA_SSH_KEY" -p "$PG_STA_SSH_PORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 \
            "vagrant@$PG_STA_HOST" "$cmd"
    else
        bash -c "$cmd"
    fi
}

# Copy a file or tree to the target machine.
pg_sta_push() {
    local src="$1" dst="$2"
    if [ "$PG_STA_MODE" = "ssh" ]; then
        rsync -az \
            -e "ssh -i $PG_STA_SSH_KEY -p $PG_STA_SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
            "$src" "$dst"
    else
        cp -a "$src" "$dst"
    fi
}

# Copy a file or tree back from the target machine.
pg_sta_pull() {
    local src="$1" dst="$2"
    if [ "$PG_STA_MODE" = "ssh" ]; then
        scp -q -i "$PG_STA_SSH_KEY" -P "$PG_STA_SSH_PORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "vagrant@$PG_STA_HOST:$src" "$dst"
    else
        cp -a "$src" "$dst"
    fi
}

# Does a file exist on the target machine?
pg_sta_target_exists() {
    local path="$1"
    if [ "$PG_STA_MODE" = "ssh" ]; then
        ssh -i "$PG_STA_SSH_KEY" -p "$PG_STA_SSH_PORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR "vagrant@$PG_STA_HOST" \
            "test -f '$path'" 2>/dev/null
    else
        [ -f "$path" ]
    fi
}

# --------------------------------------------------------------------------
# psql
# --------------------------------------------------------------------------

# The psql client to use in "local" mode.  On AlmaLinux the PostgreSQL 17
# binaries live in /usr/pgsql-17/bin, which is not always on the PATH of a
# login shell, so the well known locations are searched as well.
pg_sta_psql_bin() {
    if command -v psql >/dev/null 2>&1; then
        command -v psql
        return 0
    fi
    local c
    for c in /usr/pgsql-*/bin/psql /usr/local/pgsql/bin/psql \
             /usr/lib/postgresql/*/bin/psql /opt/homebrew/opt/postgresql*/bin/psql; do
        if [ -x "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# The command prefix that runs a command as the database owner.  Over SSH the
# remote account is "vagrant", locally it may already be "postgres".
pg_sta_postgres_prefix() {
    if [ "$PG_STA_MODE" = "ssh" ] || [ "$(id -un)" != "postgres" ]; then
        printf '%s' "sudo -u postgres "
    else
        printf '%s' ""
    fi
}

# Run psql on this machine as the database owner.  The PG* variables are
# passed explicitly because sudo resets the environment.
pg_sta_local_psql() {
    local bin
    bin=$(pg_sta_psql_bin) || {
        pg_sta_note "no psql client found; install the PostgreSQL client or add it to the PATH"
        return 127
    }
    local envs=() v
    for v in PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSSLMODE PGCONNECT_TIMEOUT; do
        if [ -n "${!v:-}" ]; then
            envs+=("$v=${!v}")
        fi
    done
    if [ "$(id -un)" = "postgres" ]; then
        "$bin" "$@"
    else
        sudo -u postgres env ${envs[@]+"${envs[@]}"} "$bin" "$@"
    fi
}

# Run psql against a database on the target machine.  The SQL is read from
# stdin.  $1 = database, $2 = extra psql flags.
pg_sta_psql() {
    local db="$1" flags="$2"
    if [ "$PG_STA_MODE" = "ssh" ]; then
        ssh -i "$PG_STA_SSH_KEY" -p "$PG_STA_SSH_PORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 \
            "vagrant@$PG_STA_HOST" \
            "sudo -u postgres psql -X -v ON_ERROR_STOP=1 $flags -d '$db'"
    else
        # shellcheck disable=SC2086
        pg_sta_local_psql -X -v ON_ERROR_STOP=1 $flags -d "$db"
    fi
}
