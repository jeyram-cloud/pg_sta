/*-------------------------------------------------------------------------
 * pg_sta.c
 *		PostgreSQL SQL Tuning Advisor -- C extension core.
 *
 * The C layer exists for exactly three reasons:
 *
 *   1. Canonical query identification.  PostgreSQL >= 14 computes a
 *      canonical query id ("jumble") for every parsed statement.  The id
 *      lives in Query->queryId and is what pg_stat_statements stores.
 *      Re-implementing it in SQL is not possible, so pg_sta asks the
 *      server itself: it parses the statement with the very same parser
 *      and analyzer the executor uses and returns the id the server
 *      would have assigned.  This makes sta.queryid() automatically
 *      identical to pg_stat_statements.queryid, on this release and on
 *      later releases that keep the same jumbling algorithm.
 *
 *   2. Normalised statement text.  pg_stat_statements displays constants
 *      replaced by $n.  pg_sta reproduces that rendering exactly (the
 *      algorithm below is adapted from contrib/pg_stat_statements) so a
 *      statement can be matched against pg_stat_statements rows by text
 *      as well as by id.
 *
 *   3. Safe EXPLAIN capture.  EXPLAIN (FORMAT JSON) is executed through
 *      SPI on a parsed, validated single statement, so a multi-statement
 *      string can never be smuggled through the advisor, and
 *      EXPLAIN ANALYZE is refused for anything that is not a plain
 *      SELECT.
 *
 * Portions Copyright (c) 2026, the pg_sta contributors
 * Portions Copyright (c) 1996-2024, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * The query-normalisation routines are adapted from
 * contrib/pg_stat_statements/pg_stat_statements.c and are used under the
 * PostgreSQL licence; see LICENSE.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>

#include "commands/dbcommands.h"
#include "commands/extension.h"
#include "common/keywords.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "nodes/queryjumble.h"
#include "parser/analyze.h"
#include "parser/scanner.h"
#include "parser/scansup.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/errcodes.h"
#include "utils/guc.h"
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(pg_sta_queryid);
PG_FUNCTION_INFO_V1(pg_sta_queryid_normalized);
PG_FUNCTION_INFO_V1(pg_sta_explain);
PG_FUNCTION_INFO_V1(pg_sta_server_info);

void		_PG_init(void);

/* GUCs ------------------------------------------------------------------ */
static bool pg_sta_enable_analyze = true;
static int	pg_sta_max_findings = 200;
static char *pg_sta_advice_state = NULL;
static char *pg_sta_advice_stash = NULL;

/* ------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------ */

/*
 * A parsed, analysed, single SQL statement.
 */
typedef struct PgStaStmt
{
	char	   *sql;			/* palloc'd copy of the submitted text */
	List	   *raw_list;		/* result of pg_parse_query() */
	RawStmt    *raw;			/* the one and only statement */
	Query      *query;		/* parse-analyzed statement */
} PgStaStmt;

/*
 * Return the highest $n parameter placeholder used by the statement, or 0
 * when the statement has none.
 *
 * String literals, quoted identifiers, dollar quoted strings and comments
 * are skipped, so that a literal "$1" inside a string is not mistaken for a
 * parameter.
 */
