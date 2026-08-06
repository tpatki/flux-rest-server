#!/bin/sh

test_description='Test POST /api/v1/jobs/<id>/cancel'

. $(dirname $0)/sharness.sh

test_under_flux 1

REST_SOCKET="$(flux getattr rundir)/rest"
CURL="curl --unix-socket ${REST_SOCKET}"

# Same helper as t1000-basic.t/t1002-job-submit.t/t1003-jobs-state.t: start
# the server in the background, return only once it is responding.
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

test_expect_success 'cancel a running job returns 202, and the job is actually canceled' '
	jobid=$(flux submit sleep 300) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	$CURL -s -o cancel.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs/$jobid/cancel >cancel.code &&
	test "$(cat cancel.code)" = "202" &&
	jq -e ".id" cancel.out &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s http://localhost/api/v1/jobs/$jobid/state >state.out &&
	test "$(jq -r .state state.out)" = "INACTIVE" &&
	test "$(jq -r .result state.out)" = "CANCELED"
'

# Regression guard: flux.job.cancel() accepts an optional reason -- confirm
# it actually reaches the real job, not just that the request succeeds.
test_expect_success 'an optional reason is passed through to the job' '
	jobid=$(flux submit sleep 300) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	$CURL -s -X POST http://localhost/api/v1/jobs/$jobid/cancel \
	    -H "Content-Type: application/json" \
	    -d "{\"reason\": \"my custom test reason\"}" &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	flux job eventlog $jobid | grep -q "my custom test reason"
'

# Regression guard: flux.job.cancel() raises the identical exception (and
# errno) for "job already inactive" and "unknown job id", distinguished
# only by message text -- confirm each maps to the intended, different
# status code, not the same one.
test_expect_success 'canceling an already-inactive job returns 409, not 404' '
	jobid=$(flux submit true) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s -o already.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs/$jobid/cancel >already.code &&
	test "$(cat already.code)" = "409"
'

test_expect_success 'canceling a nonexistent job returns 404, not 409' '
	$CURL -s -o missing.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs/999999999999/cancel >missing.code &&
	test "$(cat missing.code)" = "404"
'

test_expect_success 'malformed job id returns 400' '
	$CURL -s -o badid.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs/not-a-real-id/cancel >badid.code &&
	test "$(cat badid.code)" = "400"
'

test_expect_success 'unrelated existing routes still work' '
	$CURL -s -o submit.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs/submit \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"]}" >submit.code &&
	test "$(cat submit.code)" = "201" &&
	$CURL -s -o health.out -w "%{http_code}" \
	    http://localhost/api/v1/health >health.code &&
	test "$(cat health.code)" = "200"
'

test_done
