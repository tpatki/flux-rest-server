#!/bin/sh

test_description='Test GET /api/v1/jobs/<id>/state'

. $(dirname $0)/sharness.sh

test_under_flux 1

REST_SOCKET="$(flux getattr rundir)/rest"
CURL="curl --unix-socket ${REST_SOCKET}"

# Same helper as t1000-basic.t/t1002-job-submit.t: start the server in the
# background, return only once it is responding to requests.
start_server() {
	local tries=50

	flux exec -r 0 --bg flux rest-server --verbose || return 1

	while test $tries -gt 0; do
		$CURL -sf http://localhost/api/v1/ && return 0
		tries=$(($tries-1))
		sleep 0.1
	done
	return 1
}

test_expect_success 'start flux-rest-server' '
	start_server
'

test_expect_success 'state of a running job has no result yet' '
	jobid=$(flux submit sleep 300) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	$CURL -s -o state.out -w "%{http_code}" \
	    http://localhost/api/v1/jobs/$jobid/state >state.code &&
	test "$(cat state.code)" = "200" &&
	jq -e ".id" state.out &&
	test "$(jq -r .state state.out)" = "RUN" &&
	! jq -e ".result" state.out >/dev/null &&
	flux cancel $jobid
'

# Regression guard: F58 job ids contain a real Unicode character (the
# "\u0192" glyph), which is not valid in a raw URL. An HTTP client will
# percent-encode it, and the server must decode the path before parsing the
# id out of it -- otherwise this specific, most-common job id form breaks.
test_expect_success 'state works with the F58 job id form in the URL' '
	jobid=$(flux submit true) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s -o f58.out -w "%{http_code}" \
	    http://localhost/api/v1/jobs/$jobid/state >f58.code &&
	test "$(cat f58.code)" = "200" &&
	test "$(jq -r .state f58.out)" = "INACTIVE" &&
	test "$(jq -r .result f58.out)" = "COMPLETED"
'

test_expect_success 'result appears once state is INACTIVE' '
	jobid=$(flux submit false) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s http://localhost/api/v1/jobs/$jobid/state >failed.out &&
	test "$(jq -r .state failed.out)" = "INACTIVE" &&
	test "$(jq -r .result failed.out)" = "FAILED"
'

test_expect_success 'nonexistent job returns 404' '
	$CURL -s -o missing.out -w "%{http_code}" \
	    http://localhost/api/v1/jobs/999999999999/state >missing.code &&
	test "$(cat missing.code)" = "404"
'

test_expect_success 'malformed job id returns 400' '
	$CURL -s -o badid.out -w "%{http_code}" \
	    http://localhost/api/v1/jobs/not-a-real-id/state >badid.code &&
	test "$(cat badid.code)" = "400"
'

test_expect_success 'unrelated existing routes still work' '
	$CURL -s -o health.out -w "%{http_code}" \
	    http://localhost/api/v1/health >health.code &&
	test "$(cat health.code)" = "200" &&
	test_must_fail $CURL -f http://localhost/api/v1/nonexistent 2>unknown.err &&
	grep 404 unknown.err
'

test_done
