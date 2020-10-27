#!/bin/bash

SCRIPT_DIR=$(readlink -f `dirname "${BASH_SOURCE[0]}"`)

# If the NAMESPACE env var is set and the namespace
# doesn't exist, try to create it
if [ -n ${NAMESPACE:-} ]; then
    set +e
    oc get namespace $NAMESPACE
    if [ "$?" -ne 0 ]; then
        oc create namespace $NAMESPACE
    fi
    set -e
fi

function help() {
    echo "usage: setup.sh [-d|-D] [-pto] FILE"
    echo
    echo "Required:"
    echo "  FILE     a file of 'operatorname channel github' space-separated triplets, one per line"
    echo "           Check the README.md for more information."
    echo
    echo "Options:"
    echo
    echo "  -p       command will affect projects"
    echo "  -t       command will affect test subdirectories"
    echo "  -o       command will affect operators"
    echo
    echo "   The default behavior without any of the above options is '-pto'. If any of the"
    echo "   three options are specified, then only those specified will be set"
    echo
    echo "  -d       delete and recreate projects and operators, mutually exclusive with -D."
    echo "  -D       delete projects and operators, mutually exclusive with -d. Also skips git clone."
}

function delete_operator() {
    local namespace
    if [ "$2" == "true" ]; then
	# we installed this globally in openshift-operators
        namespace=openshift-operators
    else
	# If there's no project, there can't be an operator there
	namespace=$(find_project $1)
	if [ "$namespace" == "" ]; then
	    echo Operator $1 not found, nothing to delete
	    return 0
	fi
    fi
    set +e
    csv=$(oc get subscription -l peak.test.subscription=$1 -n $namespace -o=jsonpath="{.items[0].status.currentCSV}" 2>/dev/null)
    if [ "$?" -eq 0 ]; then
	echo Attempting to uninstall operator $1
        oc delete subscription -l peak.test.subscription=$1 -n $namespace
        oc delete clusterserviceversion $csv -n $namespace
	if [ "$2" == "false" ]; then
	    oc delete operatorgroup -l peak.test.operatorgroup=$1 -n $namespace
	fi
    else
	echo Operator $1 not found, nothing to delete
    fi
    set -e
}

function handleproj() {
    if [ "$delete" == "true" ]; then
        del_project $1
    elif [ "$recreate" == "true" ]; then
        clean_project $1
    else
	make_project $1
    fi
}

function getmanifest() {
    installMode=""
    set +e
    oc get packagemanifest $1 &> /dev/null
    manifest_present="$?"
    if [ "$manifest_present" -eq 0 ]; then
        installMode=$(oc get packagemanifest $1 -o=jsonpath="{.status.channels[?(@.name==\"$2\")].currentCSVDesc.installModes[?(@.type==\"AllNamespaces\")].supported}")
    fi
    set -e
}