static int
pg_sta_scan_params(const char *sql)
{
	int			max_param = 0;
	const char *p = sql;

	while (*p)
	{
		if (*p == '\'')
		{
			/* single quoted string; '' escapes a quote */
			p++;
			while (*p)
			{
				if (*p == '\'')
				{
					if (p[1] == '\'')
					{
						p += 2;
						continue;
					}
					p++;
					break;
				}
				p++;
			}
			continue;
		}
		if (*p == '"')
		{
			/* quoted identifier; "" escapes a quote */
			p++;
			while (*p)
			{
				if (*p == '"')
				{
					if (p[1] == '"')
					{
						p += 2;
						continue;
					}
					p++;
					break;
				}
				p++;
			}
			continue;
		}
		if (*p == '-' && p[1] == '-')
		{
			while (*p && *p != '\n')
				p++;
			continue;
		}
		if (*p == '/' && p[1] == '*')
		{
			int			depth = 1;

			p += 2;
			while (*p && depth > 0)
			{
				if (*p == '/' && p[1] == '*')
				{
					depth++;
					p += 2;
					continue;
				}
				if (*p == '*' && p[1] == '/')
				{
					depth--;
					p += 2;
					continue;
				}
				p++;
			}
			continue;
		}
		if (*p == '$')
		{
			const char *q = p + 1;

			/*
			 * A parameter placeholder is "$" followed by digits.  A dollar
			 * quoted string is "$" followed by an optional tag and another
			 * "$"; a tag can never start with a digit, so the two cases
			 * are unambiguous.
			 */
			if (isdigit((unsigned char) *q))
			{
				int			n = 0;

				while (isdigit((unsigned char) *q))
				{
					n = n * 10 + (*q - '0');
					q++;
				}
				if (n > max_param)
					max_param = n;
				p = q;
				continue;
			}

			while (*q && (isalnum((unsigned char) *q) || *q == '_'))
				q++;

			if (*q == '$')
			{
				/* dollar quoted string: $tag$ ... $tag$ */
				const char *tag = p + 1;
				size_t		taglen = (size_t) (q - tag);

				p = q + 1;
				while (*p)
				{
					if (*p == '$' && strncmp(p, tag, taglen) == 0 &&
						p[taglen] == '$')
					{
						p += taglen + 1;
						break;
					}
					p++;
				}
				continue;
			}

			p++;
			continue;
		}
		p++;
	}

	return max_param;
}

/*
 * Parse and analyse exactly one statement.
 *
 * Anything other than a single statement is rejected: an advisor that
 * silently accepted "SELECT 1; DROP TABLE t" would be a liability.
 */
static PgStaStmt *
pg_sta_parse_one(const char *sql, const char *caller)
{
	PgStaStmt *stmt = (PgStaStmt *) palloc0(sizeof(PgStaStmt));

	stmt->sql = pstrdup(sql);
	stmt->raw_list = pg_parse_query(stmt->sql);

	if (stmt->raw_list == NIL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("%s: no SQL statement found", caller),
				 errhint("Provide a single, non-empty SQL statement.")));

	if (list_length(stmt->raw_list) != 1)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("%s: exactly one SQL statement is allowed", caller),
				 errhint("Split the text into separate calls.")));

	stmt->raw = (RawStmt *) linitial(stmt->raw_list);

	/*
	 * A statement that uses $n placeholders needs the variable-parameter
	 * parser, which infers the type of every parameter from its context.
	 * Everything else goes through the fixed-parameter parser, which is
	 * what pg_stat_statements effectively sees.
	 */
	if (pg_sta_scan_params(stmt->sql) > 0)
	{
		Oid		   *paramTypes = NULL;
		int			numParams = 0;

		stmt->query = parse_analyze_varparams(stmt->raw, stmt->sql,
											  &paramTypes, &numParams, NULL);
	}
	else
		stmt->query = parse_analyze_fixedparams(stmt->raw, stmt->sql, NULL, 0, NULL);

	return stmt;
}

/*
 * Return the text of the statement itself, trimmed and with any trailing
 * semicolon removed, so that it can safely be embedded in a generated
 * command (EXPLAIN ...).
 *
 * The length of the last statement in a source string is not recorded by
 * the parser (RawStmt.stmt_len is 0 for it), which is why CleanQuerytext()
 * is used: it treats a length of 0 as "rest of the string", exactly like
 * pg_stat_statements does.
 */
static char *
pg_sta_statement_text(PgStaStmt *stmt)
{
	int			location = stmt->raw->stmt_location;
	int			len = stmt->raw->stmt_len;
	const char *query = CleanQuerytext(stmt->sql, &location, &len);
	char	   *result = pnstrdup(query, len);

	while (len > 0 && scanner_isspace(result[len - 1]))
		len--;
	if (len > 0 && result[len - 1] == ';')
		len--;
	result[len] = '\0';

	return result;
}

/*
 * Human readable command type name.  The backend's queryTypeName() is not
 * exported to extensions, so provide our own.
 */
