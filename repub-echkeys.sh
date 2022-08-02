#!/bin/bash

# set -x

# Copyright (C) 2022 Stephen Farrell, stephen.farrell@cs.tcd.ie
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# Update the ECH keys in DNS for some web servers. This part is run on the
# zonefactory from a cron job and pulls updated keys from a .well-known, 
# checks those work ok, and if so re-publishes the the ECH keys

# This works as per draft-ietf-tls-wkech

# Caution: don't mess with output format here unless you make
# equivalent changes in (your equivalent of) regen-echkeys.sh - both scripts 
# should deal with the same thing

# variables/settings

# Our goal here is to ensure that we only re-publish ECHConfigList
# information that actually works.
# Our ECH-enabled OpenSSL build lives here - that's needed for validating keys
: ${OSSL:=$HOME/code/openssl}
export LD_LIBRARY_PATH=$OSSL

# Top of ECH key file directories
: ${ECHTOP:=$HOME/ech}

# BACKENDS can be >1, use a space-separated list
: ${BACKENDS:="draft-13.esni.defo.ie"}

# This script only works for one FRONTEND, generalise if you wish:-)
: ${FRONTEND:="cover.defo.ie"}

# A timeout in case accessing the FRONTEND .well-known is gonna
# fail - this is 10 seconds
: ${CURLTIMEOUT:="10s"}

# check that the that OpenSSL build is built
if [ ! -f $OSSL/apps/openssl ]
then
    echo "OpenSSL not built - exiting"
    exit 1
fi

# check that the echcli.sh script is present in that OpenSSL build
if [ ! -f $OSSL/esnistuff/echcli.sh ]
then
    echo "OpenSSL not built with ECH - exiting"
    exit 2
fi

# We need a directory to store long-ish term values, just so we can check
# if they've changed or not
FEDIR="$ECHTOP/$FRONTEND"
if [ ! -d $FEDIR ]
then
    mkdir -p $FEDIR
fi

# a tmp directory to accumulate the inbound new files, before
# they've been validated
FETMP="$FEDIR/tmp"
if [ ! -d $FETMP ]
then
    mkdir -p $FETMP
fi

# Set to "yes" to run a local test for dev purposes
DOTEST="no"

function whenisitagain()
{
    /bin/date -u +%Y%m%d-%H%M%S
}

