#!/usr/bin/env bash

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# RFC 10008 requirements that are observable at a ClickHouse origin server:
# - the request content and its media type define the query;
# - a missing media type is rejected;
# - QUERY is safe and idempotent;
# - URI query parameters still identify and configure the target resource.
# Location, Content-Location, conditional requests, caching, ranges, and Accept-Query are optional
# protocol facilities and are not implemented by the ClickHouse HTTP query endpoint.

BASE="${CLICKHOUSE_PORT_HTTP_PROTO}://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT_HTTP}"
DB="${CLICKHOUSE_DATABASE}"
PREFIX="/query_method_${DB}"
HSELECT="query_select_${DB}"
HRAW="query_raw_${DB}"
HFORM="query_form_${DB}"

cleanup()
{
    ${CLICKHOUSE_CLIENT} -q "
        DROP HANDLER IF EXISTS \`${HSELECT}\`;
        DROP HANDLER IF EXISTS \`${HRAW}\`;
        DROP HANDLER IF EXISTS \`${HFORM}\`;"
}

trap cleanup EXIT
cleanup

check_equal()
{
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo "${name}: OK"
    else
        echo "${name}: expected '${expected}', got '${actual}'"
    fi
}

check_contains()
{
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == *"$expected"* ]]; then
        echo "${name}: OK"
    else
        echo "${name}: response does not contain '${expected}'"
    fi
}

http_status()
{
    ${CLICKHOUSE_CURL} -sS -o /dev/null -w '%{http_code}' "$@"
}

# A successful QUERY carries SQL in its content and returns the query result with status 200.
status=$(http_status -X QUERY -H 'Content-Type: application/sql' --data-binary 'SELECT 1' "${CLICKHOUSE_URL}")
check_equal "application/sql status" "200" "$status"

body=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' --data-binary 'SELECT 1 FORMAT TSV' "${CLICKHOUSE_URL}")
check_equal "application/sql body" "1" "$body"

# Media type matching ignores case and parameters.
body=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: Text/Plain; charset=UTF-8' --data-binary 'SELECT 2 FORMAT TSV' "${CLICKHOUSE_URL}")
check_equal "media type parameters" "2" "$body"

# The URI query component remains part of the target. ClickHouse allows SQL to be split between
# the `query` URI parameter and the request content, as it does for POST.
body=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' --data-binary ' 3 FORMAT TSV' "${CLICKHOUSE_URL}&query=SELECT")
check_equal "URI query component" "3" "$body"

# `curl --data-binary` otherwise adds `Content-Type: application/x-www-form-urlencoded`, so explicitly
# erase the field to exercise the RFC's missing-media-type requirement.
status=$(http_status -X QUERY -H 'Content-Type:' --data-binary 'SELECT 1' "${CLICKHOUSE_URL}")
check_equal "missing Content-Type" "400" "$status"

# A declared SQL media type with malformed SQL is rejected as a client error; the server must not
# replace the declared type by sniffing another representation from the content.
status=$(http_status -X QUERY -H 'Content-Type: application/sql' --data-binary 'this is not SQL' "${CLICKHOUSE_URL}")
if [[ "$status" == 4* ]]; then
    echo "invalid SQL content: OK"
else
    echo "invalid SQL content: expected 4xx, got '${status}'"
fi

# A body consumed by the built-in query endpoint must be framed. Either Content-Length (added by
# --data-binary) or chunked Transfer-Encoding is accepted; neither produces 411.
status=$(http_status -X QUERY -H 'Content-Type: application/sql' "${CLICKHOUSE_URL}&query=SELECT%201")
check_equal "missing body framing" "411" "$status"

body=$(printf 'SELECT 4 FORMAT TSV' | ${CLICKHOUSE_CURL} -sS --http1.1 -X QUERY \
    -H 'Content-Type: application/sql' -H 'Transfer-Encoding: chunked' --data-binary @- "${CLICKHOUSE_URL}")
check_equal "chunked request content" "4" "$body"

# QUERY is safe: it cannot perform a persistent mutation.
error=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' \
    --data-binary "CREATE TABLE ${DB}.query_method_forbidden (x UInt8) ENGINE = Memory" "${CLICKHOUSE_URL}" 2>&1)
check_contains "safe method rejects mutation" "READONLY" "$error"

exists=$(${CLICKHOUSE_CLIENT} -q "EXISTS TABLE ${DB}.query_method_forbidden")
check_equal "safe method leaves no table" "0" "$exists"

# Repeating an idempotent QUERY produces the same result and no requested state change.
first=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' \
    --data-binary 'SELECT sum(number) FROM numbers(10) FORMAT TSV' "${CLICKHOUSE_URL}")
second=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' \
    --data-binary 'SELECT sum(number) FROM numbers(10) FORMAT TSV' "${CLICKHOUSE_URL}")
check_equal "idempotent repeated result" "$first" "$second"

# ClickHouse-specific response format selection continues to work for QUERY.
body=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' \
    -H 'X-ClickHouse-Format: JSONEachRow' --data-binary 'SELECT 42 AS x' "${CLICKHOUSE_URL}")
check_equal "response format header" '{"x":42}' "$body"

# SQL processing errors are returned normally through the QUERY method.
error=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' \
    --data-binary 'SELECT * FROM query_method_nonexistent_table' "${CLICKHOUSE_URL}" 2>&1)
check_contains "SQL error propagation" "UNKNOWN_TABLE" "$error"

# QUERY is not CORS-safelisted, so browsers use OPTIONS preflight. The default server configuration
# must advertise QUERY among the allowed methods.
headers=$(${CLICKHOUSE_CURL} -sS -X OPTIONS -H 'Origin: https://example.test' -D - -o /dev/null "${CLICKHOUSE_URL}")
check_contains "CORS preflight advertises QUERY" "QUERY" "$headers"

# SQL-defined handlers participate in method routing. A handler that does not consume content accepts
# an explicitly empty, framed QUERY representation.
${CLICKHOUSE_CLIENT} -q "CREATE HANDLER \`${HSELECT}\` URL '${PREFIX}/select' METHODS (QUERY) AS SELECT 41 + 1 FORMAT TSV"
body=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/sql' -H 'Content-Length: 0' "${BASE}${PREFIX}/select")
check_equal "SQL handler routing" "42" "$body"

# Raw request content and both form encodings are available to SQL-defined QUERY handlers.
${CLICKHOUSE_CLIENT} -q "CREATE HANDLER \`${HRAW}\` URL '${PREFIX}/raw' METHODS (QUERY) AS SELECT {_request_body:String} FORMAT TSV"
body=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: text/plain' --data-binary 'raw query body' "${BASE}${PREFIX}/raw")
check_equal "SQL handler raw body" "raw query body" "$body"

${CLICKHOUSE_CLIENT} -q "CREATE HANDLER \`${HFORM}\` URL '${PREFIX}/form' METHODS (QUERY) AS SELECT {id:UInt64} * 2 FORMAT TSV"
body=$(${CLICKHOUSE_CURL} -sS -X QUERY -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary 'param_id=21' "${BASE}${PREFIX}/form")
check_equal "SQL handler URL-encoded body" "42" "$body"

body=$(${CLICKHOUSE_CURL} -sS -X QUERY -F 'param_id=6' "${BASE}${PREFIX}/form")
check_equal "SQL handler multipart body" "12" "$body"