function installop() {
    # $1 operator name
    # $2 channel

    # Note that in the case of an operator in a single namespace,
    # the operator group and subscription will be created here.
    if [ "$manifest_present" -ne 0 ]; then
        echo "operator manifest not present for $1, skipping install"
        return 0
    fi

    # subscription namespace
    local subsns

    # testproj is based on the operator name with a random string,
    # we'll use it to name subscriptions etc too
    local testproj
    testproj=$(find_project $1)

    # Look up the specified channel and find the catalog source
    csource=$(oc get packagemanifest $1 -o=jsonpath="{.status.catalogSource}")

    # Look up the specified channel and find the catalog source namespace
    csourcens=$(oc get packagemanifest $1 -o=jsonpath="{.status.catalogSourceNamespace}")

    set +e
    if [ "$installMode" == "true" ]; then
        echo "install $1 in namespace openshift-operators"
        subsns=openshift-operators

	# For global operators we're just using testproj for a name, so make
	# one if we have not created the project
        if [ "$testproj" == "" ]; then
	    testproj=$(random_name $1)
	fi
    else
	# make sure project exists since we can decouple project and operator creation
        if [ "$testproj" == "" ]; then
	    echo "project for $1 does not exist, skipping operator install"
	    return 0
	fi

        echo "install $1 in namespace $testproj"
        subsns=$testproj

        # in this case we need to make an operator group in the new project
        cat <<- EOF | oc create -f -
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: "$testproj"
	  namespace: "$subsns"
	  labels:
	     peak.test.operatorgroup: $1
	spec:
	  targetNamespaces:
	  - "$testproj"
	EOF
    fi

    # create a subscription object
    cat <<- EOF | oc create -f -
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: $testproj
	  namespace: $subsns
	  labels:
	    peak.test.subscription: $1
	spec:
	  channel: $2
	  name: $1
	  source: $csource
	  sourceNamespace: $csourcens
	EOF
    set -e

    # wait for install
    for _ in $(seq 1 30); do
        csv=$(oc -n "$subsns" get subscription "$testproj" -o jsonpath='{.status.installedCSV}' || true)
        if [[ -n "$csv" ]]; then
            if [[ "$(oc -n "$subsns" get csv "$csv" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
                echo "$1 installed"
                return
            fi
        fi
        sleep 10
    done
    echo "$1 install failed"
}

function addtestdir() {
    if [ ! -d $SCRIPT_DIR/operator-tests/$1 ]; then
	echo Cloning test repository for $1
        if [ -n "$3" ]; then
           echo git clone $2 --branch $3 $SCRIPT_DIR/operator-tests/$1
           git clone $2 --branch $3 $SCRIPT_DIR/operator-tests/$1
        else
           echo git clone $2 $SCRIPT_DIR/operator-tests/$1
           git clone $2 $SCRIPT_DIR/operator-tests/$1
        fi
    else
	echo Test repository exists for $1, skipping clone
    fi
}

delete=false
recreate=false

everything=true
projects=false
operators=false
tests=false
manifest_present=-1
installMode=

while getopts Ddhpto option; do
    case $option in
        D)
            delete=true
            ;;
        d)
            recreate=true
            ;;
        h)
            help
            exit 0
            ;;
	p)
	    everything=false
	    projects=true
	    ;;
	t)
	    everything=false
	    tests=true
	    ;;
	o)
	    everything=false
	    operators=true
	    ;;
        *)
           ;;
    esac
done

# The last argument is the name of the operator file
shift $((OPTIND-1))
if [ "$#" -lt 1 ]; then
    help
    exit 0
fi

if [ "$delete" == "true" -a "$recreate" == "true" ]; then
    echo "Options -d and -D are mutually exclusive"
    help
    exit -1
fi

if [ "$everything" == "true" ]; then
    tests=true
    projects=true
    operators=true
fi

# Track whether we have a valid oc login
source $SCRIPT_DIR/util
check_ocp
check_whoami

# We have to have a login for projects
if [ "$projects" == "true" ]; then
    if [ "$OCP" -ne 0 ]; then
        echo "No active openshift login, can't set up projects, exiting."
        exit 0
    fi
fi

# We have to have at least a basic config to install operators
if [ "$operators" == "true" ]; then
    if [ "$WHOAMI" -ne 0 ] && [ "$OCP" -ne 0 ]; then
        echo "No valid kubeconfig or login, can't set up operators, exiting."
        exit 0
    fi
fi

while IFS= read -r line
do
    vals=($line)

    echo ++++++++++++++ Processing entry for operator "${vals[0]}" ++++++++++++++

    if [ "${#vals[@]}" -lt 2 ]; then
        echo "Invalid tuple '${vals[@]}' in $1, skipping"
        continue
    fi

    if [ "$operators" == "true" ]; then
	getmanifest ${vals[@]:0:2}
    fi

    # Uninstall the operator in the delete or recreate case
    if [ "$delete" == "true" -o "$recreate" == "true" ] && [ "$manifest_present" -eq 0 -a "$operators" == "true" ]; then
	delete_operator ${vals[0]} $installMode
    fi

    # Use vals[0] for the project name because that's the base and we may not have made it yet
    if [ "$projects" == "true" ]; then
        handleproj ${vals[0]} $installMode
    fi

    # install operator if we're (re)creating
    if [ "$operators" == "true" -a "$delete" == "false" ]; then
        installop ${vals[@]:0:2}
    fi

    # clone a specific repository for tests if one is listed
    if [ "$tests" == "true" -a "$delete" == "false" ]; then
        branch=""
        if [ "${#vals[@]}" -gt 2 ]; then
            if [ "${#vals[@]}" -gt 3 ]; then
                branch=${vals[3]}
            fi
            addtestdir ${vals[0]} ${vals[2]} $branch
        fi
    fi
done < "$1"
