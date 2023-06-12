#!/bin/bash

# set -x

# Copyright (C) 2023 Stephen Farrell, stephen.farrell@cs.tcd.ie
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

# ECH keys update as per draft-ietf-tls-wkech-02
# with the addition of 'regenfreq' to the JSON
# and (so far) without support for the 'alias' option
# or the 'target' option (in the JSON)
# This is a work-in-progress, DON'T DEPEND ON THIS!!

# This script handles ECH key updating for an ECH front-end (in ECH split-mode),
# back-end (e.g. web server) or zone factory (the thing that publishes DNS RRs
# containing ECH public values).

# variables/settings, some can be overwritten from environment

# where the ECH-enabled OpenSSL is built, needed if ECH-checking is enabled
: ${OSSL:=$HOME/code/openssl}
export LD_LIBRARY_PATH=$OSSL

# script to restart or reload configuations for front/back-end
: ${BE_RESTARTER:=$HOME/code/defo-project/be_restart.sh}
: ${FE_RESTARTER:=$HOME/code/defo-project/fe_restart.sh}

# Top of ECH key file directories
: ${ECHTOP:=$HOME/.ech13}

# This is where most or all $DURATION-lived ECH keys live
# When they get to 2*$DURATION old they'll be moved to $ECHOLD
ECHDIR="$ECHTOP/echkeydir"
# Where old stuff goes
ECHOLD="$ECHDIR/old"

# Key update frequency - we publish keys for 2 x the "main"
# duration and add a new key each time and retire (as in don't 
# load to server) old keys after 3 x this duration.
# So, keys remain usable for 3 x this, and are visible to the
# Internet for 2 x this. 
# Old keys are just moved into $ECHOLD for now and are deleted
# once they're 5 x this duration old.
# We request a TTL for that the RR containing keys be half 
# this duration.
DURATION="3600" # 1 hour

# Key filename convention is "*.ech" for key files but 
# "*.pem.ech" for short-terms key files that'll be moved
# aside

# Long term key files, can be space-sep list if needed
# These won't be expired out ever, and will be added to
# the list of keys we ask be published. This is mostly
# for testing.
: ${LONGTERMKEYS:="$ECHDIR/*.ech"}
files2check="$ECHDIR/*.pem.ech"

# this is what's on our defo.ie test site
DEFPORT=443
DEFFRONTEND="cover.defo.ie"
DEFBACKENDS="defo.ie \
             draft-13.esni.defo.ie:8413 \
             draft-13.esni.defo.ie:8414 \
             draft-13.esni.defo.ie:9413 \
             draft-13.esni.defo.ie:10413 \
             draft-13.esni.defo.ie:11413 \
             draft-13.esni.defo.ie:12413 \
             draft-13.esni.defo.ie:12414"

# Our FRONTEND and BACKEND DNS names
# This script only works for one FRONTEND, generalise if you wish:-)
: ${FRONTEND:="$DEFFRONTEND"}

# BACKENDS should be a space separated list of names
: ${BACKENDS:="$DEFBACKENDS"}

# Back-end DocRoot where we make ECH info available via .well-known
: ${DOCROOT:="/var/www/html/cover"}
WESTR="origin-svcb"
WKECHDIR="$DOCROOT/.well-known/$WESTR"

# uid for writing files to DocRoot, whoever runs this script
# needs to be able to sudo to that uid
: ${WWWUSER:="www-data"}

# A timeout in case accessing the FRONTEND .well-known is gonna
# fail - believe it or not: this is 10 seconds
: ${CURLTIMEOUT:="10s"}

# role strings
FESTR="fe"
BESTR="be"
ZFSTR="zf"
ROLES="$FESTR,$BESTR"

# whether to attempt checks that ECH works before publishing
VERIFY="yes"

# whether to really try publish via bind or just test to that point
DOTEST="no"

# set this if we do someting that needs a server re-start
actiontaken="false"

# We need a directory to store long-ish term values, just so we can check
# if they've changed or not
FEDIR="$ECHTOP/$FRONTEND"
# a tmp directory to accumulate the inbound new files, before
# they've been validated
FETMP="$FEDIR/tmp"

# functions

function whenisitagain()
{
    /bin/date -u +%Y%m%d-%H%M%S
}

