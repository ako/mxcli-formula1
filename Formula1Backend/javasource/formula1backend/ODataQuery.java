package formula1backend;

import java.math.BigDecimal;
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
 * Turns the OData query options on a request URI into SQL fragments for DuckDB.
 *
 * <p>The live service publishes non-persistable entities backed by read
 * microflows. Mendix applies none of {@code $top} / {@code $skip} /
 * {@code $orderby} / {@code $filter} to what such a microflow returns — the
 * microflow is handed the request and whatever it returns is the response. So a
 * datagrid asking for "rows 80-100 ordered by name" only becomes a 20-row query
 * if this code makes it one.
 *
 * <p><b>Injection.</b> Column names come from the client. Every one of them is
 * resolved through a whitelist supplied by the caller — the {@code columnMap},
 * {@code exposedName:sqlExpression} pairs. Nothing else can reach the SQL. A
 * name absent from the map is ignored in {@code $orderby} (a wrong sort order is
 * cosmetic) and rejected in {@code $filter} (a dropped filter would silently
 * return more rows than the client asked for). Literal values are escaped, and
 * anything numeric must parse as a number.
 */
public final class ODataQuery {

    private ODataQuery() {
    }

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
            if (eq <= 0) {
                continue;
            }
            String key = decode(pair.substring(0, eq)).toLowerCase();
            out.put(key, decode(pair.substring(eq + 1)));
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

    /** The whitelist: "exposedName:sqlExpression,..." keyed by lower-cased name. */
    public static Map<String, String> parseColumnMap(String columnMap) {
        Map<String, String> cols = new LinkedHashMap<>();
        if (columnMap == null) {
            return cols;
        }
        for (String pair : columnMap.split(",")) {
            int c = pair.indexOf(':');
            if (c > 0) {
                cols.put(pair.substring(0, c).trim().toLowerCase(), pair.substring(c + 1).trim());
            }
        }
        return cols;
    }

    /** " ORDER BY ... LIMIT n OFFSET m". LIMIT is always present. */
    public static String orderLimit(String uri, String columnMap, String defaultOrderBy, long maxTop) {
        Map<String, String> opts = parseQuery(uri);
        Map<String, String> cols = parseColumnMap(columnMap);

        List<String> order = new ArrayList<>();
        String ob = opts.get("$orderby");
        if (ob != null && !ob.trim().isEmpty()) {
            for (String term : ob.split(",")) {
                String[] bits = term.trim().split("\\s+");
                if (bits.length == 0 || bits[0].isEmpty()) {
                    continue;
                }
                String col = cols.get(bits[0].toLowerCase());
                if (col == null) {
                    continue; // not whitelisted — ignore this sort term
                }
                order.add(col + (bits.length > 1 && "desc".equalsIgnoreCase(bits[1]) ? " DESC" : " ASC"));
            }
        }
        if (order.isEmpty() && defaultOrderBy != null && !defaultOrderBy.trim().isEmpty()) {
            order.add(defaultOrderBy.trim());
        }

        StringBuilder sb = new StringBuilder();
        if (!order.isEmpty()) {
            sb.append(" ORDER BY ").append(String.join(", ", order));
        }

        // Always bound the response. Without $top the client gets maxTop rows
        // rather than the whole table — an unbounded read microflow is how this
        // service used to return 293 KB for a grid showing twenty names.
        long top = maxTop;
        long skip = 0;
        try {
            if (opts.containsKey("$top")) {
                top = Long.parseLong(opts.get("$top").trim());
            }
        } catch (NumberFormatException ignored) {
            // fall back to maxTop
        }
        try {
            if (opts.containsKey("$skip")) {
                skip = Long.parseLong(opts.get("$skip").trim());
            }
        } catch (NumberFormatException ignored) {
            // fall back to 0
        }
        if (top < 0 || top > maxTop) {
            top = maxTop;
        }
        if (skip < 0) {
            skip = 0;
        }
        sb.append(" LIMIT ").append(top);
        if (skip > 0) {
            sb.append(" OFFSET ").append(skip);
        }
        return sb.toString();
    }