static const char *
pg_sta_command_type_name(CmdType type)
{
	switch (type)
	{
		case CMD_SELECT:
			return "SELECT";
		case CMD_UPDATE:
			return "UPDATE";
		case CMD_INSERT:
			return "INSERT";
		case CMD_DELETE:
			return "DELETE";
		case CMD_MERGE:
			return "MERGE";
		case CMD_UTILITY:
			return "UTILITY";
		case CMD_NOTHING:
			return "NOTHING";
		case CMD_UNKNOWN:
			break;
	}
	return "UNKNOWN";
}

/*
 * Reject anything that is not a SELECT.
 *
 * EXPLAIN itself also accepts DML, but an advisor has no business pointing
 * the planner at a statement that writes.  Restricting the input to SELECT
 * keeps pg_sta read-only by construction and turns a cryptic parser error
 * into an actionable message.
 */
static void
pg_sta_check_select_only(const PgStaStmt *stmt, const char *caller)
{
	if (stmt->query->commandType != CMD_SELECT)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("%s: only SELECT statements are supported", caller),
				 errdetail("Statement command type is \"%s\".",
						   pg_sta_command_type_name(stmt->query->commandType)),
				 errhint("Rewrite the statement as a SELECT, or run EXPLAIN yourself.")));
}

/*
 * Reject EXPLAIN ANALYZE for anything that is not a read-only SELECT.
 */
static void
pg_sta_check_analyzable(const PgStaStmt *stmt, const char *caller)
{
	if (!pg_sta_enable_analyze)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("%s: EXPLAIN ANALYZE is disabled", caller),
				 errhint("Set pg_sta.enable_analyze = true to allow it.")));

	if (stmt->query->commandType != CMD_SELECT)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("%s: EXPLAIN ANALYZE is only supported for SELECT statements", caller),
				 errdetail("Statement command type is \"%s\".",
						   pg_sta_command_type_name(stmt->query->commandType)),
				 errhint("Use the non-analyzing variant to inspect the plan of this statement.")));
}

/* ------------------------------------------------------------------------
 * Normalised query text (adapted from contrib/pg_stat_statements)
 * ------------------------------------------------------------------------ */

static int
pg_sta_comp_location(const void *a, const void *b)
{
	const LocationLen *la = (const LocationLen *) a;
	const LocationLen *lb = (const LocationLen *) b;

	return (la->location > lb->location) - (la->location < lb->location);
}

/*
 * The core jumbling machinery reports the *location* of every constant but
 * not its length.  Re-scan the source text with the core scanner to work
 * out where each constant token ends.
 */
static void
pg_sta_fill_in_constant_lengths(JumbleState *jstate, const char *query,
								 int query_loc)
{
	LocationLen *locs;
	core_yyscan_t yyscanner;
	core_yy_extra_type yyextra;
	core_YYSTYPE yylval;
	YYLTYPE		yylloc;
	int			last_loc = -1;
	int			i;

	if (jstate->clocations_count > 1)
		qsort(jstate->clocations, jstate->clocations_count,
			  sizeof(LocationLen), pg_sta_comp_location);
	locs = jstate->clocations;

	yyscanner = scanner_init(query, &yyextra, &ScanKeywords, ScanKeywordTokens);

	/* we do not want to re-emit any escape string warnings */
	yyextra.escape_string_warning = false;

	for (i = 0; i < jstate->clocations_count; i++)
	{
		int			loc = locs[i].location - query_loc;
		int			tok;

		if (loc < 0 || loc >= (int) strlen(query))
			break;				/* location outside the statement */

		if (loc <= last_loc)
			continue;			/* duplicate constant, ignore */

		for (;;)
		{
			tok = core_yylex(&yylval, &yylloc, yyscanner);

			if (tok == 0)
				break;			/* out of inner for-loop */

			if (yylloc >= loc)
			{
				if (query[loc] == '-')
				{
					/*
					 * A negative constant: the location points at the
					 * leading '-' operator, and we deliberately start from
					 * the minus sign so that "= 1" and "= -2" normalise
					 * identically.
					 */
					tok = core_yylex(&yylval, &yylloc, yyscanner);
					if (tok == 0)
						break;	/* out of inner for-loop */
				}

				locs[i].length = strlen(yyextra.scanbuf + loc);
				break;			/* out of inner for-loop */
			}
		}

		if (tok == 0)
			break;				/* hit end of string, give up */

		last_loc = loc;
	}

	scanner_finish(yyscanner);
}