function fileage()
{
    echo $(($(date +%s) - $(date +%s -r "$1"))) 
}

function hostport2host()
{
    case $1 in
      *:*) host=${1%:*} port=${1##*:};;
        *) host=$1      port=$DEFPORT;;
    esac
    echo $host
}

function hostport2port()
{
    case $1 in
      *:*) host=${1%:*} port=${1##*:};;
        *) host=$1      port=$DEFPORT;;
    esac
    echo $port
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
    priority=$4
    # port can be empty for 443 so has to be last
    port=$5

    if [[ "$port" == "443" || "$port" == "" ]]
    then
        nscmd="update delete $host HTTPS\n
               update add $host $ttl HTTPS $priority . ech=$echval\n
               send\n
               quit"
    else
        oname="_$port._https.$host"
        nscmd="update delete $oname HTTPS\n
               update add $oname $ttl HTTPS $priority $host ech=$echval\n
               send\n
               quit"
    fi
    echo -e $nscmd | sudo su -c "nsupdate -l >/dev/null 2>&1; echo $?"
}

function usage()
{
    echo "$0 [-h] [-r roles] [-d duration] - generate new ECHKeys for defo.ie"
    echo "  -d specifies key update frequency in seconds (for testing really)"
    echo "  -h means print this"
    echo "  -n means to not verify that ECH is working before publishing"
    echo "  -r roles can be \"$FESTR\" or \"$FESTR,$BESTR\" or \"$ZFSTR\" (default is \"$ROLES\")"
    echo "  -t means to test $ZFSTR role up to, but not including, publication"

	echo ""
	echo "The following should work:"
	echo "    $0 "
    exit 1
}

echo "=========================================="
NOW=$(whenisitagain)
echo "Running $0 at $NOW"

# options may be followed by one colon to indicate they have a required argument
if ! options=$(/usr/bin/getopt -s bash -o d:hnr:t -l duration,help,no-verify,roles:,test -- "$@")
then
    # something went wrong, getopt will put out an error message for us
    exit 2
fi
#echo "|$options|"
eval set -- "$options"
while [ $# -gt 0 ]
do
    case "$1" in
        -h|--help) usage;;
        -d|--duration) DURATION=$2; shift;;
        -n|--no-verify) VERIFY="no";;
        -r|--roles) ROLES=$2; shift;;
        -t|--test) DOTEST="yes";;
        (--) shift; break;;
        (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 3;;
        (*)  break;;
    esac
    shift
done

# variables that can be influenced by command line options

# Various multiples/fractions of DURATION
duro2=$((DURATION/2))
dur=$DURATION
durt2=$((DURATION*2))
durt3=$((DURATION*3))
durt5=$((DURATION*5))

# sanity checks

case $ROLES in
    "$FESTR")
        ;;
    "$FESTR,$BESTR")
        ;;
    "$BESTR")
        ;;
    "$ZFSTR")
        ;;
    *)
        echo "Bad role(s): $ROLES - exiting"
        exit 4
esac

# checks for front-end role
if [[ $ROLES == *"$FESTR"* ]]
then
    # check that the that OpenSSL build is built
    if [ ! -f $OSSL/apps/openssl ]
    then
        echo "OpenSSL not built - exiting"
        exit 5
    fi
    if [ ! -f $OSSL/esnistuff/mergepems.sh ]
    then
        echo "mergepems not seen - exiting"
        exit 6
    fi
    if [ ! -d $ECHTOP ]
    then
        echo "$ECHTOP ECH key dir missing - exiting"
        exit 7
    fi
    # check that our OpenSSL build supports ECH
    $OSSL/apps/openssl ech -help >/dev/null 2>&1
    eres=$?
    if [[ "$eres" != "0" ]]
    then
        echo "OpenSSL not built with ECH - exiting"
        exit 8
    fi
fi

if [[ $ROLES == *"$BESTR"* ]]
then
    # check if we can sudo to www-user
    if [[ ! -d $DOCROOT ]]
    then
        echo "$FRONTEND - $DOCROOT missing - exiting"
        exit 9
    fi
    sudo -u $WWWUSER ls $DOCROOT
    sres=$?
    if [[ "$sres" != "0" ]]
    then
        echo "Can't sudo to $WWWUSER - exiting"
        exit 10
    fi
    wns=`which jq`
    if [[ "$wns" == "" ]]
    then
        echo "Can't see jq - exiting"
        exit 11
    fi