    private static final Pattern FN = Pattern.compile(
            "^(contains|startswith|endswith)\\(\\s*([A-Za-z0-9_]+)\\s*,\\s*(.+)\\)$",
            Pattern.CASE_INSENSITIVE);

    private static final Pattern CMP = Pattern.compile(
            "^([A-Za-z0-9_]+)\\s+(eq|ne|gt|ge|lt|le)\\s+(.+)$",
            Pattern.CASE_INSENSITIVE);

    /**
     * " WHERE ..." for the subset of $filter a datagrid actually emits, or "" if
     * there is no filter.
     *
     * @throws IllegalArgumentException on anything not translatable, rather than
     *     quietly widening the result set
     */
    public static String where(String uri, String columnMap) {
        Map<String, String> opts = parseQuery(uri);
        String filter = opts.get("$filter");
        if (filter == null || filter.trim().isEmpty()) {
            return "";
        }
        Map<String, String> cols = parseColumnMap(columnMap);

        List<String> terms = new ArrayList<>();
        for (String raw : filter.split("(?i)\\s+and\\s+")) {
            String t = raw.trim();
            while (t.startsWith("(") && t.endsWith(")")) {
                t = t.substring(1, t.length() - 1).trim();
            }

            Matcher fn = FN.matcher(t);
            if (fn.matches()) {
                String col = requireColumn(cols, fn.group(2));
                String v = esc(stringLiteral(fn.group(3).trim()));
                String kind = fn.group(1).toLowerCase();
                String pattern = "contains".equals(kind) ? "'%" + v + "%'"
                        : "startswith".equals(kind) ? "'" + v + "%'"
                        : "'%" + v + "'";
                terms.add(col + " ILIKE " + pattern);
                continue;
            }

            Matcher cmp = CMP.matcher(t);
            if (cmp.matches()) {
                String col = requireColumn(cols, cmp.group(1));
                String op = sqlOp(cmp.group(2).toLowerCase());
                String val = cmp.group(3).trim();
                if (val.startsWith("'")) {
                    terms.add(col + " " + op + " '" + esc(stringLiteral(val)) + "'");
                } else if ("true".equalsIgnoreCase(val) || "false".equalsIgnoreCase(val)) {
                    terms.add(col + " " + op + " " + val.toLowerCase());
                } else if ("null".equalsIgnoreCase(val)) {
                    terms.add(col + ("=".equals(op) ? " IS NULL" : " IS NOT NULL"));
                } else {
                    try {
                        new BigDecimal(val);
                    } catch (NumberFormatException e) {
                        throw new IllegalArgumentException("Unsupported $filter value: " + val);
                    }
                    terms.add(col + " " + op + " " + val);
                }
                continue;
            }
            throw new IllegalArgumentException("Unsupported $filter expression: " + t);
        }
        return terms.isEmpty() ? "" : " WHERE " + String.join(" AND ", terms);
    }

    /** True when the client asked for $count=true. */
    public static boolean wantsCount(String uri) {
        String v = parseQuery(uri).get("$count");
        return v != null && "true".equalsIgnoreCase(v.trim());
    }

    /**
     * The right-hand side of `<field> eq <value>` in $filter, as an identifier
     * safe to paste into SQL.
     *
     * The resources built on it — a driver's career, a season's points
     * progression — are not a filtered projection of one table but a query whose
     * *shape* depends on the value: it appears in three subqueries, inside a
     * window function, in a CROSS JOIN. {@link #where} cannot express that, so
     * the value is lifted out and interpolated instead.
     *
     * Interpolating anything from a URL is the injection case, so this is a
     * whitelist, not an escape: the return value is guaranteed to match
     * [A-Za-z0-9_-]{1,64} or be empty. f1db keys are all slugs, so nothing legal
     * is lost. Empty means absent — the caller decides whether that is a default
     * or an empty result, and must never treat it as "no filter, return
     * everything".
     */
    public static String filterIdentifier(String uri, String field) {
        String filter = parseQuery(uri).get("$filter");
        if (filter == null || field == null || field.isEmpty()) {
            return "";
        }
        Matcher m = Pattern.compile(
                "(?:^|\\s|\\()" + Pattern.quote(field) + "\\s+eq\\s+'([^']*)'",
                Pattern.CASE_INSENSITIVE).matcher(filter);
        if (!m.find()) {
            return "";
        }
        String value = m.group(1);
        return value.matches("[A-Za-z0-9_-]{1,64}") ? value : "";
    }

