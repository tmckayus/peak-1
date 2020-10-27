#!/bin/bash
STARTTIME=$(date +%s)
output=
debug=false
makeproj=true
errfile=
verbose=false
interactive=false

# If the NAMESPACE env var is set and the namespace
# doesn't exist, try to create it
if [ -n ${NAMESPACE:-} ]; then
    set +e
    echo "namespace is $NAMESPACE"
    oc get namespace $NAMESPACE
    if [ "$?" -ne 0 ]; then
        oc create namespace $NAMESPACE
    fi
    set -e
fi

SCRIPT_DIR=$(readlink -f `dirname "${BASH_SOURCE[0]}"`)
TEST_DIR=$SCRIPT_DIR/operator-tests
export TEST_DIR

function help() {
    echo "usage: run.sh [-h] [-f FILE] [regexp]"
    echo
    echo "Run tests in subdirectories under $TEST_DIR."
    echo
    echo "If there is a current openshift login, set the project to the name of each subdirectory"
    echo "under $TEST_DIR before running tests in that subdirectory unless -p is set."
    echo
    echo "Options:"
    echo "  -h       Print this help message"
    echo "  -f FILE  Redirect output to FILE rather than console, includes errors if -e is not set"
    echo "  -e FILE  Record errors to FILE rather than console or log file"
    echo "  -v       Verbose, include detailed logs for passing tests (default is detailed logs only for failed tests)."
    echo "  -i       Interactive, send raw logs directly to the console or FILE if -f is set, -e and -v have no effect."
    echo "           This is useful for test development since realtime logs are printed instead of summary logs."
    echo "  -d       Debug, set -x (large amount of output)"
    echo "  -p       Do not create a new project per test directory"
    echo
    echo "Optional arguments:"
    echo "  regexp   Only run test files whose absolute path matches regexp"
    echo
}

while getopts ivdphf:e: option; do
    case $option in
        h)
            help
            exit 0
            ;;
	f)
	    output=$OPTARG
	    ;;
	e)
	    errfile=$OPTARG
	    ;;
        d)
            debug=true
            ;;
        p)
            makeproj=false
            ;;
	v)
	    verbose=true
	    ;;
	i)
	    interactive=true
	    ;;
        *)
            ;;
    esac
done
shift $((OPTIND-1))

# Redirect stdout/stderr to output file if set
if [ -n "$output" ]; then
    exec > ${output}
    exec 2>&1
fi

# Truncate the error log file if set
if [ -n "$errfile" ]; then
    : > $errfile
fi

if [ "$debug" == "true" ]; then
    set -x
fi

# Sourcing common will source test/lib/init.sh
source $TEST_DIR/common
source $SCRIPT_DIR/util

# Track whether we have a valid oc login
check_ocp
check_whoami

os::util::environment::setup_time_vars

function handle_term {
    echo "$0" received termination signal
    local cnt
    local killed=1
    if [ -n "$PID" ]; then
        kill -TERM $PID
        for cnt in {1..10}
        do
            kill -0 $PID >/dev/null 2>&1
            if [ "$?" -ne 0 ]; then
                killed=0
                break
            else
                sleep 1
            fi
        done
        if [ "$killed" -ne 0 ]; then
            kill -9 $PID
        fi
        wait $PID
        exit $?
    fi
    exit 1
}

function cleanup()
{
    out=$?
    set +e

    os::test::junit::reconcile_output

    ENDTIME=$(date +%s); echo "$0 took $(($ENDTIME - $STARTTIME)) seconds"
    os::log::info "Exiting with ${out}"
    exit $out
}

trap "handle_term" INT TERM
trap "cleanup" EXIT

function find_tests() {
    local test_regex="${2}"
    local full_test_list=()
    local selected_tests=()

    full_test_list=($(find "${1}" -maxdepth 1 -name '*.sh'))
    if [ "${#full_test_list[@]}" -eq 0 ]; then
        return 0
    fi    
    for test in "${full_test_list[@]}"; do
    	test_rel_path=${test#${TEST_DIR}/}
        if grep -q -E "${test_regex}" <<< "${test_rel_path}"; then
            selected_tests+=( "${test}" )
        fi
    done

    if [ "${#selected_tests[@]}" -eq 0 ]; then
        return 1
    else
        echo "${selected_tests[@]}"
    fi
}

if [ "$makeproj" == "true" ]; then
    set_curr_project
fi

logfile=$(mktemp)
failed_list=""
dirs=($(find "${TEST_DIR}" -mindepth 1 -type d -not -path "./resources*"))
for dir in "${dirs[@]}"; do

    # Get the list of test files in the current directory
    set +e
    output=$(find_tests $dir ${1:-.*})
    res=$?
    set -e
    if [ "$res" -ne 0 ]; then
        echo $output
        continue
    else
        output=$(echo $output | xargs -n1 | sort)
    fi

    # Turn the list of tests into an array and check the length, skip if zero
    tests=($(echo "$output"))
    if [ "${#tests[@]}" -eq 0 ]; then
        continue
    fi

    currproj=
    if [ "$makeproj" == "true" ]; then
        currproj=$(go_to_project $(basename $dir))
        # currproj is just a string for the summary line
        currproj=" ($currproj)"
    fi

    for test in "${tests[@]}"; do
        shortname=${test#${TEST_DIR}/}
        if [ "$interactive" == "true" ]; then
            ${test} &
        else
            ${test} > $logfile 2 >&1 &
        fi
        PID=$!
        set +e
        wait $PID
        res=$?
        set -e
        if [ "$res" -ne 0 ]; then
            failed_list=$failed_list'\n\t'$shortname

	    # If errfile is set, write failure log there, otherwise use stdout
            if [ -n "$errfile" ]; then
                os::text::print_red "failed: $shortname$currproj" >> $errfile
                cat $logfile >> $errfile
	    else
                os::text::print_red "failed: $shortname$currproj"
                cat $logfile
            fi
        else
	    os::text::print_green "passed: $shortname$currproj"
	    if [ "$verbose" == "true" ]; then
		cat $logfile
	    fi
        fi
    done
done

if [ "$makeproj" == "true" ]; then
    restore_curr_project
fi

if [ -n "$failed_list" ]; then
    os::text::print_red "One or more tests failed:"
    echo -e $failed_list'\n'
    exit 1
fi
rm $logfile