fi

if [[ $ROLES == $ZFSTR ]]
then
    if [ ! -f $OSSL/esnistuff/echcli.sh ]
    then
        echo "Can't see $OSSL/esnistuff/echcli.sh - exiting"
        exit 11
    fi
    if [ ! -d $FEDIR ]
    then
        mkdir -p $FEDIR
    fi
    if [ ! -d $FEDIR ]
    then
        echo "Can't see $FEDIR - exiting"
        exit 11
    fi
    if [ ! -d $FETMP ]
    then
        mkdir -p $FETMP
    fi
    if [ ! -d $FETMP ]
    then
        echo "Can't see $FETMP - exiting"
        exit 11
    fi
    # check we can run nsupdate
    wns=`which nsupdate`
    if [[ "$wns" == "" ]]
    then
        echo "Can't see nsupdate - exiting"
        exit 11
    fi
    wns=`which jq`
    if [[ "$wns" == "" ]]
    then
        echo "Can't see jq - exiting"
        exit 11
    fi
fi

# other dirs we'll try create, if needed
if [[ $ROLES == *"$FESTR"* ]]
then
	if [ ! -d $ECHDIR ]
	then
	    mkdir -p $ECHDIR
	fi
	if [ ! -d $ECHDIR ]
	then
	    echo "$ECHDIR missing - exiting"
	    exit 12
	fi
	if [ ! -d $ECHOLD ]
	then
	    mkdir -p $ECHOLD
	fi
	if [ ! -d $ECHOLD ]
	then
	    echo "$ECHOLD missing - exiting"
	    exit 13
	fi
    if [ ! -d $WKECHDIR ]
    then
        sudo -u $WWWUSER mkdir -p $WKECHDIR
    fi
    if [ ! -d $WKECHDIR ]
    then
        echo "$FRONTEND - $WKECHDIR missing - exiting"
        exit 14
    fi
fi

if [[ $ROLES == *"$BESTR"* ]]
then
    if [ ! -d $WKECHDIR ]
    then
        sudo -u $WWWUSER mkdir -p $WKECHDIR
    fi
    if [ ! -d $WKECHDIR ]
    then
        echo "$FRONTEND - $WKECHDIR missing - exiting"
        exit 14
    fi
fi