/*
 * Build the normalised rendering of the statement: every constant is
 * replaced by "$n", exactly like pg_stat_statements displays it.
 */
static char *
pg_sta_generate_normalized_query(JumbleState *jstate, const char *query,
								 int query_loc, int *query_len_p)
{
	char	   *norm_query;
	int			query_len = *query_len_p;
	int			i;
	int			norm_query_buflen;
	int			len_to_wrt;
	int			quer_loc = 0;	/* source query byte location */
	int			n_quer_loc = 0;	/* normalized query byte location */
	int			last_off = 0;	/* offset of previous token */
	int			last_tok_len = 0;	/* length of previous token */
	int			num_constants_replaced = 0;

	pg_sta_fill_in_constant_lengths(jstate, query, query_loc);

	/*
	 * "$n" can be longer than the constant it replaces; 10 bytes per
	 * constant is always enough ("$" + 9 digits).
	 */
	norm_query_buflen = query_len + jstate->clocations_count * 10;
	norm_query = (char *) palloc(norm_query_buflen + 1);

	for (i = 0; i < jstate->clocations_count; i++)
	{
		int			off;
		int			tok_len;

		off = jstate->clocations[i].location - query_loc;
		tok_len = jstate->clocations[i].length;

		if (tok_len < 0)
			continue;			/* ignore duplicates */

		if (off < 0 || off > query_len || tok_len > query_len - off)
			continue;			/* location outside the statement */

		/* copy the chunk that precedes this constant */
		len_to_wrt = off - last_off - last_tok_len;
		if (len_to_wrt < 0)
			len_to_wrt = 0;
		memcpy(norm_query + n_quer_loc, query + quer_loc, len_to_wrt);
		n_quer_loc += len_to_wrt;

		/* and substitute the parameter symbol */
		n_quer_loc += snprintf(norm_query + n_quer_loc,
							   norm_query_buflen + 1 - n_quer_loc,
							   "$%d",
							   num_constants_replaced + 1 + jstate->highest_extern_param_id);
		num_constants_replaced++;

		quer_loc = off + tok_len;
		last_off = off;
		last_tok_len = tok_len;
	}

	/* copy whatever remains after the last constant */
	len_to_wrt = query_len - quer_loc;
	if (len_to_wrt < 0)
		len_to_wrt = 0;
	memcpy(norm_query + n_quer_loc, query + quer_loc, len_to_wrt);
	n_quer_loc += len_to_wrt;

	norm_query[n_quer_loc] = '\0';
	*query_len_p = n_quer_loc;

	return norm_query;
}

/* ------------------------------------------------------------------------
 * SQL-callable functions
 * ------------------------------------------------------------------------
 */

/*
 * sta.queryid(sql text) -> bigint
 *
 * The canonical query id the server assigns to the statement.
 */
Datum
pg_sta_queryid(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	char	   *sql = text_to_cstring(sql_text);
	PgStaStmt *stmt;
	uint64		query_id;

	if (!IsQueryIdEnabled())
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("sta.queryid: query identifier computation is disabled"),
				 errhint("Set compute_query_id to 'on' or 'auto'.")));

	stmt = pg_sta_parse_one(sql, "sta.queryid");
	query_id = stmt->query->queryId;

	PG_RETURN_INT64((int64) query_id);
}

/*
 * sta.queryid_normalized(sql text) -> text
 *
 * The statement text with every constant replaced by "$n", matching the
 * rendering used by pg_stat_statements.
 */
Datum
pg_sta_queryid_normalized(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	char	   *sql = text_to_cstring(sql_text);
	PgStaStmt *stmt;
	JumbleState *jstate;
	char	   *normalized;
	const char *query;
	int			query_location;
	int			query_len;

	if (!IsQueryIdEnabled())
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("sta.queryid_normalized: query identifier computation is disabled"),
				 errhint("Set compute_query_id to 'on' or 'auto'.")));

	stmt = pg_sta_parse_one(sql, "sta.queryid_normalized");

	jstate = JumbleQuery(stmt->query);

	/*
	 * Confine ourselves to the text of the statement and determine its
	 * length, exactly the way pg_stat_statements does.  This matters: the
	 * parser does not record the length of the *last* statement of a
	 * source string, and using that (zero) length would under-allocate
	 * the output buffer.
	 */
	query_location = stmt->raw->stmt_location;
	query_len = stmt->raw->stmt_len;
	query = CleanQuerytext(stmt->sql, &query_location, &query_len);

	normalized = pg_sta_generate_normalized_query(jstate, query,
												   query_location, &query_len);

	PG_RETURN_TEXT_P(cstring_to_text(normalized));
}

