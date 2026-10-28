%global progname pg_sta
%global pgversion 17

Name:           pg_sta
Version:        0.1.7
Release:        1%{?dist}
Summary:        PostgreSQL SQL Tuning Advisor

License:        PostgreSQL
URL:            https://github.com/jeyram-cloud/pg_sta
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  make
BuildRequires:  gcc
BuildRequires:  postgresql%{pgversion}-devel
Requires:       postgresql%{pgversion}-server
Requires:       postgresql%{pgversion}-contrib

%description
pg_sta is an open-source SQL Tuning Advisor for PostgreSQL 17, in the spirit
of Oracle's SQL Tuning Advisor.

It analyses the workload (from pg_stat_statements), the execution plans and
the table statistics of a database and returns ranked, explainable tuning
recommendations.  Every recommendation carries the evidence that produced
it, the expected benefit, the cost and the steps required to validate it.

The extension is read-only by design: it never applies a change to the
database.  The function sta.validate() measures a proposed index against
the current plan inside a subtransaction and rolls it back again.

The before/after functions show the plan of a statement before and after a
proposed change and report how much the change gains; the change is applied
in a subtransaction and rolled back, so the database is left unchanged.
sta.sql_id() and sta.sql_hash() give every statement the Oracle style
SQL_ID and SQL_HASH.

The extension also reproduces the plan-advice features that PostgreSQL 19
introduces: sta.plan_advice_string() generates PostgreSQL 19 style plan
advice from an execution plan, and the advice stash API (sta.create_stash,
sta.set_stashed_advice, sta.get_stash_contents and friends) mirrors
pg_stash_advice.  Applying advice changes only the session settings of
the caller and is always reversible with sta.restore_advice().

%prep
%setup -q

%build
make %{?_smp_mflags} PG_CONFIG=/usr/pgsql-%{pgversion}/bin/pg_config

%install
make install DESTDIR=%{buildroot} PG_CONFIG=/usr/pgsql-%{pgversion}/bin/pg_config

%files
%{_libdir}/pg_sta.so
%{_datadir}/pgsql/extension/pg_sta.control
%{_datadir}/pgsql/extension/pg_sta--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.0--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.1--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.2--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.3--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.4--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.5--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.6--0.1.7.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.7--0.1.6.sql
%{_datadir}/pgsql/extension/pg_sta--0.1.0--0.1.1.sql
%license LICENSE
%doc README.md
%doc docs/usage.md
%doc docs/advice-catalog.md
%doc docs/pg19-compatibility.md

%changelog
* Tue Oct 28 2026 Jey <jey@example.com> - 0.1.7-1
- The tuning report: sta.tuning_report() writes a statement out the way
  the Oracle SQL Tuning Advisor writes it, as the four files <sql_id>.txt,
  <sql_id>_indx.txt, <sql_id>_multiple_plan.txt and <sql_id>_sql_profile.txt.
  The client command "tuning-report" writes them to a directory.

* Sun Oct 27 2026 Jey <jey@example.com> - 0.1.6-1
- The index and the rewrite are measured together, and the row-by-row
  comparison of the two result sets is fixed.

* Sun Oct 27 2026 Jey <jey@example.com> - 0.1.5-1
- Every finding now carries the plan before the change, the plan after it
  and the benefit of the change, in percent.

* Sun Oct 26 2026 Jey <jey@example.com> - 0.1.4-1
- The plan before and after the change, for every statement of the
  workload: sta.before_after_report() measures every change the advisor
  recommends and returns the plan before, the plan after and the gain.
- The action script now carries the plan before and the plan after every
  step, with the measured benefit and a verdict.

* Sun Oct 25 2026 Jey <jey@example.com> - 0.1.3-1
- The plan before and after a change: sta.plan_before_after() measures the
  plan of a statement before and after an index, an ANALYZE or a rewritten
  statement, and sta.before_after_benefit() reports the benefit.
- Oracle style statement identifiers: sta.sql_id(), sta.sql_hash() and
  sta.queryid_info().

* Sun Oct 25 2026 Jey <jey@example.com> - 0.1.2-1
- Action plan and action script: runnable CREATE INDEX, ANALYZE, VACUUM
  and rewritten statements, in the order in which they should be applied.
- The advisor now sees the constants of a statement: the workload can
  register the text of its statements with sta.record().
- The rewritten statements are laid out one clause per line.

* Sun Oct 25 2026 Jey <jey@example.com> - 0.1.1-1
- Rewrite advice, index advice and workload-driven plan advice.

* Mon Oct 25 2026 Jey <jey@example.com> - 0.1.0-1
- Initial packaging of pg_sta 0.1.0 for PostgreSQL 17.
