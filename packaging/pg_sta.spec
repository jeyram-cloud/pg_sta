%global progname pg_sta
%global pgversion 17

Name:           pg_sta
Version:        0.1.0
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

%prep
%setup -q

%build
make %{?_smp_mflags} PG_CONFIG=/usr/pgsql-%{pgversion}/bin/pg_config

%install
make install DESTDIR=%{buildroot} PG_CONFIG=/usr/pgsql-%{pgversion}/bin/pg_config

%files
%{_libdir}/pg_sta.so
%{_datadir}/pgsql/extension/pg_sta.control
%{_datadir}/pgsql/extension/pg_sta--0.1.0.sql
%license LICENSE
%doc README.md

%changelog
* Mon Oct 25 2026 Jey <jey@example.com> - 0.1.0-1
- Initial packaging of pg_sta 0.1.0 for PostgreSQL 17.