# split an ECFConfigList into a set of "singleton" ECHConfigList's
# so we can test each key individually
# example usage input is base64 encoded ECHconfigList
#   list=$echconfiglist
#   splitlists=`splitlist`
# result is a space sep list of single-entry base64 encoded ECHConfigLists
# this assumes encoding is valid and does no error checking, however the
# output will be fed into s_client and then parsed so we'll only publish
# values that, in the end, work. And bash will just return empty strings
# if there's an internal length out-of-bounds error
function splitlist()
{
    olist=""
    ah_echlist=`echo $list | base64 -d | xxd -ps -c 200 | tr -d '\n'`
    ah_olen=${ah_echlist:0:4}
    olen=$((16#$ah_olen))
    remaining=$olen
    top=${ah_echlist:4}
    while ((remaining>0))
    do
        ah_nlen=${top:4:4}
        nlen=$((16#$ah_nlen))
        nlen=$((nlen+4))
        ah_nlen=$((nlen*2))
        ah_thislen="`printf  "%04x" $((nlen))`"
        thisone=${top:0:ah_nlen}
        b64thisone=`echo $ah_thislen$thisone | xxd -p -r | base64 -w 0`
        olist="$olist $b64thisone"
        remaining=$((remaining-nlen))
        top=${top:ah_nlen}
    done
    echo -e "$olist"
}

# given a host, a base64 ECHConfigList a TTL and an optional port
# (default 443), use the bind9 nsupdate tool to publish that value
# in the DNS, we return the return value from the nsupdate tool,
# which is 0 for success and non-zero otherwise
function donsupdate()
{
    host=$1
    echval=$2
    ttl=$3
    # port can be empty for 443 so has to be last
    port=$4

    if [[ "$port" == "443" || "$port" == "" ]]
    then
        nscmd="update delete $host HTTPS\n
               update add $host $ttl HTTPS 1 . ech=$echval\n
               send\n
               quit"
    else
        oname="_$port._https.$host"
        nscmd="update delete $oname HTTPS\n
               update add $oname $ttl HTTPS 1 . ech=$echval\n
               send\n
               quit"
    fi
    echo -e $nscmd | sudo su -c "nsupdate -l >/dev/null 2>&1; echo $?"
}

NOW=$(whenisitagain)

echo "=========================================="
echo "Running $0 at $NOW"

function usage()
{
    echo "$0 [-ht] - check for and, if good, publish new ECHConfigList "\
                "values for $BACKENDS"
    echo "  -h means print this"
    echo "  -t means do a local test (of this script, for dev purposes only)"

    echo ""
    echo "The following should work:"
    echo "    $0 "
    exit 99
}

# options may be followed by one colon to indicate they have a required argument
if ! options=$(/usr/bin/getopt -s bash -o h,t -l help,test -- "$@")
then
    # something went wrong, getopt will put out an error message for us
    exit 98
fi
#echo "|$options|"
eval set -- "$options"
while [ $# -gt 0 ]
do
    case "$1" in
        -h|--help) usage;;
        -t|--test) DOTEST="yes";;
        (--) shift; break;;
        (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 97;;
        (*)  break;;
    esac
    shift
done


# pull URL content, if all same as before, exit
# check new ECH values all work, if not discard
# for those that work: re-publish

echo "Checking for ECHConfigList values for $BACKENDS at $FRONTEND"
todos=""
for back in $BACKENDS
do
    # pull URL, and see if that has new stuff ...
    TMPF=`mktemp /tmp/ech-XXXX`
    path=".well-known/ech/$back.json"
    URL="https://$FRONTEND/$path"
    # grab .well-known stuff
    timeout $CURLTIMEOUT curl -s $URL -o $TMPF
    tres=$?
    if [[ "$tres" == "124" ]]
    then
        # timeout returns 124 if it timed out, or else the
        # result from curl otherwise
        echo "Timed out after $CURLTIMEOUT waiting for $FRONTEND"
        exit 2
    fi
    if [ ! -s $TMPF ]
    then
        echo "Can't get content from $URL - skipping $back"
        rm -f $TMPF
    else
        newcontent=""
        if [ ! -f  $FEDIR/$back.json ]
        then
            newcontent="yes"
        else
            newcontent=`diff -q $TMPF $FEDIR/$back.json`
        fi
        if [[ "$newcontent" != "" ]]
        then
            nctype=`file $TMPF`
            if [[ "$nctype" != "$TMPF: JSON data" ]]
            then
                echo "$back bad file type"
                rm -f $TMPF
            else
                echo "New content for $back, something to do"
                todos="$todos $back"
                mv $TMPF $FETMP/$back.json
            fi
        else
            # content was same, ditch TMPF
            rm -f $TMPF
        fi
    fi
done

for backend in $todos
do
    # Remember if we did or didn't publish something - if we did, then
    # we'll "promote" the JSON file from the tmp dir to the longer term
    # one. We do that even if some of the JSON file entries don't work
    # on the basis that it's correct to publish keys that work and if
    # the FRONTEND fixes broken things, then we'll pick up on that and
    # publish.
    publishedsomething="false"
    #echo "Trying ECH to $backend"
    entries=`cat $FETMP/$backend.json | jq length`
    #echo "entries: $entries"
    if [[ "$entries" == "" ]]
    then
        continue
    fi
    for ((index=0;index!=$entries;index++))
    do
        echo "$backend Array element: $((index+1)) of $entries"
        arrent=`cat $FETMP/$backend.json | jq .[$index]`
        ports=`echo $arrent | jq -c .ports \
            | sed -e 's/,/ /g' | sed -e 's/\[//' | sed -e 's/]//'`
        #echo "ports: $ports"
        list=`echo $arrent | jq .echconfiglist | sed -e 's/\"//g'`
        splitlists=`splitlist`
        #echo "splitlists: $splitlists"
        listarr=( $splitlists )
        listcount=${#listarr[@]}
        desired_ttl=`echo $arrent | jq '.["desired-ttl"]'`
        #echo "desired_ttl: $desired_ttl"
        # now test for each port and ECHConfig within the ECHConfigList
        echerror="false"
        echworked="false"
        for port in $ports
        do
            # first test entire list then each element
            $OSSL/esnistuff/echcli.sh -P $list -H $backend -c $FRONTEND \
                -s $FRONTEND -p $port >/dev/null 2>&1
            res=$?
            #echo "Test result is $res"
            if [[ "$res" != "0" ]]
            then
                echo "ECH list error for $backend $port"
                echerror="true"
            else 
                echo "ECH list fine for $backend $port"
                echworked="true"
            fi
            # could speed up this if full list is singleton but better 
            # to run the code for now...
            if [[ "$echworked" == "true" ]]
            then
                # only check singletons if overall was ok
                snum=1
                for singletonlist in $splitlists
                do
                    $OSSL/esnistuff/echcli.sh -P $singletonlist -H $backend \
                        -c $FRONTEND -s $FRONTEND -p $port >/dev/null 2>&1
                    res=$?
                    #echo "Test result is $res"
                    if [[ "$res" != "0" ]]
                    then
                        echo "ECH single error at $backend $port $singletonlist"
                        echerror="true"
                    else 
                        echo "ECH single ($snum/$listcount) fine at $backend $port"
                        echworked="true"
                    fi
                    snum=$((snum+1))
                done
            fi
        done
        # ignore ECH errors for a test domain so we can check publication
        if [[ "$backend" == "foo.ie" ]]
        then
            echerror="false"
            echworked="true"
        fi
        if [ "$echerror" == "false" ]  && [ "$echworked" == "true" ]
        then
            # success... all ports ok so bank that one...
            for port in $ports
            do
                if [[ "$DOTEST" == "no" ]]
                then
                    #echo "Will try publish for $backend/$port"
                    sleep 3
                    nres=`donsupdate $backend $list $desired_ttl $port`
                    if [[ "$nres" == "0" ]]
                    then 
                        echo "Published for $backend/$port"
                        publishedsomething="true"
                    else
                        echo "Failure ($nres) in publishing for $backend/$port"
                    fi
                else
                    echo "Just testing so won't add $backend/$port"
                    publishedsomething="true"
                fi
            done
        else
            echo "Won't try publish $backend/$ports"
        fi
    done
    if [[ "$publishedsomething" == "true" ]]
    then
        # we're accepting this one, so we something worked from here
        # so save this file for comparison with next time we get run
        mv $FETMP/$backend.json $FEDIR/$backend.json
    else
        # nothing worked, so clean up
        rm $FETMP/$backend.json
    fi
done

# clean up TMP dir, it should be empty, if not the error will improve us:-)
rmdir $FETMP

# exit returning "0" for "I did stuff that seemed to work"
exit 0