/*
 * sta.explain(sql text, analyze boolean DEFAULT false) -> jsonb
 *
 * Run EXPLAIN (FORMAT JSON) on a single statement and return the plan.
 *
 * Statements that use $n placeholders -- the normalised form stored in
 * pg_stat_statements -- cannot be planned directly, because the parser has
 * no parameter values to work with.  Such statements are planned through a
 * throw-away prepared statement with plan_cache_mode = force_generic_plan,
 * which yields exactly the generic plan PostgreSQL would use for repeated
 * executions of the statement.
 */
Datum
pg_sta_explain(PG_FUNCTION_ARGS)
{
	text	   *sql_text = PG_GETARG_TEXT_PP(0);
	bool		analyze = PG_GETARG_BOOL(1);
	char	   *sql = text_to_cstring(sql_text);
	PgStaStmt *stmt;
	StringInfoData cmd;
	StringInfoData result;
	int			ret;
	int			spi_status;
	bool		connected = false;
	bool		prepared = false;
	char	   *plan_text = NULL;
	char	   *stmt_text;
	char	   *old_mode = NULL;
	int			nparams;
	int			i;
	MemoryContext outer_cxt = CurrentMemoryContext;

	stmt = pg_sta_parse_one(sql, "sta.explain");

	pg_sta_check_select_only(stmt, "sta.explain");

	if (analyze)
		pg_sta_check_analyzable(stmt, "sta.explain");

	stmt_text = pg_sta_statement_text(stmt);
	nparams = pg_sta_scan_params(stmt->sql);

	if (nparams > 0 && analyze)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("sta.explain: EXPLAIN ANALYZE is not supported for a parameterized statement"),
				 errhint("Parameters are unknown, so the measured execution would not reflect real data."),
				 errdetail("Call sta.explain(sql, false) to obtain the generic plan instead.")));

	initStringInfo(&cmd);

	PG_TRY();
	{
		spi_status = SPI_connect();
		if (spi_status != SPI_OK_CONNECT)
			elog(ERROR, "SPI_connect failed: %d", spi_status);
		connected = true;

		if (nparams > 0)
		{
			/*
			 * Step 1: prepare the statement so that PostgreSQL infers the
			 * type of every parameter from its context.
			 */
			resetStringInfo(&cmd);
			appendStringInfoString(&cmd, "PREPARE pg_sta_tmp AS ");
			appendStringInfoString(&cmd, stmt_text);

			ret = SPI_execute(cmd.data, false, 0);
			if (ret != SPI_OK_UTILITY && ret != SPI_OK_SELECT)
				elog(ERROR, "sta.explain: could not prepare statement (SPI code %d)", ret);
			prepared = true;

			/*
			 * Step 2: remember the current plan_cache_mode and force the
			 * generic plan.  Without this the planner would build a
			 * custom plan for the NULL values we bind below.
			 */
			resetStringInfo(&cmd);
			appendStringInfoString(&cmd, "SELECT current_setting('plan_cache_mode')");
			ret = SPI_execute(cmd.data, false, 0);
			if (ret == SPI_OK_SELECT && SPI_processed == 1 && SPI_tuptable != NULL)
				old_mode = MemoryContextStrdup(outer_cxt,
											   SPI_getvalue(SPI_tuptable->vals[0],
															SPI_tuptable->tupdesc, 1));

			resetStringInfo(&cmd);
			appendStringInfoString(&cmd, "SELECT set_config('plan_cache_mode', 'force_generic_plan', true)");
			ret = SPI_execute(cmd.data, false, 0);
			if (ret != SPI_OK_SELECT)
				elog(ERROR, "sta.explain: could not set plan_cache_mode (SPI code %d)", ret);

			/*
			 * Step 3: explain the generic plan.  The parameter values are
			 * irrelevant for a generic plan, but they still have to be
			 * supplied.
			 */
			resetStringInfo(&cmd);
			appendStringInfoString(&cmd, "EXPLAIN (FORMAT JSON, VERBOSE, SETTINGS) EXECUTE pg_sta_tmp(");
			for (i = 1; i <= nparams; i++)
			{
				if (i > 1)
					appendStringInfoString(&cmd, ", ");
				appendStringInfoString(&cmd, "NULL");
			}
			appendStringInfoString(&cmd, ")");
		}
		else
		{
			resetStringInfo(&cmd);
			appendStringInfoString(&cmd, "EXPLAIN (FORMAT JSON, VERBOSE, SETTINGS");
			if (analyze)
				appendStringInfoString(&cmd, ", ANALYZE, TIMING, BUFFERS");
			appendStringInfoString(&cmd, ") ");
			appendStringInfoString(&cmd, stmt_text);
		}

		/*
		 * read_only must be false: PostgreSQL classifies EXPLAIN as a
		 * non-read-only command, so SPI would refuse it otherwise.
		 */
		ret = SPI_execute(cmd.data, false, 0);
		if (ret != SPI_OK_SELECT && ret != SPI_OK_UTILITY)
			elog(ERROR, "sta.explain: EXPLAIN did not return a plan (SPI code %d)", ret);

		if (SPI_processed != 1 || SPI_tuptable == NULL)
			elog(ERROR, "sta.explain: EXPLAIN returned no plan");

		plan_text = SPI_getvalue(SPI_tuptable->vals[0],
								 SPI_tuptable->tupdesc, 1);
		if (plan_text == NULL)
			elog(ERROR, "sta.explain: EXPLAIN returned a NULL plan");

		/*
		 * Copy the plan out of the SPI memory context: SPI_finish() deletes
		 * procCxt, so anything allocated there (including a plain pstrdup)
		 * would be dangling by the time we build the result.
		 */
		plan_text = MemoryContextStrdup(outer_cxt, plan_text);

		/*
		 * Step 4: clean up -- restore plan_cache_mode and drop the
		 * throw-away prepared statement.
		 */
		if (prepared)
		{
			resetStringInfo(&cmd);
			appendStringInfoString(&cmd, "DEALLOCATE pg_sta_tmp");
			SPI_execute(cmd.data, false, 0);

			if (old_mode != NULL)
			{
				resetStringInfo(&cmd);
				appendStringInfoString(&cmd, "SELECT set_config('plan_cache_mode', ");
				appendStringInfoString(&cmd, quote_literal_cstr(old_mode));
				appendStringInfoString(&cmd, ", true)");
				SPI_execute(cmd.data, true, 0);
			}
		}
	}
	PG_CATCH();
	{
		if (connected)
		{
			if (prepared)
				SPI_execute("DEALLOCATE pg_sta_tmp", false, 0);
			SPI_finish();
		}
		PG_RE_THROW();
	}
	PG_END_TRY();

	SPI_finish();

	initStringInfo(&result);
	appendStringInfoString(&result, plan_text);

	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(result.data)));
}

