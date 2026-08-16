package {{MODULE_PATH}};

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Turns the OData query options on a request URI into SQL, for a resource whose
 * rows come from somewhere Mendix cannot query itself.
 *
 * <p><b>Why this exists.</b> A published entity backed by a read microflow gets
 * handed the request and returns a list; Mendix applies none of {@code $filter},
 * {@code $orderby}, {@code $top}, {@code $skip} or the key lookup to it. Every
 * one of those is the microflow's job, and a microflow that does not do the job
 * does not fail — it answers the wrong question with a 200. So this parses the
 * request once and hands back everything needed to answer it properly.
 *
 * <p><b>The grammar is not a guess.</b> It is what Mendix's own OData client
 * emits, captured off the wire from a running app driving real datagrids (see
 * FINDINGS §45):
 *
 * <pre>
 *   name eq 'Ayrton Senna'          (raceWins gt 10) and (podiums gt 20)
 *   name ne 'Ayrton Senna'          (name eq 'a') or (name eq 'b')
 *   raceWins gt|ge|lt|le 40         contains(name,'Sen')
 *   points gt 100.5                 startswith(name,'Ayr') / endswith(name,'nna')
 *   nationality eq null             championshipWon eq true
 * </pre>
 *
 * Covering exactly that set is what makes a widget sitting on an external entity
 * work rather than half-work.
 *
 * <p><b>Two ways to use the result.</b> Callers that build their own statement
 * take {@link Result#filterSql} and {@link Result#orderBySql} and splice them
 * in. Callers whose SQL lives elsewhere — a view, a stored procedure, a query
 * defined on the database connection — take {@link Result#key},
 * {@link Result#top}, {@link Result#skip} and the sort terms and bind them.
 * Same parse, and the second kind is the reason this is not just a SQL builder:
 * you usually cannot rewrite someone else's warehouse SQL.
 *
 * <p><b>Injection.</b> Column names come from the client and are resolved
 * through a whitelist the caller supplies; nothing else reaches the SQL. A name
 * absent from the whitelist is a rejection, not an omission, because a dropped
 * filter silently returns more rows than were asked for. Literals are escaped,
 * and anything numeric must parse as a number.
 *
 * <p><b>No Mendix here.</b> This class is plain Java over strings so it can be
 * exercised without a runtime. {@link QueryObject} is the binding.
 */
public final class ODataQueryParser {

    private ODataQueryParser() {
    }

    // ---------------------------------------------------------------- types

    /** What a caller needs to answer the request, in both styles. */
    public static final class Result {
        /** " WHERE …", or "" when the client asked for everything. */
        public String filterSql = "";
        /** " ORDER BY … LIMIT n OFFSET m" for callers that splice. */
        public String orderBySql = "";
        /** The key a client is re-reading a held row by; "" for a collection. */
        public String key = "";
        public long top;
        public long skip;
        public boolean wantsCount;
        /** First two sort terms, as exposed names, for callers that bind. */
        public String sortColumn1 = "";
        public String sortDirection1 = "A";
        public String sortColumn2 = "";
        public String sortDirection2 = "A";
        /** True when the request asked for something untranslatable. */
        public boolean rejected;
        public String rejectReason = "";
    }

    /**
     * One whitelisted column: what the client calls it, the SQL behind it, and
     * its type.
     *
     * <p>The type is not decoration. Mendix quotes a literal according to what
     * the <em>widget</em> thinks the attribute is, which is not always what the
     * column is: a combo box bound to a numeric key sends {@code year eq '1957'}
     * while the grid header on the same column sends {@code year eq 1957}. A
     * comparison that pastes the quotes through gives DuckDB
     * {@code year = '1957'} against a BIGINT, which is zero rows and a 200.
     * FINDINGS §42.
     */
    private static final class Column {
        static final String TEXT = "text";
        static final String NUMBER = "number";
        static final String BOOL = "bool";
        static final String DATE = "date";

        final String sql;
        final String type;

        Column(String sql, String type) {
            this.sql = sql;
            this.type = type;
        }
    }

    // ------------------------------------------------------------- entry point

    /**
     * @param uri            the request URI, query string and all
     * @param columnMap      whitelist, {@code exposed:sqlExpression:type,…}; the
     *                       type may be omitted and defaults to text
     * @param dialect        postgresql | duckdb | sqlserver | oracle | mysql
     * @param maxTop         the largest page this resource will serve
     * @param defaultTop     what to use when the client asks for no page at all
     * @param defaultOrderBy SQL appended when the client asks for no order
     * @param keyField       the exposed name of the resource's key
     */
    public static Result parse(String uri, String columnMap, String dialect,
                               long maxTop, long defaultTop, String defaultOrderBy,
                               String keyField) {
        Result r = new Result();
        Map<String, Column> cols = parseColumnMap(columnMap);
        Map<String, String> opts = parseQuery(uri);
        Dialect d = Dialect.of(dialect);

        r.top = readLong(opts.get("$top"), defaultTop, maxTop);
        r.skip = Math.max(0, readLong(opts.get("$skip"), 0, Long.MAX_VALUE));
        r.wantsCount = "true".equalsIgnoreCase(trim(opts.get("$count")));
        r.key = keyValue(uri, opts, keyField);

        try {
            String filter = trim(opts.get("$filter"));
            if (!filter.isEmpty()) {
                r.filterSql = " WHERE " + new FilterParser(filter, cols, d).parseAll();
            }
        } catch (IllegalArgumentException e) {
            // Rejected rather than dropped: answering a filter you could not read
            // returns more rows than the client asked for, and looks like success.
            r.rejected = true;
            r.rejectReason = e.getMessage();
        }

        List<String[]> terms = sortTerms(trim(opts.get("$orderby")), cols);
        if (!terms.isEmpty()) {
            r.sortColumn1 = terms.get(0)[0];
            r.sortDirection1 = terms.get(0)[1];
        }
        if (terms.size() > 1) {
            r.sortColumn2 = terms.get(1)[0];
            r.sortDirection2 = terms.get(1)[1];
        }
        r.orderBySql = orderBySql(terms, cols, defaultOrderBy, d, r.top, r.skip);
        return r;
    }

    /**
     * The key alone, for a resource whose SQL already answers everything else.
     *
     * <p>Plenty of resources are reached only one way — "the sessions of this
     * weekend", "the laps of this race" — and their whole contract is a single
     * id out of {@code $filter}. Making those build a column map and a dialect
     * to get at one string would be a tax on the common case, so this is the
     * short form of the same parse.
     */
    public static String key(String uri, String keyField) {
        return keyValue(uri, parseQuery(uri), keyField);
    }

    /**
     * The number a {@code $filter} term compares a field to, or the fallback.
     *
     * <p>Distinct from {@link #key} in one way that matters: it never falls back
     * to the path segment. A resource keyed on {@code calendarKey} can also be
     * asked {@code ?$filter=year eq 2021}, and reading 1036 out of
     * {@code /Calendar('1036-c')} as if it were a year would answer a question
     * nobody asked.
     *
     * <p>The quotes are optional because the client's are: the same numeric
     * column arrives as {@code year eq 1957} from a grid header and
     * {@code year eq '1957'} from a combo box.
     */
    public static long filterNumber(String uri, String field, long fallback) {
        String filter = trim(parseQuery(uri).get("$filter"));
        String f = trim(field);
        if (filter.isEmpty() || f.isEmpty()) {
            return fallback;
        }
        Matcher m = Pattern.compile(
                "(?:^|\\s|\\()" + Pattern.quote(f) + "\\s+eq\\s+'?(-?[0-9]{1,18})'?(?:\\s|\\)|$)",
                Pattern.CASE_INSENSITIVE).matcher(filter);
        if (!m.find()) {
            return fallback;
        }
        try {
            return Long.parseLong(m.group(1));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    // ------------------------------------------------------------- dialects

    /** The handful of places SQL engines disagree about what this code emits. */
    private enum Dialect {
        POSTGRESQL, DUCKDB, SQLSERVER, ORACLE, MYSQL;

        static Dialect of(String s) {
            if (s == null) {
                return POSTGRESQL;
            }
            switch (s.trim().toLowerCase()) {
                case "duckdb":     return DUCKDB;
                case "sqlserver":
                case "mssql":      return SQLSERVER;
                case "oracle":     return ORACLE;
                case "mysql":      return MYSQL;
                default:           return POSTGRESQL;
            }
        }

        /** Case-insensitive LIKE, which only two of these spell the same way. */
        String ilike(String col, String pattern) {
            switch (this) {
                case POSTGRESQL:
                case DUCKDB:
                    return col + " ILIKE " + pattern;
                case SQLSERVER:
                    // Default collations are already case-insensitive; LOWER on
                    // both sides is the portable form and costs an index scan
                    // either way once a leading wildcard is involved.
                    return "LOWER(" + col + ") LIKE LOWER(" + pattern + ")";
                default:
                    return "LOWER(" + col + ") LIKE LOWER(" + pattern + ")";
            }
        }

        /** The page window. Three spellings across five engines. */
        String page(long top, long skip) {
            switch (this) {
                case SQLSERVER:
                case ORACLE:
                    // Both require an ORDER BY before OFFSET, which is why the
                    // caller always supplies a default order.
                    return " OFFSET " + skip + " ROWS FETCH NEXT " + top + " ROWS ONLY";
                case MYSQL:
                    return " LIMIT " + skip + ", " + top;
                default:
                    return " LIMIT " + top + (skip > 0 ? " OFFSET " + skip : "");
            }
        }
    }

    // --------------------------------------------------------------- pieces

    /** Query options from a URI, keys lower-cased and values URL-decoded. */
    public static Map<String, String> parseQuery(String uri) {
        Map<String, String> out = new HashMap<>();
        if (uri == null) {
            return out;
        }
        int q = uri.indexOf('?');
        if (q < 0 || q == uri.length() - 1) {
            return out;
        }
        for (String pair : uri.substring(q + 1).split("&")) {
            int eq = pair.indexOf('=');
            if (eq > 0) {
                out.put(decode(pair.substring(0, eq)).toLowerCase(), decode(pair.substring(eq + 1)));
            }
        }
        return out;
    }

    private static String decode(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8.name());
        } catch (Exception e) {
            return s;
        }
    }

    private static Map<String, Column> parseColumnMap(String columnMap) {
        Map<String, Column> cols = new LinkedHashMap<>();
        if (columnMap == null) {
            return cols;
        }
        for (String entry : columnMap.split(",")) {
            String[] bits = entry.trim().split(":");
            if (bits.length >= 2 && !bits[0].trim().isEmpty()) {
                String type = bits.length >= 3 ? columnType(bits[2]) : Column.TEXT;
                cols.put(bits[0].trim().toLowerCase(), new Column(bits[1].trim(), type));
            }
        }
        return cols;
    }

    /**
     * A column type, or a hard failure.
     *
     * <p>An unrecognised type could default to text, which is what the previous
     * helper did by having no types at all. But a typo would then quietly turn
     * {@code year:t.year:numbr} into a text column, and {@code year eq 1957}
     * into {@code t.year = '1957'} — zero rows, status 200, no log line. The
     * whole point of this component is that a request it cannot honour says so,
     * and a column map it cannot read is the same class of mistake. This is
     * design-time input, so failing on the first request is the cheapest place
     * to find out.
     */
    private static String columnType(String raw) {
        switch (raw.trim().toLowerCase()) {
            case "text":
            case "string":
                return Column.TEXT;
            case "number":
            case "int":
            case "integer":
            case "long":
            case "decimal":
                return Column.NUMBER;
            case "bool":
            case "boolean":
                return Column.BOOL;
            case "date":
            case "datetime":
                return Column.DATE;
            default:
                throw new IllegalArgumentException(
                        "unknown column type '" + raw.trim() + "'; expected text, number, bool or date");
        }
    }

    private static String trim(String s) {
        return s == null ? "" : s.trim();
    }

    private static long readLong(String raw, long fallback, long max) {
        if (raw == null) {
            return fallback;
        }
        try {
            long v = Long.parseLong(raw.trim());
            if (v < 0) {
                return fallback;
            }
            return v > max ? max : v;
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    // ------------------------------------------------------------------ key

    private static final Pattern PATH_KEY = Pattern.compile(
            "\\(\\s*(?:[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*)?'?([^')]*)'?\\s*\\)\\s*/?$");

    /**
     * The key a client is re-reading a held row by, in any of the three
     * spellings it arrives in.
     *
     * <p>This is the one that bites. A client holding a row re-reads it by key
     * on its own initiative; a read that ignores that request answers with the
     * collection default, and the client then adopts the first row of the answer
     * as that object's identity — permanently, with a valid payload and a 200 at
     * every step. FINDINGS §37.
     */
    private static String keyValue(String uri, Map<String, String> opts, String keyField) {
        String field = trim(keyField);
        if (!field.isEmpty()) {
            String filter = trim(opts.get("$filter"));
            Matcher m = Pattern.compile(
                    "(?:^|\\s|\\()" + Pattern.quote(field) + "\\s+eq\\s+('([^']*)'|[0-9][0-9.]*)",
                    Pattern.CASE_INSENSITIVE).matcher(filter);
            if (m.find()) {
                String v = m.group(2) != null ? m.group(2) : m.group(1);
                if (safeKey(v)) {
                    return v;
                }
            }
        }
        int q = uri == null ? -1 : uri.indexOf('?');
        String path = uri == null ? "" : (q < 0 ? uri : uri.substring(0, q));
        Matcher pm = PATH_KEY.matcher(path);
        if (pm.find() && safeKey(pm.group(1))) {
            return pm.group(1);
        }
        return "";
    }

    private static boolean safeKey(String v) {
        return v != null && v.matches("[A-Za-z0-9_.\\-]{1,128}");
    }

    // ---------------------------------------------------------------- order

    private static List<String[]> sortTerms(String orderby, Map<String, Column> cols) {
        List<String[]> out = new ArrayList<>();
        if (orderby.isEmpty()) {
            return out;
        }
        for (String term : orderby.split(",")) {
            String[] bits = term.trim().split("\\s+");
            if (bits.length == 0 || bits[0].isEmpty()) {
                continue;
            }
            if (!cols.containsKey(bits[0].toLowerCase())) {
                continue; // not whitelisted: a wrong order is cosmetic, so ignore it
            }
            out.add(new String[]{bits[0], bits.length > 1 && "desc".equalsIgnoreCase(bits[1]) ? "D" : "A"});
        }
        return out;
    }

    private static String orderBySql(List<String[]> terms, Map<String, Column> cols,
                                     String defaultOrderBy, Dialect d, long top, long skip) {
        List<String> parts = new ArrayList<>();
        for (String[] t : terms) {
            parts.add(cols.get(t[0].toLowerCase()).sql + ("D".equals(t[1]) ? " DESC" : " ASC"));
        }
        if (parts.isEmpty() && !trim(defaultOrderBy).isEmpty()) {
            parts.add(defaultOrderBy.trim());
        }
        StringBuilder sb = new StringBuilder();
        if (!parts.isEmpty()) {
            sb.append(" ORDER BY ").append(String.join(", ", parts));
        }
        sb.append(d.page(top, skip));
        return sb.toString();
    }

    // --------------------------------------------------------------- filter

    /**
     * Recursive descent over the filter grammar, so precedence and parentheses
     * are handled rather than approximated.
     *
     * <p>An earlier version split the string on {@code and} and matched each
     * piece with a regex. That cannot express {@code or} at all — which Mendix
     * emits the moment a datagrid has two values selected in one filter — and it
     * cannot see that {@code a and (b or c)} groups.
     */
    private static final class FilterParser {
        private final String src;
        private final Map<String, Column> cols;
        private final Dialect d;
        private int pos;

        FilterParser(String src, Map<String, Column> cols, Dialect d) {
            this.src = src;
            this.cols = cols;
            this.d = d;
        }

        String parseAll() {
            String sql = parseOr();
            skipSpace();
            if (pos < src.length()) {
                throw new IllegalArgumentException("unparsed input at " + pos + ": " + src.substring(pos));
            }
            return sql;
        }

        private String parseOr() {
            String left = parseAnd();
            while (keyword("or")) {
                left = "(" + left + " OR " + parseAnd() + ")";
            }
            return left;
        }

        private String parseAnd() {
            String left = parseUnary();
            while (keyword("and")) {
                left = "(" + left + " AND " + parseUnary() + ")";
            }
            return left;
        }

        private String parseUnary() {
            if (keyword("not")) {
                return "(NOT " + parseUnary() + ")";
            }
            return parsePrimary();
        }

        private String parsePrimary() {
            skipSpace();
            if (peek() == '(') {
                int save = pos;
                pos++;
                String inner = parseOr();
                skipSpace();
                if (peek() != ')') {
                    pos = save;
                    throw new IllegalArgumentException("unbalanced parenthesis");
                }
                pos++;
                return "(" + inner + ")";
            }
            return parseTerm();
        }

        private static final Pattern FN = Pattern.compile(
                "\\G(contains|startswith|endswith)\\s*\\(\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*,\\s*('(?:[^']|'')*')\\s*\\)",
                Pattern.CASE_INSENSITIVE);
        private static final Pattern CMP = Pattern.compile(
                "\\G([A-Za-z_][A-Za-z0-9_]*)\\s+(eq|ne|gt|ge|lt|le)\\s+"
                        + "('(?:[^']|'')*'|-?[0-9][0-9.]*|true|false|null|"
                        + "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?)",
                Pattern.CASE_INSENSITIVE);

        private String parseTerm() {
            skipSpace();
            Matcher fn = FN.matcher(src);
            fn.region(pos, src.length());
            if (fn.find()) {
                pos = fn.end();
                Column c = require(fn.group(2));
                String v = esc(unquote(fn.group(3)));
                String kind = fn.group(1).toLowerCase();
                String pattern = "contains".equals(kind) ? "'%" + v + "%'"
                        : "startswith".equals(kind) ? "'" + v + "%'" : "'%" + v + "'";
                // Substring search against a number or a date is meaningful — a
                // user typing "195" into a year filter means the 1950s — but only
                // once the column is text. LIKE against a BIGINT is a type error
                // on some engines and a silent cast on others.
                String col = Column.TEXT.equals(c.type) ? c.sql : "CAST(" + c.sql + " AS VARCHAR)";
                return d.ilike(col, pattern);
            }
            Matcher cmp = CMP.matcher(src);
            cmp.region(pos, src.length());
            if (cmp.find()) {
                pos = cmp.end();
                Column c = require(cmp.group(1));
                String op = cmp.group(2).toLowerCase();
                String val = cmp.group(3);
                return comparison(c, op, val);
            }
            throw new IllegalArgumentException("cannot translate: " + src.substring(pos));
        }

        /**
         * One comparison, rendered for the column's own type rather than for the
         * shape the client happened to send.
         */
        private String comparison(Column c, String op, String val) {
            if ("null".equalsIgnoreCase(val)) {
                if ("eq".equals(op)) {
                    return c.sql + " IS NULL";
                }
                if ("ne".equals(op)) {
                    return c.sql + " IS NOT NULL";
                }
                throw new IllegalArgumentException("null only compares with eq or ne");
            }
            String sqlOp = sqlOp(op);
            String bare = val.startsWith("'") ? unquote(val) : val;

            if (Column.NUMBER.equals(c.type)) {
                if (!bare.matches("-?[0-9]+(\\.[0-9]+)?")) {
                    throw new IllegalArgumentException("not a number for " + c.sql + ": " + bare);
                }
                return c.sql + " " + sqlOp + " " + bare;
            }
            if (Column.BOOL.equals(c.type)) {
                if (!"true".equalsIgnoreCase(bare) && !"false".equalsIgnoreCase(bare)) {
                    throw new IllegalArgumentException("not a boolean for " + c.sql + ": " + bare);
                }
                return c.sql + " " + sqlOp + " " + bare.toLowerCase();
            }
            if (Column.DATE.equals(c.type)) {
                // Quoted and cast rather than pasted, so the engine parses the
                // instant instead of this code guessing a format.
                return c.sql + " " + sqlOp + " CAST('" + esc(bare) + "' AS TIMESTAMP)";
            }
            return c.sql + " " + sqlOp + " '" + esc(bare) + "'";
        }

        private Column require(String name) {
            Column c = cols.get(name.toLowerCase());
            if (c == null) {
                throw new IllegalArgumentException("field not filterable: " + name);
            }
            return c;
        }

        private boolean keyword(String kw) {
            skipSpace();
            int end = pos + kw.length();
            if (end <= src.length() && src.regionMatches(true, pos, kw, 0, kw.length())
                    && (end == src.length() || !Character.isLetterOrDigit(src.charAt(end)))) {
                pos = end;
                return true;
            }
            return false;
        }

        private void skipSpace() {
            while (pos < src.length() && Character.isWhitespace(src.charAt(pos))) {
                pos++;
            }
        }

        private char peek() {
            return pos < src.length() ? src.charAt(pos) : '\0';
        }
    }

    private static String sqlOp(String odataOp) {
        switch (odataOp) {
            case "eq": return "=";
            case "ne": return "<>";
            case "gt": return ">";
            case "ge": return ">=";
            case "lt": return "<";
            case "le": return "<=";
            default: throw new IllegalArgumentException("unsupported operator: " + odataOp);
        }
    }

    private static String unquote(String literal) {
        String s = literal.substring(1, literal.length() - 1);
        return s.replace("''", "'");
    }

    private static String esc(String v) {
        return v.replace("'", "''");
    }
}