    /**
     * The right-hand side of `<field> eq <number>` in $filter, as a long.
     * Returns {@code fallback} when the term is absent or not a plain integer —
     * a year, a round, nothing else.
     */
    public static long filterLong(String uri, String field, long fallback) {
        String filter = parseQuery(uri).get("$filter");
        if (filter == null || field == null || field.isEmpty()) {
            return fallback;
        }
        Matcher m = Pattern.compile(
                "(?:^|\\s|\\()" + Pattern.quote(field) + "\\s+eq\\s+(-?\\d{1,9})(?:\\s|\\)|$)",
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

    /**
     * The first {@code $orderby} column, as its **exposed** name, or "" when the
     * client did not ask for an order or asked for something not whitelisted.
     *
     * The exposed name rather than the SQL one, because this is compared against
     * literals inside a bound CASE rather than spliced into the statement — the
     * resources that use it keep their SQL in the connection and cannot take a
     * clause. {@link #orderLimit} is the other half of this pair, for callers
     * that do build their own statement.
     *
     * Only the first term. A multi-column sort would need one CASE per term in
     * every query; a datagrid emits one.
     */
    public static String sortColumn(String uri, String columnMap) {
        String ob = parseQuery(uri).get("$orderby");
        if (ob == null || ob.trim().isEmpty()) {
            return "";
        }
        String[] bits = ob.split(",")[0].trim().split("\\s+");
        if (bits.length == 0 || bits[0].isEmpty()) {
            return "";
        }
        String name = bits[0].trim();
        // Whitelisted by the same map the SQL side uses, so an unknown name
        // sorts by nothing rather than reaching the query.
        return parseColumnMap(columnMap).containsKey(name.toLowerCase()) ? name : "";
    }

    /** "D" when the first {@code $orderby} term is descending, else "A". */
    public static String sortDirection(String uri) {
        String ob = parseQuery(uri).get("$orderby");
        if (ob == null || ob.trim().isEmpty()) {
            return "A";
        }
        String[] bits = ob.split(",")[0].trim().split("\\s+");
        return bits.length > 1 && "desc".equalsIgnoreCase(bits[1]) ? "D" : "A";
    }

    /**
     * The value of {@code $top}, or {@code fallback} when the client did not ask
     * for a page.
     *
     * The companion to {@link #orderLimit}, for resources that build no SQL of
     * their own: those pass the value to a bound LIMIT rather than splicing a
     * clause. The fallback is "everything" rather than a page size, because
     * these resources returned their whole list before paging existed and a
     * caller that never asked for a page must keep getting one.
     *
     * Clamped to {@code maxTop} so a client cannot ask for more work than the
     * resource is willing to do, and a negative or unparseable value falls back
     * rather than reaching SQL.
     */
    public static long topValue(String uri, long fallback, long maxTop) {
        String raw = parseQuery(uri).get("$top");
        if (raw == null) {
            return fallback;
        }
        try {
            long v = Long.parseLong(raw.trim());
            if (v < 0) {
                return fallback;
            }
            return v > maxTop ? maxTop : v;
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    /** The value of {@code $skip}; 0 when absent, negative or unparseable. */
    public static long skipValue(String uri) {
        String raw = parseQuery(uri).get("$skip");
        if (raw == null) {
            return 0;
        }
        try {
            long v = Long.parseLong(raw.trim());
            return v < 0 ? 0 : v;
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /**
     * The key literal of a key-addressed request, or "" for a collection read.
     *
     * `/odata/f1-fan/Calendar('1036-c')` yields `1036-c`; `/Calendar(1036)`
     * yields `1036`; `/Calendar` and `/Calendar?$filter=...` yield "".
     *
     * Both key forms have to be read, because clients pick between them and the
     * one Mendix's own OData client sends is the named one: OData allows the
     * bare `Calendar('1036-c')` and the named `Calendar(calendarKey='1036-c')`,
     * and reading only the bare form is indistinguishable from reading neither.
     *
     * This matters more than it looks. A published resource whose ReadMode is a
     * microflow is asked for a single object by key whenever a client needs to
     * resolve an object it is holding — which is what happens when a grid row is
     * handed to another page. That request carries the key in the *path*, not in
     * $filter, so a read microflow that only inspects $filter answers with its
     * collection default and the client silently takes the first row of it. The
     * symptom is a drill-down that always opens the same record no matter which
     * row was clicked, with no error anywhere. FINDINGS §37.
     *
     * Whitelisted like the $filter readers, and for the same reason: the value
     * is interpolated into SQL rather than bound.
     */
    public static String entityKey(String uri) {
        if (uri == null) {
            return "";
        }
        int q = uri.indexOf('?');
        String path = q < 0 ? uri : uri.substring(0, q);
        Matcher m = Pattern.compile(
                "\\(\\s*(?:[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*)?'?([^')]*)'?\\s*\\)\\s*/?$")
                .matcher(path);
        if (!m.find()) {
            return "";
        }
        String value = m.group(1);
        return value.matches("[A-Za-z0-9_-]{1,64}") ? value : "";
    }

    /**
     * The leading digits of {@link #entityKey}, as a long — for keys that are an
     * id with a suffix, like Calendar's `1036-c`. {@code fallback} when there
     * is no key or it does not start with digits.
     */
    public static long entityKeyLong(String uri, long fallback) {
        Matcher m = Pattern.compile("^(\\d{1,9})").matcher(entityKey(uri));
        if (!m.find()) {
            return fallback;
        }
        try {
            return Long.parseLong(m.group(1));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static String requireColumn(Map<String, String> cols, String name) {
        String col = cols.get(name.toLowerCase());
        if (col == null) {
            throw new IllegalArgumentException("Unknown or non-filterable field in $filter: " + name);
        }
        return col;
    }

    private static String sqlOp(String odataOp) {
        switch (odataOp) {
            case "eq": return "=";
            case "ne": return "<>";
            case "gt": return ">";
            case "ge": return ">=";
            case "lt": return "<";
            case "le": return "<=";
            default: throw new IllegalArgumentException("Unsupported operator: " + odataOp);
        }
    }

    /**
     * Reads one complete OData string literal and returns its value.
     *
     * <p>OData escapes a quote inside a literal by doubling it, so {@code 'O''Brien'}
     * is the five-plus-two characters {@code O'Brien}. Naively stripping the outer
     * quotes gets that wrong, and — worse — accepts input that is not a single
     * literal at all: {@code 'a' or name eq 'b'} both starts and ends with a quote,
     * so a startsWith/endsWith check would wave through an OR this translator does
     * not implement and emit SQL the caller never asked for.
     *
     * <p>So the closing quote must be the last character, and anything else throws.
     */
    private static String stringLiteral(String s) {
        if (s.length() < 2 || s.charAt(0) != '\'') {
            throw new IllegalArgumentException("Expected a quoted value in $filter: " + s);
        }
        StringBuilder sb = new StringBuilder();
        int i = 1;
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c == '\'') {
                if (i + 1 < s.length() && s.charAt(i + 1) == '\'') {
                    sb.append('\'');
                    i += 2;
                    continue;
                }
                if (i != s.length() - 1) {
                    throw new IllegalArgumentException("Unsupported $filter expression: " + s);
                }
                return sb.toString();
            }
            sb.append(c);
            i++;
        }
        throw new IllegalArgumentException("Unterminated string literal in $filter: " + s);
    }

    private static String esc(String v) {
        return v.replace("'", "''");
    }
}
