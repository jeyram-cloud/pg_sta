# pg_sta -- PostgreSQL SQL Tuning Advisor
#
# Build:   make PG_CONFIG=/usr/pgsql-17/bin/pg_config
# Install: make install PG_CONFIG=/usr/pgsql-17/bin/pg_config
# Test:    make installcheck PG_CONFIG=/usr/pgsql-17/bin/pg_config

EXTENSION   = pg_sta
MODULE_big  = pg_sta
OBJS        = src/pg_sta.o
DATA        = sql/pg_sta--0.1.0.sql
REGRESS     = pg_sta

PG_CONFIG  ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Convenience: build against a specific PostgreSQL installation.
PGSTA_PG_CONFIG ?= /usr/pgsql-17/bin/pg_config

# The regression suite creates its own schema and drops it again, so it is
# safe to run against a scratch database.  It never touches anything outside
# the schema it creates.
REGRESS_OPTS ?= --dbname=pg_sta_regress

# Extra developer conveniences -------------------------------------------
.PHONY: qa
qa:
	./test/run_qa.sh

.PHONY: check
check: installcheck
