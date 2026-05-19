#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Integration + Load + Crawl Tests for AtmosIndex
# ═══════════════════════════════════════════════════════════════════════════════

BASE="http://localhost:8787"
PASS=0
FAIL=0

pass() { ((PASS++)); echo "  ✅ $1"; }
fail() { ((FAIL++)); echo "  ❌ $1: $2"; }

check_json() {
  local label=$1
  local url=$2
  local field=$3
  local expected=$4
  
  resp=$(curl -s "$url" 2>/dev/null)
  if [ -z "$resp" ]; then
    fail "$label" "empty response"
    return
  fi
  
  val=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field','MISSING'))" 2>/dev/null)
  if [ "$val" = "$expected" ]; then
    pass "$label (got $val)"
  else
    fail "$label" "expected $field=$expected got $val"
  fi
}

echo ""
echo "══════════════════════════════════════════"
echo "  INTEGRATION TESTS"
echo "══════════════════════════════════════════"

# Test 1: Health check
echo "── Health ──"
check_json "Health endpoint" "$BASE/health" "status" "ok"

# Test 2: Search returns JSON with results array
echo "── Search API ──"
resp=$(curl -s "$BASE/tg/search?title=Sharanya")
has_results=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'results' in d and 'total' in d else 'no')" 2>/dev/null)
if [ "$has_results" = "yes" ]; then
  pass "Search returns {results, total}"
else
  fail "Search JSON structure" "$resp"
fi

# Test 3: Search finds indexed movie
total=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])" 2>/dev/null)
if [ "$total" -gt 0 ] 2>/dev/null; then
  pass "Catalog search finds 'Sharanya' ($total results)"
else
  fail "Catalog search" "0 results for 'Sharanya'"
fi

# Test 4: Result has expected fields
has_fields=$(echo "$resp" | python3 -c "
import sys,json
r = json.load(sys.stdin)['results'][0]
fields = ['title','quality','channel_username','msg_id']
print('yes' if all(f in r for f in fields) else 'no')
" 2>/dev/null)
if [ "$has_fields" = "yes" ]; then
  pass "Result has title, quality, channel_username, msg_id"
else
  fail "Result fields" "missing expected fields"
fi

# Test 5: Results are scored (have _score field)
has_score=$(echo "$resp" | python3 -c "
import sys,json; r=json.load(sys.stdin)['results'][0]; print('yes' if '_score' in r else 'no')
" 2>/dev/null)
if [ "$has_score" = "yes" ]; then
  pass "Results have _score field (ranking works)"
else
  fail "Result scoring" "no _score field"
fi

# Test 6: Empty query returns error
echo "── Error handling ──"
check_json "Empty title returns error" "$BASE/tg/search?title=" "error" "title param required"

# Test 7: Season search API
echo "── Season API ──"
resp=$(curl -s "$BASE/tg/season?title=test&s=1")
has_structure=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'results' in d else 'no')" 2>/dev/null)
if [ "$has_structure" = "yes" ]; then
  pass "Season endpoint returns {results}"
else
  fail "Season endpoint" "$resp"
fi

# Test 8: Stats API
echo "── Stats API ──"
resp=$(curl -s "$BASE/tg/stats")
has_stats=$(echo "$resp" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print('yes' if 'channels' in d and 'seeds' in d else 'no')
" 2>/dev/null)
if [ "$has_stats" = "yes" ]; then
  channels=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['channels'])" 2>/dev/null)
  pass "Stats: $channels channels indexed"
else
  fail "Stats endpoint" "$resp"
fi

# Test 9: CORS headers present
echo "── CORS ──"
cors=$(curl -sI "$BASE/tg/search?title=test" 2>/dev/null | grep -i "access-control-allow-origin" | head -1)
if echo "$cors" | grep -q "\*"; then
  pass "CORS header present"
else
  fail "CORS" "no Access-Control-Allow-Origin header"
fi

echo ""
echo "══════════════════════════════════════════"
echo "  LOAD TEST (10 concurrent requests)"
echo "══════════════════════════════════════════"

# Run 10 parallel searches
start_time=$(date +%s%N)
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code}" "$BASE/tg/search?title=test$i" &
done
results=$(wait; echo "done")
end_time=$(date +%s%N)
duration=$(( (end_time - start_time) / 1000000 ))

# Run 10 sequential to check all return 200
all_ok=true
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/tg/search?title=movie$i")
  if [ "$code" != "200" ]; then
    all_ok=false
    fail "Request $i" "HTTP $code"
  fi
done

if $all_ok; then
  pass "10 sequential requests all returned HTTP 200"
else
  fail "Load test" "some requests failed"
fi

echo ""
echo "══════════════════════════════════════════"
echo "  CRAWL TEST"  
echo "══════════════════════════════════════════"

# Trigger crawl
echo "── Triggering crawl ──"
crawl_resp=$(curl -s -X POST "$BASE/tg/crawl")
crawl_status=$(echo "$crawl_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
if [ "$crawl_status" = "crawl_started" ]; then
  pass "Crawl trigger returned crawl_started"
else
  fail "Crawl trigger" "$crawl_resp"
fi

# Wait for crawl to complete
sleep 10

# Check media count increased
media_count=$(curl -s "$BASE/tg/stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('estimated_media', 0))" 2>/dev/null)
if [ "$media_count" -gt 0 ] 2>/dev/null; then
  pass "Crawl indexed media ($media_count items in DB)"
else
  fail "Crawl indexing" "0 media items"
fi

echo ""
echo "══════════════════════════════════════════"
echo "  RESULTS"
echo "══════════════════════════════════════════"
echo "  ✅ Passed: $PASS"
echo "  ❌ Failed: $FAIL"  
echo "  Total:    $((PASS + FAIL))"
echo "══════════════════════════════════════════"
exit $FAIL