/*
 * sta.server_info() -> jsonb
 *
 * Capability/introspection report used by the CLI and the QA suite.
 */
Datum
pg_sta_server_info(PG_FUNCTION_ARGS)
{
	StringInfoData out;
	bool		has_pgss = false;
	char	   *pgss_version = NULL;
	Oid			ext_oid = InvalidOid;
	const char *version_num_str;
	MemoryContext outer_cxt = CurrentMemoryContext;

	initStringInfo(&out);
	appendStringInfoChar(&out, '{');

	appendStringInfo(&out, "\"server_version\":");
	escape_json(&out, GetConfigOption("server_version", true, false));
	version_num_str = GetConfigOption("server_version_num", true, false);
	appendStringInfo(&out, ",\"server_version_num\":%s",
					 (version_num_str && *version_num_str) ? version_num_str : "0");
	appendStringInfo(&out, ",\"database\":");
	escape_json(&out, get_database_name(MyDatabaseId));
	appendStringInfo(&out, ",\"user\":");
	escape_json(&out, GetUserNameFromId(GetUserId(), false));
	appendStringInfo(&out, ",\"compute_query_id\":");
	escape_json(&out, GetConfigOption("compute_query_id", true, false));
	appendStringInfo(&out, ",\"query_id_enabled\":%s",
					 IsQueryIdEnabled() ? "true" : "false");
	appendStringInfo(&out, ",\"shared_preload_libraries\":");
	escape_json(&out, GetConfigOption("shared_preload_libraries", true, false));

	/* Is pg_stat_statements available? */
	ext_oid = get_extension_oid("pg_stat_statements", true);
	if (OidIsValid(ext_oid))
	{
		int			ret;

		has_pgss = true;

		if (SPI_connect() == SPI_OK_CONNECT)
		{
			ret = SPI_execute("SELECT extversion FROM pg_extension "
							  "WHERE extname = 'pg_stat_statements'",
							  true, 0);
			if (ret == SPI_OK_SELECT && SPI_processed == 1)
			{
				char	   *v = SPI_getvalue(SPI_tuptable->vals[0],
											SPI_tuptable->tupdesc, 1);

				if (v)
					pgss_version = MemoryContextStrdup(outer_cxt, v);
			}
			SPI_finish();
		}
	}
	appendStringInfo(&out, ",\"pg_stat_statements\":%s", has_pgss ? "true" : "false");
	if (pgss_version)
	{
		appendStringInfo(&out, ",\"pg_stat_statements_version\":");
		escape_json(&out, pgss_version);
	}

	appendStringInfo(&out, ",\"pg_sta\":{\"enable_analyze\":%s,\"max_findings\":%d}",
					 pg_sta_enable_analyze ? "true" : "false",
					 pg_sta_max_findings);

	appendStringInfo(&out, ",\"captured_at\":");
	escape_json(&out, timestamptz_to_str(GetCurrentTimestamp()));

	appendStringInfoChar(&out, '}');

	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(out.data)));
}

