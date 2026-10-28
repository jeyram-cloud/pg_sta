# pg_sta -- PostgreSQL SQL Tuning Advisor
#
# Run every make command from the directory that holds this Makefile (the
# pg_sta source tree).  "No targets specified and no makefile found" means
# the current directory is not the source tree.
#
# Build:   make PG_CONFIG=/usr/pgsql-17/bin/pg_config
# Install: make install PG_CONFIG=/usr/pgsql-17/bin/pg_config
# Test:    make installcheck PG_CONFIG=/usr/pgsql-17/bin/pg_config

EXTENSION   = pg_sta
MODULE_big  = pg_sta
OBJS        = src/pg_sta.o
EXTVERSION  = 0.1.7
DATA        = sql/pg_sta--$(EXTVERSION).sql \
           sql/pg_sta--0.1.0--$(EXTVERSION).sql \
           sql/pg_sta--0.1.1--$(EXTVERSION).sql \
           sql/pg_sta--0.1.2--$(EXTVERSION).sql \
           sql/pg_sta--0.1.3--$(EXTVERSION).sql \
           sql/pg_sta--0.1.4--$(EXTVERSION).sql \
           sql/pg_sta--0.1.5--$(EXTVERSION).sql \
           sql/pg_sta--0.1.6--$(EXTVERSION).sql \
           sql/pg_sta--$(EXTVERSION)--0.1.6.sql \
           sql/pg_sta--0.1.0--0.1.1.sql
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
.PHONY: upgrade-script
upgrade-script:
	python3 scripts/gen_upgrade.py 0.1.0 $(EXTVERSION)
	python3 scripts/gen_upgrade.py 0.1.1 $(EXTVERSION)
	python3 scripts/gen_upgrade.py 0.1.2 $(EXTVERSION)
	python3 scripts/gen_upgrade.py 0.1.3 $(EXTVERSION)
	python3 scripts/gen_upgrade.py 0.1.4 $(EXTVERSION)
	python3 scripts/gen_upgrade.py 0.1.5 $(EXTVERSION)
	python3 scripts/gen_upgrade.py 0.1.6 $(EXTVERSION)
	python3 scripts/gen_upgrade.py --downgrade $(EXTVERSION) 0.1.6

.PHONY: lint
lint:
	python3 scripts/lint_sql.py sql/pg_sta--$(EXTVERSION).sql \
	        sql/pg_sta--0.1.0--$(EXTVERSION).sql \
	        sql/pg_sta--0.1.1--$(EXTVERSION).sql \
	        sql/pg_sta--0.1.2--$(EXTVERSION).sql \
	        sql/pg_sta--0.1.3--$(EXTVERSION).sql \
	        sql/pg_sta--0.1.4--$(EXTVERSION).sql \
	        sql/pg_sta--0.1.5--$(EXTVERSION).sql \
	        sql/pg_sta--0.1.6--$(EXTVERSION).sql \
	        sql/pg_sta--$(EXTVERSION)--0.1.6.sql

.PHONY: qa
qa:
	./test/run_qa.sh

.PHONY: check
check: installcheck
