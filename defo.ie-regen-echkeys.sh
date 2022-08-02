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

# ECH keys update as per draft-ietf-tls-wkech

# Caution: don't mess with output format here unless you make
# equivalent changes in (your equivalent of) repub-echkeys.sh - both scripts 
# should deal with the same thing

# This script is specific to the defo.ie deployment which runs a bunch of
# different web servers on different ports, but using the same DNS name
# (draft-13.esni.defo.ie) for all the BACKENDS and cover.defo.ie for the
# FRONTEND. Other scripts/tools will be needed for other deployments (and
# are planned, hopefully soonish).

# This is run from a cron job and deposits updated keys where the
# web server instances can load 'em (and restarts the server or reloads the 
# server config). We also copy the keys to the .well-known below DocRoot so 
# they can be picked up by a DNS backend/zonefactory, checked and published.

# Updating keys includes moving aside "old" key files.

# We also support leaving in-place some long term keys, if that's desired.

# filename convention: *.ech can be loaded by servers but only 
# *.pem.ech will be moved aside when old, so if you want a file
# to always be loaded by servers just call it something.ech where
# the something doesn't end in .pem

# variables/settings

# where this repo tends to live
: ${OSSL:=$HOME/code/openssl}
export LD_LIBRARY_PATH=$OSSL

# check that the that OpenSSL build is built
if [ ! -f $OSSL/apps/openssl ]
then
    echo "OpenSSL not built - exiting"
    exit 99
fi

# check that our build supports ECH
$OSSL/apps/openssl ech -help >/dev/null 2>&1
eres=$?
if [[ "$eres" != "0" ]]
then
    echo "OpenSSL not built with ECH - exiting"
    exit 98
fi

# ECH key file directory is common for all defo.ie instances
: ${ECHSTUFF:=$HOME/.ech13}

# This is where most or all $DURATION-lived ECH keys live
# When they get to 2*$DURATION old they'll be moved to $ECHOLD
ECHDIR="$ECHSTUFF/echkeydir"
# Where old stuff goes
ECHOLD="$ECHDIR/old"

if [[ ! -d $ECHSTUFF || ! -d $ECHDIR || ! -d $ECHOLD ]]
then
    echo "Some ECH key dirs absent - exiting"
    exit 1
fi

# Various possible "prime" durationns - we publish keys for
# 2 x this duration and add a new key each time and retire
# (as in don't load to server) old keys after 3 x this duration.
# So, keys remain usable for 3 x this, and are visible to the
# Internet for 2 x this. 
# We ask that the RR TTL containing such keys be half the
# duration.
DURATION="3600" # 1 hour

# Our FRONTEND and BACKEND DNS names
# BACKEND needs to be just one name here (for now)
: ${BACKEND:="draft-13.esni.defo.ie"}

# Where we keep long term keys, can be space-sep list if needed
LONGTERMKEYS="$ECHDIR/$BACKEND.ech"

# This script only works for one FRONTEND, generalise if you wish:-)
: ${FRONTEND:="cover.defo.ie"}

# FRONTEND DocRoot where we make ECH info available via .well-known
: ${DOCROOT:="/var/www/html/cover"}
DOCROOTDIR="$DOCROOT/.well-known/ech"

# uid for writing files to DocRoot
: ${WWWUSER:="www-data"}

# where the scripts to re-start the various web servers live
: ${SCRIPTHOME:="$HOME/code/defo-project/scripts"}

if [[ ! -d $DOCROOT ]]
then
    echo "$FRONTEND - $DOCROOT missing - exiting"
    exit 2
fi
# make this one if needed
if [ ! -d $DOCROOTDIR ]
then
    sudo -u $WWWUSER mkdir -p $DOCROOTDIR
fi
if [ ! -d $DOCROOTDIR ]
then
    echo "$FRONTEND - $DOCROOTDIR missing - exiting"
    exit 2
fi

# We have these web servers on these ports
# OpenSSL s_server
PORT_S_SERVER=8413
# OpenSSL s_server that forces HRR for almost everyone by only supporting
# p384 key shares
PORT_S_SERVER_HRR=8414
# lighttpd
PORT_LIGHTTPD=9413
# nginx
PORT_NGINX=10413
# apache
PORT_APACHE=11413
# haproxy
# just to record the ones below for now - we don't rotate keys yet
# as we've not integrated key reloading yet - doing that well
# would need to use the netcat like API haproxy likes as it
# doesn't want to read from disk after initial startup (in case
# of disk failures apparently)
# So the upstream zone factory treats those ones as
# static zone content rather than dynamic
PORT_HAPROXY=12413
PORT_HAPROXY_SPLIT=12414
# we also have an nginx on port 443 but don't rotate it's keys 
# for better interop in case some client doesn't support a list
# of ECH keys

# We aggregate over all ports on $FRONTEND - even if keyed
# differently, they are all authenticated similarly so
# not much point differentialing
PORTS="$PORT_S_SERVER \
       $PORT_S_SERVER_HRR \
       $PORT_LIGHTTPD \
       $PORT_NGINX \
       $PORT_APACHE"
