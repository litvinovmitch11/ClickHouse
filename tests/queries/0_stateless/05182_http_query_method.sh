#!/usr/bin/env bash

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

#######################
# ${CLICKHOUSE_CURL} -sS -X GET "${CLICKHOUSE_URL}&query=SELECT+name,value,changed+FROM+system.settings+WHERE+name+IN+('readonly','max_rows_to_read')&max_rows_to_read=10000&default_format=PrettySpaceNoEscapes"
# ${CLICKHOUSE_CURL} -sS -X POST "${CLICKHOUSE_URL}&max_rows_to_read=10000&default_format=PrettySpaceNoEscapes" -d "SELECT name, value, changed FROM system.settings WHERE name IN ('readonly','max_rows_to_read')"
# ${CLICKHOUSE_CURL} -sS -X QUERY "${CLICKHOUSE_URL}&max_rows_to_read=10000&default_format=PrettySpaceNoEscapes" -d "SELECT name, value, changed FROM system.settings WHERE name IN ('readonly','max_rows_to_read')"
# ${CLICKHOUSE_CURL} -sS -X GET "${CLICKHOUSE_URL}&max_rows_to_read=10000&default_format=PrettySpaceNoEscapes" -d "SELECT name, value, changed FROM system.settings WHERE name IN ('readonly','max_rows_to_read')"


# ============================================================
# 1. QUERY с телом SELECT — базовый сценарий
# ============================================================
echo "--- 1. simple SELECT via QUERY ---"
${CLICKHOUSE_CURL} -sS -X QUERY \
    -H "Content-Type: text/plain" \
    -d "SELECT 1" \
    "${CLICKHOUSE_URL}" | grep -q "^1$" && echo "OK: select 1"

# ============================================================
# 2. QUERY с запросом в URL-параметре query (без тела)
# ============================================================
echo "--- 2. query in URL parameter ---"
${CLICKHOUSE_CURL} -sS -X QUERY \
    "${CLICKHOUSE_URL}/&query=SELECT%202" | grep -q "HTTP_LENGTH_REQUIRED" && echo "OK: url param"

# ============================================================
# 3. QUERY с INSERT — должен быть запрещён (readonly)
#    RFC 10008: QUERY safe, поэтому модификация данных не разрешена.
# ============================================================
echo "--- 3. INSERT via QUERY must fail (readonly) ---"
${CLICKHOUSE_CURL} -sS -X QUERY \
    -d "CREATE TABLE test_query_sh (x UInt8) ENGINE = Memory" \
    "${CLICKHOUSE_URL}" 2>&1 | grep -q "READONLY" && echo "OK: readonly enforced"

# ============================================================
# 4. Сравнение результата QUERY и POST для одинакового SELECT
# ============================================================
echo "--- 4. QUERY result equals POST result ---"
POST_RESULT=$(${CLICKHOUSE_CURL} -sS -X POST \
    -d "SELECT number FROM numbers(3)" \
    "${CLICKHOUSE_URL}")
QUERY_RESULT=$(${CLICKHOUSE_CURL} -sS -X QUERY \
    -H "Content-Type: text/plain" \
    -d "SELECT number FROM numbers(3)" \
    "${CLICKHOUSE_URL}")
[ "$POST_RESULT" = "$QUERY_RESULT" ] && echo "OK: post vs query"

# ============================================================
# 5. QUERY с chunked transfer encoding
# ============================================================
echo "--- 5. chunked QUERY ---"
printf "SELECT 5" | ${CLICKHOUSE_CURL} -sS -X QUERY \
    -H "Transfer-Encoding: chunked" \
    --data-binary @- \
    "${CLICKHOUSE_URL}" | grep -q "^5$" && echo "OK: chunked"

# # ============================================================
# # 6. QUERY без Content-Type — должен вернуть 4xx (RFC 10008, Section 2)
# # ============================================================
# echo "--- 6. missing Content-Type must fail ---"
# HTTP_CODE=$(${CLICKHOUSE_CURL} -sS -o /dev/null -w "%{http_code}" -X QUERY \
#     --data-binary "SELECT 1" \
#     "${CLICKHOUSE_URL}")
# [ "$HTTP_CODE" -ge 400 ] && [ "$HTTP_CODE" -lt 500 ] && echo "OK: 4xx for missing Content-Type"

# # ============================================================
# # 7. QUERY с неподдерживаемым Content-Type — 415 (RFC 10008, Section 2.1)
# # ============================================================
# echo "--- 7. unsupported Content-Type must fail (415) ---"
# HTTP_CODE=$(${CLICKHOUSE_CURL} -sS -o /dev/null -w "%{http_code}" -X QUERY \
#     -H "Content-Type: application/x-nonexistent" \
#     --data-binary "SELECT 1" \
#     "${CLICKHOUSE_URL}")
# [ "$HTTP_CODE" -eq 415 ] && echo "OK: 415 for unsupported Content-Type"

# ============================================================
# 8. QUERY с X-ClickHouse-Format — заголовки должны применяться
# ============================================================
echo "--- 8. QUERY with X-ClickHouse-Format ---"
${CLICKHOUSE_CURL} -sS -X QUERY \
    -H "Content-Type: text/plain" \
    -H "X-ClickHouse-Format: JSONEachRow" \
    -d "SELECT 42 AS x" \
    "${CLICKHOUSE_URL}" | grep -q '"x":42' && echo "OK: headers applied"

# ============================================================
# 9. QUERY с ошибкой в запросе — должен вернуть 500
# ============================================================
echo "--- 9. QUERY with SQL error ---"
${CLICKHOUSE_CURL} -sS -X QUERY \
    -H "Content-Type: text/plain" \
    -d "SELECT * FROM nonexistent_table_xyz" \
    "${CLICKHOUSE_URL}" 2>&1 | grep -q "UNKNOWN_TABLE" && echo "OK: error propagated"

# ============================================================
# 10. QUERY через http_handlers с фильтром methods=QUERY
#     (если у вас настроен кастомный handler с methods=QUERY)
# ============================================================
# Этот тест требует конфигурации http_handlers, поэтому опционален.
# echo "--- 10. custom handler with methods=QUERY ---"
# ...

echo "All QUERY method tests completed."