/* ------------------------------------------------------------------------
 * Module initialisation
 * ------------------------------------------------------------------------ */
void
_PG_init(void)
{
	DefineCustomBoolVariable("pg_sta.enable_analyze",
							   "Allow sta.explain() to execute EXPLAIN ANALYZE.",
							   "Only plain SELECT statements are accepted; anything else is refused.",
							   &pg_sta_enable_analyze,
							   true,
							   PGC_USERSET,
							   0,
							   NULL, NULL, NULL);

	DefineCustomIntVariable("pg_sta.max_findings",
							"Maximum number of advisory rows returned by a single pg_sta call.",
							NULL,
							&pg_sta_max_findings,
							200,
							1, 100000,
							PGC_USERSET,
							0,
							NULL, NULL, NULL);

	/*
	 * The planner settings that sta.apply_advice() changed, together with
	 * the values they had before.  It is a plain "name=value" list so that
	 * it can be moved in and out of a session with set_config() and so
	 * that sta.restore_advice() can put everything back exactly as it was.
	 */
	DefineCustomStringVariable("pg_sta.advice_state",
							   "Planner settings saved by sta.apply_advice().",
							   "Managed by sta.apply_advice() and sta.restore_advice(); do not edit by hand.",
							   &pg_sta_advice_state,
							   "",
							   PGC_USERSET,
							   0,
							   NULL, NULL, NULL);

	/*
	 * The advice stash that is currently in force.  Mirrors the
	 * pg_stash_advice.stash_name GUC of PostgreSQL 19: a stash is a named
	 * bag of (query id -> advice string) pairs.  When it is set, a query
	 * whose id is in the stash is planned with the stored advice applied.
	 */
	DefineCustomStringVariable("pg_sta.advice_stash",
							   "Name of the advice stash that is currently in force.",
							   "Set to the name of a stash created with sta.create_stash().",
							   &pg_sta_advice_stash,
							   "",
							   PGC_USERSET,
							   0,
							   NULL, NULL, NULL);

	/*
	 * Ask the backend to compute query ids even when compute_query_id is
	 * 'auto' and no other module has claimed the feature yet.  This is what
	 * pg_stat_statements does, and it is what makes sta.queryid()
	 * agree with pg_stat_statements.queryid.
	 */
	EnableQueryId();
}
