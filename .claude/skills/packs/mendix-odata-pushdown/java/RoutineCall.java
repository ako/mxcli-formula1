package {{MODULE_PATH}};

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * How to invoke a stored routine, in the spelling the engine wants.
 *
 * <p><b>What this is for.</b> The rest of this module puts a query behind an
 * OData resource. This puts a <em>routine</em> behind one — a stored procedure,
 * a table-valued function, a package body — which is where a great deal of the
 * logic worth exposing actually lives, and the part of a legacy system nobody
 * gets to rewrite.
 *
 * <p><b>What it deliberately does not do.</b> It never renders a value. Every
 * argument comes out as a Mendix named parameter — {@code {driverId}} — so the
 * statement it returns is a template that {@code execute database query} binds.
 * There is no escaping here because there is nothing to escape: the only text
 * this class emits is the routine name, which is checked against an identifier
 * pattern, and punctuation.
 *
 * <p>That is a stronger position than the {@code $filter} translation can take.
 * A {@code WHERE} clause has to be built as text because its <em>shape</em>
 * comes from the client; a routine call's shape is fixed by the routine, and
 * only the values vary. So they can be bound, and they are.
 *
 * <p><b>Why it is not just string concatenation.</b> Five engines, three kinds
 * of routine, and almost no two agree:
 *
 * <pre>
 *   table-valued function        procedure
 *   ─────────────────────────    ────────────────────────────
 *   pg   SELECT * FROM f(a,b)    CALL p(a,b,NULL,NULL)
 *   mssql SELECT * FROM f(a,b)   EXEC p @x = a, @y = b
 *   ora  SELECT * FROM TABLE(f(a,b))
 *                                BEGIN p(a,b); END;
 *   mysql (none — use a proc)    CALL p(a,b)
 *   duck SELECT * FROM f(a,b)    (none — macros only)
 * </pre>
 *
 * Getting that wrong is a whole afternoon, once per engine.
 */
public final class RoutineCall {

    /** A schema-qualified routine name and nothing else. */
    private static final Pattern ROUTINE =
            Pattern.compile("[A-Za-z_][A-Za-z0-9_]{0,62}(\\.[A-Za-z_][A-Za-z0-9_]{0,62}){0,2}");

    /** A Mendix query parameter name. */
    private static final Pattern PARAM = Pattern.compile("[A-Za-z_][A-Za-z0-9_]{0,62}");

    private RoutineCall() {
    }

    /**
     * The statement to run, with one bound parameter per argument.
     *
     * @param routine    schema-qualified name, e.g. {@code f1ops.driver_form}
     * @param kind       {@code table} | {@code procedure} | {@code scalar}
     * @param parameters comma-separated Mendix parameter names, in the routine's
     *                   own argument order; {@code null} for a literal SQL NULL,
     *                   which is how a Postgres procedure's INOUT slots are
     *                   filled
     * @param dialect    postgresql | duckdb | sqlserver | oracle | mysql
     */
    public static String statement(String routine, String kind, String parameters, String dialect) {
        String name = trim(routine);
        if (!ROUTINE.matcher(name).matches()) {
            throw new IllegalArgumentException("not a routine name: " + routine);
        }
        String d = trim(dialect).toLowerCase();
        String k = trim(kind).toLowerCase();
        List<String> args = args(parameters, d);

        switch (k) {
            case "table":
                return tableCall(name, args, d);
            case "procedure":
                return procedureCall(name, args, parameters, d);
            case "scalar":
                return "SELECT " + name + "(" + join(args) + ") AS result";
            default:
                throw new IllegalArgumentException(
                        "unknown routine kind '" + kind + "'; expected table, procedure or scalar");
        }
    }

    // ------------------------------------------------------------------ kinds

    private static String tableCall(String name, List<String> args, String d) {
        if ("oracle".equals(d)) {
            // A pipelined function is a table only inside TABLE().
            return "SELECT * FROM TABLE(" + name + "(" + join(args) + "))";
        }
        if ("mysql".equals(d)) {
            // MySQL has no table-valued functions at all. Saying so beats
            // emitting something that parses and returns one scalar column.
            throw new IllegalArgumentException(
                    "mysql has no table-valued functions; use kind 'procedure'");
        }
        return "SELECT * FROM " + name + "(" + join(args) + ")";
    }

    private static String procedureCall(String name, List<String> args, String rawParams, String d) {
        switch (d) {
            case "sqlserver":
                // Named arguments, because EXEC positional and named cannot mix
                // and named is the form that survives a routine gaining a
                // parameter with a default.
                return "EXEC " + name + named(rawParams);
            case "oracle":
                return "BEGIN " + name + "(" + join(args) + "); END;";
            case "duckdb":
                throw new IllegalArgumentException(
                        "duckdb has no stored procedures; use kind 'table' over a macro");
            default:
                // Postgres and MySQL. In Postgres a CALL with INOUT parameters
                // answers with one row carrying them, which is what makes a
                // procedure readable through the same query interface as a
                // SELECT.
                return "CALL " + name + "(" + join(args) + ")";
        }
    }

    // ------------------------------------------------------------------ args

    /**
     * One placeholder per named parameter.
     *
     * <p>{@code null} is passed through as a literal, because a Postgres
     * procedure's INOUT slots have to be present in the call and there is
     * nothing to bind into them — the engine fills them on the way out.
     */
    private static List<String> args(String parameters, String dialect) {
        List<String> out = new ArrayList<>();
        if (trim(parameters).isEmpty()) {
            return out;
        }
        for (String raw : parameters.split(",")) {
            String p = raw.trim();
            if (p.isEmpty()) {
                continue;
            }
            if ("null".equalsIgnoreCase(p)) {
                out.add("NULL");
                continue;
            }
            if (!PARAM.matcher(p).matches()) {
                throw new IllegalArgumentException("not a parameter name: " + p);
            }
            out.add("{" + p + "}");
        }
        return out;
    }

    /** SQL Server's {@code @name = {name}} form. */
    private static String named(String parameters) {
        StringBuilder sb = new StringBuilder();
        if (trim(parameters).isEmpty()) {
            return "";
        }
        boolean first = true;
        for (String raw : parameters.split(",")) {
            String p = raw.trim();
            if (p.isEmpty() || "null".equalsIgnoreCase(p)) {
                continue; // SQL Server OUTPUT slots are declared, not passed
            }
            if (!PARAM.matcher(p).matches()) {
                throw new IllegalArgumentException("not a parameter name: " + p);
            }
            sb.append(first ? " " : ", ").append('@').append(p).append(" = {").append(p).append('}');
            first = false;
        }
        return sb.toString();
    }

    private static String join(List<String> args) {
        return String.join(", ", args);
    }

    private static String trim(String s) {
        return s == null ? "" : s.trim();
    }
}