if [[ $ROLES == *"$FESTR"* ]]
then
    echo "Checking if new ECHKeys needed for $FRONTEND"

    # Plan:

    # - check creation date of existing ECHConfig key pair files
    # - if all ages < DURATION then we're done and exit 
    # - Otherwise:
    #   - generate new instance of ECHKeys (same for backends)
    #   - retire any keys >3*DURATION old
    #   - delete any keys >5*DURATION old
    #   - push updated JSON (for all keys) to DocRoot dest

    newest=$durt2
    newf=""
    oldest=0
    oldf=""

    echo "Prime key lifetime: $DURATION seconds"
    echo "New key generated when latest is $dur old"
    echo "Old keys retired when older than $durt3"
    echo "Keys published until older than $durt2"
    echo "Desired TTL will be $duro2"

    for file in $files2check
    do
        if [ ! -f $file ]
        then
            continue
        fi
        fage=$(fileage $file)
        #echo "$file is $fage old"
        if ((fage < newest)) 
        then
            newest=$fage
            newf=$file
        fi
        if ((fage > oldest)) 
        then
            oldest=$fage
            oldf=$file
        fi
        if ((fage > durt3)) 
        then
            echo "$file too old, (age==$fage >= $durt3)... moving to $ECHOLD"
            mv $file $ECHOLD
            actiontaken="true"
        fi
    done

    echo "Oldest moveable PEM file is $oldf (age: $oldest)"
    echo "Newest moveable PEM file is $newf (age: $newest)"

    # delete files older than 5*DURATION
    oldies="$ECHOLD/*"
    for file in $oldies
    do
        if [ ! -f $file ]
        then
            continue
        fi
        fage=$(fileage $file)
        if ((fage >= durt5))
        then
            rm -f $file
        fi
    done

    keyn="ech`date +%s`"

    if ((newest >= dur))
    then
        echo "Time for a new key pair (newest as old or older than $dur)"
        actiontaken="true"
        $OSSL/apps/openssl ech \
            -ech_version 0xfe0d \
            -public_name $FRONTEND \
            -pemout $ECHDIR/$keyn.pem.ech
        res=$?
        if [[ "$res" != "1" ]]
        then
            echo "Error generating $ECHDIR/$keyn.pem.ech"
            exit 15
        fi

        # move zonefrag to below DocRoot
        newjsonfile="false"
        # include long-term keys
        mergefiles="$LONGTERMKEYS"
        for file in $ECHDIR/*.pem.ech
        do
            fage=$(fileage $file)
            if ((fage > durt2)) 
            then
                # skip that one, we'll accept/decrypt based on that
                # but no longer publish the public in the zone
                continue
            fi
            newjsonfile="true"
            mergefiles=" $mergefiles $file"
        done
    fi

    if [[ "$actiontaken" != "false" ]]
    then
        # let's put a json file at https://$FRONTEND/.well-known/ech/$FRONTEND.json
        # containing one ECHConfigList for all services for this epoch 
        TMPF=`mktemp /tmp/mergedech-XXXX`
        $OSSL/esnistuff/mergepems.sh -o $TMPF $mergefiles
        echconfiglist=`cat $TMPF | sed -n '/BEGIN ECHCONFIG/,/END ECHCONFIG/p' | head -n -1 | tail -n -1`
        feport=$(hostport2port $FRONTEND)
        fehost=$(hostport2host $FRONTEND)
        cat <<EOF >$TMPF
{
    "front-end" : [{
        "regen-freq" : $dur,
        "port":  $feport,
        "ech": "$echconfiglist"
    }]
}
EOF
        chmod a+r $TMPF
        # copy that to DocRoot
        if [[ "$newjsonfile" == "true" ]]
        then 
            sudo -u $WWWUSER cp $TMPF $WKECHDIR/$fehost.json
        fi
        rm -f $TMPF
    fi

fi

if [[ $ROLES == *"$BESTR"* ]]
then
    # grab a copy of latest front end file and see if it differs
    # from what we have
    TMPF=`mktemp`
    fehost=$(hostport2host $FRONTEND)
    # if we're local to fe then grab file that way
    if [[ $ROLES == *"$FESTR"* ]]
    then
        cp $WKECHDIR/$fehost.json $TMPF
    else
        # split-mode!
        timeout $CURLTIMEOUT curl -o $TMPF -s https://$FRONTEND/.well-known/$WESTR/$fehost.json
    fi
    declare -A jarr
    if [ ! -z $TMPF ]
    then
        first_stanza="{ \"endpoints\" : ["
        entries=`cat $TMPF | jq length`
        for ((index=0;index!=$entries;index++))
        do
            regenfreq=`cat $TMPF | jq ".[$index].regenfreq"`
            feport=`cat $TMPF | jq ".[$index].port"`
            ech=`cat $TMPF | jq ".[$index].ech"`
            if [[ "$ech" == "" || "$regenfreq" == "" ]]
            then
                continue
            fi
            if [[ "$port" == "" ]]
            then
                port=443
            fi
            for be in $BACKENDS
            do
                behost=$(hostport2host $be)
                beport=$(hostport2port $be)
                beistr="
    {
        \"priority\" : 1,
        \"regenfreq\" : $((dur < regenfreq ? dur : regenfreq)),
        \"port\" : $beport,
        \"ech\" : $ech
    }"
                if [[ "${jarr[$behost]}" == "" ]]
                then
                    jarr[$behost]="$first_stanza $beistr"
                else
                    jarr[$behost]+=",$beistr"
                fi
            done
        done
    else
        # nothing to do?
        echo "Nothing to do"
    fi
    # write each collected per-behost info out to DocRoot
    last_stanza="] }"
    for behost in "${!jarr[@]}"
    do
        arrent="${jarr[$behost]} $last_stanza"
        sudo -u $WWWUSER echo $arrent > $WKECHDIR/$behost.json
    done
    unset jarr
fi

if [[ $ROLES == $ZFSTR ]]
then
    # bit more complicated:-)
    echo "Checking for ECHConfigList values at $FRONTEND"
    todos=""
    declare -A jarr
    for back in $BACKENDS
    do
        behost=$(hostport2host $back)
        if [[ "${jarr[$behost]}" == "" ]]
        then
            jarr[$behost]="{}"
        fi
    done
    for behost in "${!jarr[@]}"
    do
        # pull URL, and see if that has new stuff ...
        TMPF=`mktemp`
        path=".well-known/$WESTR/$behost.json"
        URL="https://$FRONTEND/$path"
        # grab .well-known stuff
        if [[ "$DOTEST" == "yes" ]]
        then
            cp $WKECHDIR/$behost.json $TMPF
        else
            timeout $CURLTIMEOUT curl -s $URL -o $TMPF
            tres=$?
        fi
        if [[ "$tres" == "124" ]]
        then
            # timeout returns 124 if it timed out, or else the
            # result from curl otherwise
            echo "Timed out after $CURLTIMEOUT waiting for $FRONTEND"
            exit 2
        fi
        if [ ! -s $TMPF ]
        then
            echo "Can't get content from $URL - skipping $behost"
            rm -f $TMPF
        else
            newcontent=""
            if [ ! -f  $FEDIR/$behost.json ]
            then
                newcontent="yes"
            else
                newcontent=`diff -q $TMPF $FEDIR/$behost.json`
            fi
            if [[ "$newcontent" != "" ]]
            then
                nctype=`file $TMPF`
                if [[ "$nctype" != "$TMPF: JSON text data" ]]
                then
                    echo "$behost bad file type"
                    rm -f $TMPF
                else
                    echo "New content for $behost, something to do"
                    todos="$todos $behost"
                    mv $TMPF $FETMP/$behost.json
                fi
            else
                # content was same, ditch TMPF
                rm -f $TMPF
            fi
        fi
    done
    unset jarr

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
        entries=`cat $FETMP/$backend.json | jq .endpoints | jq length`
        #echo "entries: $entries"
        if [[ "$entries" == "" ]]
        then
            continue
        fi
        for ((index=0;index!=$entries;index++))
        do
            echo "$backend Array element: $((index+1)) of $entries"
            arrent=`cat $FETMP/$backend.json | jq .endpoints | jq .[$index]`
            port=`echo $arrent | jq .port`
            #echo "port: $port"
            list=`echo $arrent | jq .ech | sed -e 's/\"//g'`
            splitlists=`splitlist`
            #echo "splitlists: $splitlists"
            listarr=( $splitlists )
            listcount=${#listarr[@]}
            priority=`echo $arrent | jq .priority`
            regenfreq=`echo $arrent | jq .regenfreq`
            desired_ttl=$((regenfreq/2))
            #echo "desired_ttl: $desired_ttl"
            # now test for each port and ECHConfig within the ECHConfigList
            echerror="false"
            if [[ "$VERIFY" == "no" ]]
            then
                echworked="true"
            else
                echworked="false"
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
            fi
            # could speed up this if full list is singleton but better 
            # to run the code for now...
            if [[ "$echworked" == "true" ]]
            then
                # only check singletons if overall was ok
                snum=1
                for singletonlist in $splitlists
                do
                    if [[ "$VERIFY" == "no" ]]
                    then
                        continue
                    fi
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
            if [ "$echerror" == "false" ] && [ "$echworked" == "true" ]
            then
                # success... all ok so bank that one...
                if [[ "$DOTEST" == "no" ]]
                then
                    #echo "Will try publish for $backend/$port"
                    sleep 3
                    nres=`donsupdate $backend $list $desired_ttl $priority $port`
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
            else
                echo "Won't try publish $backend/$port"
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
fi

if [[ "$actiontaken" != "false" ]]
then
    # restart services that support key rotation
    if [[ $ROLES == *"$FESTR"* ]]
    then
        if [ -f $FE_RESTARTER ]
        then
            echo "Took action - better restart frontend services"
            $FE_RESTARTER
        fi
    fi
    if [[ $ROLES == *"$BESTR"* ]]
    then
        if [ -f $BE_RESTARTER ]
        then
            echo "Took action - better restart backend services"
            $BE_RESTARTER
        fi
    fi
fi

exit 0