CSVPORTS="[ $PORT_S_SERVER,$PORT_S_SERVER_HRR,$PORT_LIGHTTPD,$PORT_NGINX,$PORT_APACHE ]"

function whenisitagain()
{
    /bin/date -u +%Y%m%d-%H%M%S
}

function fileage()
{
    echo $(($(date +%s) - $(date +%s -r "$1"))) 
}

NOW=$(whenisitagain)

echo "=========================================="
echo "Running $0 at $NOW"

function usage()
{
    echo "$0 [-h] [-d duration] - generate new ECHKeys for defo.ie"
    echo "  -h means print this"
    echo "  -d specifies prime duration in seconds (for testing really)"

	echo ""
	echo "The following should work:"
	echo "    $0 "
    exit 99
}

# options may be followed by one colon to indicate they have a required argument
if ! options=$(/usr/bin/getopt -s bash -o hd: -l help,duration: -- "$@")
then
    # something went wrong, getopt will put out an error message for us
    exit 1
fi
#echo "|$options|"
eval set -- "$options"
while [ $# -gt 0 ]
do
    case "$1" in
        -h|--help) usage;;
        -d|--duration) DURATION=$2; shift;;
        (--) shift; break;;
        (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 1;;
        (*)  break;;
    esac
    shift
done

echo "Checking if new ECHKeys needed for $FRONTEND"

# Plan:

# - check creation date of existing ECHConfig key pair files
# - if all ages < DURATION/2 then we're done and exit 
# - Otherwise:
#   - generate new instance of ECHKeys (same for all ports)
#   - push updated JSON (for all keys) to DocRoot dest
#   - retire any keys >3*DURATION old

if [ ! -d $ECHDIR ]
then
    mkdir -p $ECHDIR
fi
if [ ! -d $ECHOLD ]
then
    mkdir -p $ECHOLD
fi
if [ ! -d $DOCROOTDIR ]
then 
    sudo -u $WWWUSER mkdir $DOCROOTDIR
fi

files2check="$ECHDIR/*.pem.ech"

# Various multiples/fractions of DURATION
duro2=$((DURATION/2))
dur=$DURATION
durt2=$((DURATION*2))
durt3=$((DURATION*3))

newest=$durt2
newf=""
oldest=0
oldf=""

# set this if we do someting that needs a server re-start
actiontaken="false"

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
    if ((fage >= durt3)) 
    then
        echo "$file too old, (age==$fage >= $durt3)... moving to $ECHOLD"
        mv $file $ECHOLD
        actiontaken="true"
    fi
done

echo "Oldest moveable PEM file is $oldf (age: $oldest)"
echo "Newest moveable PEM file is $newf (age: $newest)"

keyn="ech`date +%s`"

if ((newest >= dur))
then
    echo "Time for a new key pair (newest as old or older than $dur)"
    # check if address file there - if not make one
    actiontaken="true"
    # move zonefrag to below DocRoot
    $OSSL/apps/openssl ech \
        -ech_version 0xfe0d \
        -public_name $FRONTEND \
        -pemout $ECHDIR/$keyn.pem.ech
    res=$?
    if [[ "$res" != "1" ]]
    then
        exit "Error generating $ECHDIR/$keyn.pem.ech"
        exit 28
    fi

    newjsonfile="false"
    mergefiles=""
    # this one can have stable, long-term keys, so include it if it's there
    if [ -f $LONGTERMKEYS ]
    then
        mergefiles="$LONGTERMKEYS"
    fi
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

    # this variant puts a json file at https://$FRONTEND/.well-known/ech/$BACKEND.json
    # containing one ECHConfigList for all services for each epoch 
    TMPF=`mktemp /tmp/mergedech-XXXX`
    $OSSL/esnistuff/mergepems.sh -o $TMPF $mergefiles
    echconfiglist=`cat $TMPF | sed -n '/BEGIN ECHCONFIG/,/END ECHCONFIG/p' | head -n -1 | tail -n -1`
    cat <<EOF >$TMPF
[
    {
        "desired-ttl": $duro2,
        "ports":  $CSVPORTS,
        "echconfiglist": "$echconfiglist"
    }
]
EOF
    # copy that to DocRoot
    if [[ "$newjsonfile" == "true" ]]
    then 
        sudo -u $WWWUSER cp $TMPF $DOCROOTDIR/$BACKEND.json
    fi
    rm -f $TMPF
fi

if [[ "$actiontaken" != "false" ]]
then
    # restart services 
    echo "Took action - better restart services"
    if [ -d $SCRIPTHOME ]
    then
        $SCRIPTHOME/defoserver-draft13.sh -d
        $SCRIPTHOME/defoserver-draft13-hrr.sh -d
        $SCRIPTHOME/lighttpdserver-draft13.sh
        $SCRIPTHOME/nginx-draft-13.sh
        $SCRIPTHOME/apache-draft-13.sh
        $SCRIPTHOME/lighttpdserver-baddns.sh
        # don't bother with haproxy yet (see above for why)
        # $SCRIPTHOME/haproxyserver-12413.sh
        # $SCRIPTHOME/haproxyserver-12414.sh
    else
        echo "Can't find $SCRIPTHOME - skipping restarts"
    fi
fi

