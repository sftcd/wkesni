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
# with the addition of 'regeninterval' to the JSON
# and (so far) without support for the 'alias' option
# This is a work-in-progress, DON'T DEPEND ON THIS!!

# This script handles ECH key updating for an ECH front-end (in ECH split-mode),
# back-end (e.g. web server) or zone factory (the thing that publishes DNS RRs
# containing ECH public values).

# This iteration isn't yet tested in any deployment, whereas wkech-03.sh is.
# The alpn TODO: is the main thing to fix before testing/deployment

# This makes use of our ECH-enabled OpenSSL and curl forks. A
# good place to start to get those working is:
#   https://github.com/sftcd/curl/blob/ECH-experimental/docs/ECH.md 

# Paths that  can be overidden
: ${OSSL:=$HOME/code/openssl}
: ${CTOP:=$HOME/code/curl}

# variables/settings, some can be overwritten from environment
. echvars.sh

# more paths, possibly partly overidden
export LD_LIBRARY_PATH=$OSSL
CURLBIN=$CTOP/src/curl
CURLCMD="$CTOP/src/curl --doh-url https://one.one.one.one/dns-query"

# role strings
FESTR="fe"
BESTR="be"
ZFSTR="zf"
ROLES="$FESTR,$BESTR"

# whether to attempt checks that ECH works before publishing
VERIFY="yes"

# whether to really try publish via bind or just test to that point
DOTEST="no"

# whether to only make one public key available for publication
# from front-end .well-known
JUSTONE="no"

# yeah, 443 is the winner:-)
DEFPORT=443

# switch between use of curl or echcli.sh
USE_CURL="yes"

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
    target=$5
    port=$6
    # extraparams can be empty, if not, it has things like alpn, ip hints
    extraparams="$7 $8 $9" 
    # All params are needed
    if [[ $host == "" \
          || $echval == "" \
          || $ttl = "" \
          || $priority = "" \
          || $target == "" \
          || $port == "" ]]
    then
        # non-random failure code
        echo 57
    fi
    if [[ "$port" == "443" ]]
    then
        nscmd="update delete $host HTTPS\n
               update add $host $ttl HTTPS $priority $target $extraparams ech=$echval\n
               send\n
               quit"
    else
        oname="_$port._https.$host"
        nscmd="update delete $oname HTTPS\n
               update add $oname $ttl HTTPS $priority $host $extraparams ech=$echval\n
               send\n
               quit"
    fi
    echo -e $nscmd | sudo su -c "nsupdate -l >/dev/null 2>&1; echo $?"
}

# given a host, a base64 ECHConfigList a TTL and an optional port
# (default 443), use the bind9 nsupdate tool to publish that value
# in the DNS, we return the return value from the nsupdate tool,
# which is 0 for success and non-zero otherwise
function doaliasupdate()
{
    host=$1
    port=$2
    alias=$3
    ttl=$4
    # All params are needed
    if [[ $host == "" \
          || $alias == "" \
          || $port == "" \
          || $ttl == "" ]]
    then
        # non-random failure code
        echo 67
    fi
    if [[ "$port" == "443" ]]
    then
        nscmd="update delete $host HTTPS\n
               update add $host $ttl HTTPS 0 $alias\n
               send\n
               quit"
    else
        oname="_$port._https.$host"
        nscmd="update delete $oname HTTPS\n
               update add $oname $ttl HTTPS 0 $alias\n
               send\n
               quit"
    fi
    echo -e $nscmd | sudo su -c "nsupdate -l >/dev/null 2>&1; echo $?"
}

function usage()
{
    echo "$0 [-h] [-r roles] [-d duration] - generate new ECHKeys as needed."
    echo "  -d specifies key update frequency in seconds (for testing really)"
    echo "  -h means print this"
    echo "  -n means to not verify that ECH is working before publishing"
    echo "  -r roles can be \"$FESTR\" or \"$FESTR,$BESTR\" or \"$ZFSTR\" " \
         "(default is \"$ROLES\")"
    echo "  -t means to test $ZFSTR role up to, but not including, publication"
    echo "  -1 means to only make 1 public key available from front-end at the .well-known"

	echo ""
	echo "The following should work:"
	echo "    $0 "
    exit 1
}

echo "=========================================="
NOW=$(whenisitagain)
echo "Running $0 at $NOW"

# options may be followed by one colon to indicate they have a required argument
if ! options=$(/usr/bin/getopt -s bash -o 1cd:ehnr:t -l one,curl,duration:,echcli,help,no-verify,roles:,test -- "$@")
then
    # something went wrong, getopt will put out an error message for us
    exit 2
fi
#echo "|$options|"
eval set -- "$options"
while [ $# -gt 0 ]
do
    case "$1" in
        -1|--one) JUSTONE="yes";;
        -c|--curl) USE_CURL="yes";;
        -d|--duration) DURATION=$2; shift;;
        -e|--echcli) USE_CURL="no";;
        -h|--help) usage;;
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
durt3=$((DURATION*3 + 60)) # allow a bit of leeway
durt5=$((DURATION*5))


# set this if we did something that needs e.g. a server restart
someactiontaken="false"

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
    # check that our OpenSSL build supports ECH
    $OSSL/apps/openssl ech -help >/dev/null 2>&1
    eres=$?
    if [[ "$eres" != "0" ]]
    then
        echo "OpenSSL not built with ECH - exiting"
        exit 8
    fi

    # check/make various directories
    if [ ! -d $ECHTOP ]
    then
        echo "$ECHTOP ECH key dir missing - exiting"
        exit 7
    fi
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
    # check/make docroot and .well-known if needed
    for feor in "${!fe_arr[@]}"
    do
        #echo "FE origin: $feor, DocRoot: ${fe_arr[${feor}]}"
        fedr=${fe_arr[${feor}]}
        fewkechdir=$fedr/.well-known/
        if [ ! -d $fewkechdir ]
        then
            sudo mkdir -p $fewkechdir
        fi
        if [ ! -d $fewkechdir ]
        then
            echo "$fedr - $fewkechdir missing - exiting"
            exit 14
        fi
        sudo chown -R $WWWUSER:$WWWGRP $fewkechdir
    done
fi

if [[ $ROLES == *"$BESTR"* ]]
then
    # check docroots and if we can sudo to www-user
    for beor in "${!be_arr[@]}"
    do
        bedr=${be_arr[${beor}]}
        if [[ ! -d $bedr ]]
        then
            echo "DocRoot for $beor ($bedr) missing - exiting"
            exit 9
        fi
        sudo -u $WWWUSER ls $bedr >/dev/null
        sres=$?
        if [[ "$sres" != "0" ]]
        then
            echo "Can't sudo to $WWWUSER to read $bedr - exiting"
            exit 10
        fi
        if [ ! -d $bedr/.well-known ]
        then
            sudo -u $WWWUSER mkdir -p $bedr/.well-known/
        fi
        if [ ! -f $bedr/.well-known/$WESTR ]
        then
            sudo -u $WWWUSER touch $bedr/.well-known/$WESTR
        fi
        if [ ! -f $bedr/.well-known/$WESTR ]
        then
            echo "Failed sudo'ing to $WWWUSER to make $bedr/.well-known/$WESTR - exiting"
            exit 15
        fi
    done
    wns=`which jq`
    if [[ "$wns" == "" ]]
    then
        echo "Can't see jq - exiting"
        exit 11
    fi
fi

if [[ $ROLES == $ZFSTR ]]
then
    # check that our CURL version supports ECH
    curlgotech=`$CURLBIN -h tls | grep "Encrypted Client Hello"`
    if [[ "$USE_CURL" == "yes" && "$curlgotech" == "" ]]
    then
        echo "$CURLBIN not built with ECH - exiting"
        exit 8
    fi
    if [ "$USE_CURL" == "no" && ! -f $OSSL/esnistuff/echcli.sh ]
    then
        echo "Can't see $OSSL/esnistuff/echcli.sh - exiting"
        exit 11
    fi
    if [ ! -d $ZFDIR ]
    then
        mkdir -p $ZFDIR
    fi
    if [ ! -d $ZFDIR ]
    then
        echo "Can't see $ZFDIR - exiting"
        exit 11
    fi
    if [ ! -d $ZFTMP ]
    then
        mkdir -p $ZFTMP
    fi
    if [ ! -d $ZFTMP ]
    then
        echo "Can't see $ZFTMP - exiting"
        exit 11
    fi
    # check we can see nsupdate
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

if [[ $ROLES == *"$FESTR"* ]]
then

    for feor in "${!fe_arr[@]}"
    do
        echo "Checking if new ECHKeys needed for $feor"
        actiontaken="false"

        feport=$(hostport2port $feor)
        fehost=$(hostport2host $feor)
        fedr=${fe_arr[${feor}]}
        fewkechfile=$fedr/.well-known/$WESTR

        # Plan:

        # - check creation date of existing ECHConfig key pair files
        # - if all ages < DURATION then we're done and exit
        # - Otherwise:
        #   - generate new instance of ECHKeys (same for backends)
        #   - retire any keys >3*DURATION old
        #   - delete any keys >5*DURATION old
        #   - push updated JSON (for all keys) to DocRoot dest

        newest=$durt5
        newf=""
        oldest=0
        oldf=""

        echo "Prime key lifetime: $DURATION seconds"
        echo "New key generated when latest is $dur old"
        echo "Old keys retired when older than $durt3"
        if [[ "$JUSTONE" == "yes" ]]
        then
            echo "Only latest key (age <$dur) made available"
        else
            echo "Keys published while younger than $durt2"
        fi
        echo "Keys deleted when older than $durt5"

        if [ ! -d $ECHDIR/$fehost.$feport ]
        then
            mkdir -p $ECHDIR/$fehost.$feport
        fi
        if [ ! -d $ECHDIR/$fehost.$feport ]
        then
            echo "Can't see $ECHDIR/$fehost.$feport - exiting"
            exit 25
        fi
        files2check="$ECHDIR/$fehost.$feport/*.pem.ech"

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
                someactiontaken="true"
            fi
        done

        echo "Oldest PEM file is $oldf (age: $oldest)"
        echo "Newest PEM file is $newf (age: $newest)"

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

        if ((newest >= (dur-1)))
        then
            echo "Time for a new key pair (newest as old or older than $dur)"
            $OSSL/apps/openssl ech \
                -ech_version 0xfe0d \
                -public_name $fehost \
                -pemout $ECHDIR/$fehost.$feport/$keyn.pem.ech
            res=$?
            if [[ "$res" != "1" ]]
            then
                echo "Error generating $ECHDIR/$fehost.$feport/$keyn.pem.ech"
                exit 15
            fi
            actiontaken="true"
            someactiontaken="true"
            newf=$ECHDIR/$fehost.$feport/$keyn.pem.ech
        fi

        if [[ "$JUSTONE" == "yes" ]]
        then
            # just set the most recent one for publishing
            mergefiles="$newf"
        else
            # include long-term keys, if any
            mergefiles="$LONGTERMKEYS"
            for file in $ECHDIR/$fehost.$feport/*.pem.ech
            do
                fage=$(fileage $file)
                if ((fage > durt2))
                then
                    # skip that one, we'll accept/decrypt based on that
                    # but no longer publish the public in the zone
                    continue
                fi
                mergefiles=" $mergefiles $file"
            done
        fi

        TMPF="$ECHDIR/$fehost.$feport/latest-merged"
        if [ ! -f $TMPF ]
        then
            actiontaken="true"
            someactiontaken="true"
        fi
        if [[ "$actiontaken" != "false" ]]
        then
            echo "Merging these files for publication: $mergefiles"
            $OSSL/esnistuff/mergepems.sh -o $TMPF $mergefiles
            echconfiglist=`cat $TMPF | sed -n '/BEGIN ECHCONFIG/,/END ECHCONFIG/p' \
                | head -n -1 | tail -n -1`
            rm -f $TMPF
            ipstr=""
            cfgips=${fe_ipv4s[${feor}]}
            if [[ "$cfgips" != "" ]]
            then
                ipstr=",\"ipv4hint\": \"$cfgips\""
            fi
            cfgips=${fe_ipv6s[${feor}]}
            if [[ "$cfgips" != "" ]]
            then
                ipstr="$ipstr,\"ipv6hint\": \"$cfgips\""
            fi
            cat <<EOF >$TMPF
{
 "endpoints": [ {
    "regeninterval" : $dur,
    "priority" : 1,
    "port":  $feport,
    "ech": "$echconfiglist"$ipstr
 } ]
}
EOF
            sudo cp $TMPF $fewkechfile
            sudo chown $WWWUSER:$WWWGRP $fewkechfile
            sudo chmod a+r $fewkechfile
        fi
    done
fi

if [[ $ROLES == *"$BESTR"* ]]
then
    for beor in "${!be_arr[@]}"
    do
        bedr=${be_arr[${beor}]}
        wkechfile=$bedr/.well-known/$WESTR
        behost=$(hostport2host $beor)
        beport=$(hostport2port $beor)
        if [ ! -d $ECHDIR/$behost.$beport ]
        then
            mkdir -p $ECHDIR/$behost.$beport
        fi
        if [ ! -d $ECHDIR/$behost.$beport ]
        then
            echo "Can't see $ECHDIR/$behost.$beport - exiting"
            exit 25
        fi
        lmf=$ECHDIR/$behost.$beport/latest-merged
        rm -f $lmf
        # is there an alias entry for this BE?
        if [[ -n ${be_alias_arr[${beor}]} ]]
        then
            alvals=${be_alias_arr[${beor}]}
            if [[ "$alvals" == "" ]]
            then
                # that's a signal that BE doesn't do ECH so signal we want to publish
                # an "empty" .well-known TODO: do that!
                echo "TODO: handle empty alias"
            else
                # add in aliases if desired - these overwrite any of the above
                alvals=${be_alias_arr[${beor}]}
                if [[ "$alvals" != "" ]]
                then
                    for alval in $alvals
                    do
                        TMPF1=`mktemp`
                        cat <<EOF >$TMPF1
{ "endpoints": [ {
    "alias": "$alval",
    "regeninterval": $dur
} ] }
EOF
                        if [ ! -f $lmf ] 
                        then
                            cp $TMPF1 $lmf
                        else
                            TMPF2=`mktemp`
                            jq -n '{ endpoints: [ inputs.endpoints ] | add }' $lmf $TMPF1 >$TMPF2
                            jres=$?
                            if [[ "$jres" == 0 ]]
                            then
                                mv $TMPF2 $lmf
                            else
                                rm -f $TMPF2
                            fi
                        fi
                        rm -f $TMPF1
                    done
                fi
            fi
        else
            # non-alias case
	        # accumulate the various front-end files
	        for feor in "${!fe_arr[@]}"
	        do
	            fehost=$(hostport2host $feor)
	            feport=$(hostport2port $feor)
	            TMPF=`mktemp`
	            if [[ $ROLES == *"$FESTR"* ]]
	            then
	                # shared-mode, FE JSON file is local
	                fedr=${fe_arr[${feor}]}
	                fewkechfile=$fedr/.well-known/$WESTR
	                cp $fewkechfile $TMPF
	            else
	                # split-mode, FE JSON file is non-local
	                timeout $CURLTIMEOUT curl -o $TMPF -s https://$feor/.well-known/$WESTR
	                if [[ "$tres" == "124" ]]
	                then
	                    # timeout returns 124 if it timed out, or else the
	                    # result from curl otherwise
	                    echo "Timed out after $CURLTIMEOUT waiting for https://$feor/.well-known/$WESTR"
	                    exit 23
	                fi
	            fi
	            if [ ! -f $TMPF ]
	            then
	                echo "Empty result from https://$feor/.well-known/$WESTR"
	                continue
	            fi
	            # merge into latest
	            if [ ! -f $lmf ]
	            then
	                cp $TMPF $lmf
	            else
	                TMPF1=`mktemp`
	                jq -n '{ endpoints: [ inputs.endpoints ] | add }' $lmf $TMPF >$TMPF1
	                jres=$?
	                if [[ "$jres" == 0 ]]
	                then
	                    mv $TMPF1 $lmf
	                else
	                    rm -f $TMPF1
	                fi
	            fi
	        done
	        # add alpn= to endpoints, if desired
	        alpnval=${be_alpn_arr[${beor}]}
	        if [[ "$alpnval" != "" ]]
	        then
	            TMPF1=`mktemp`
	            jq '.endpoints[] + { "alpn": "'$alpnval'" }' $lmf | jq -n '{ endpoints: [ inputs ] }' >$TMPF1
	            jres=$?
	            if [[ "$jres" == 0 ]]
	            then
	                mv $TMPF1 $lmf
	            else
	                rm -f $TMPF1
	            fi
	        fi
	        # fix port number everywhere if non default
	        if [[ "$beport" != "$DEFPORT" ]]
	        then
	            TMPF1=`mktemp`
	            jq '.endpoints[].port? |= "'$beport'"' $lmf >$TMPF1
	            jres=$?
	            if [[ "$jres" == 0 ]]
	            then
	                mv $TMPF1 $lmf
	            else
	                rm -f $TMPF1
	            fi
	        fi
        fi
        newcontent=`diff -q $wkechfile $lmf`
        if [[ -f $lmf && "$newcontent" != "" ]]
        then
            # copy to DocRoot
            sudo cp $lmf $wkechfile
            sudo chown $WWWUSER:$WWWGRP $wkechfile
            sudo chmod a+r $wkechfile
            someactiontaken="true"
        fi
    done
fi

if [[ $ROLES == $ZFSTR ]]
then
    # bit more complicated:-)
    todos=""
    for beor in "${!be_arr[@]}"
    do
        behost=$(hostport2host $beor)
        beport=$(hostport2port $beor)
        echo "Checking for ECHConfigList values at $behost:$beport"
        # pull URL, and see if that has new stuff ...
        TMPF=`mktemp`
        path=".well-known/$WESTR"
        # URL below should really be $behost, but needs change to defo.ie test setup
        URL="https://$beor/$path"
        # grab .well-known stuff
        if [[ "$USE_CURL" == "yes" ]]
        then
            timeout $CURLTIMEOUT $CURLCMD -s $URL -o $TMPF
        else
            # use system curl
            timeout $CURLTIMEOUT curl -s $URL -o $TMPF
        fi
        tres=$?
        if [[ "$tres" == "124" ]]
        then
            # timeout returns 124 if it timed out, or else the
            # result from curl otherwise
            echo "Timed out after $CURLTIMEOUT waiting for $beor"
            continue
        fi
        if [ ! -s $TMPF ]
        then
            echo "Can't get content from $URL - skipping $beor"
            rm -f $TMPF
        else
            newcontent=""
            if [ ! -f  $ZFDIR/$behost.$beport.json ]
            then
                newcontent="yes"
            else
                newcontent=`diff -q $TMPF $ZFDIR/$behost.$beport.json`
            fi
            if [[ "$newcontent" != "" ]]
            then
                nctype=`file --mime-type $TMPF`
                # check we got JSON
                if [[ "$nctype" != "$TMPF: application/json" ]]
                then
                    echo "$behost:$beport bad file type ($nctype)"
                    rm -f $TMPF
                else
                    echo "New content for $beor, something to do"
                    todos="$todos $beor"
                    mv $TMPF $ZFTMP/$behost.$beport.json
                fi
            else
                # content was same, ditch TMPF
                rm -f $TMPF
            fi
        fi
    done

    for back in $todos
    do
        # Remember if we did or didn't publish something - if we do, then
        # we'll "promote" the JSON file from the tmp dir to the longer term
        # one. We do that even if some of the JSON file entries don't work
        # on the basis that it's correct to publish keys that work and if
        # the backend fixes broken things, then we'll pick up on that and
        # publish.
        behost=$(hostport2host $back)
        beport=$(hostport2port $back)
        publishedsomething="false"
        #echo "Trying ECH to $behost:$beport"
        entries=`cat $ZFTMP/$behost.$beport.json | jq .endpoints | jq length`
        #echo "entries: $entries"
        if [[ "$entries" == "" ]]
        then
            continue
        fi
        for ((index=0;index!=$entries;index++))
        do
            echo "$behost:$beport Array element: $((index+1)) of $entries"
            arrent=`cat $ZFTMP/$behost.$beport.json | jq .endpoints | jq .[$index]`
            regeninterval=`echo $arrent | jq .regeninterval`
            aliasname=`echo $arrent | jq .alias | sed -e 's/"//g'`
            if [[ "$aliasname" != "" && "$aliasname" != "null" ]]
            then
                # see if that alias works
                if [[ "$USE_CURL" == "no" ]]
                then
                    $OSSL/esnistuff/echcli.sh -s $aliasname -H $behost \
                        -p $beport >/dev/null 2>&1
                else
                    $CURLCMD --ech hard "https://$behost:$beport/"
                fi
                res=$?
                #echo "Test result is $res"
                if [[ "$res" != "0" ]]
                then
                    echo "ECH alias error for $behost $beport $aliasname"
                    echerror="true"
                else
                    echo "ECH alias fine for $behost $beport $aliasname"
                    echworked="true"
                fi
                if [[ "$echworked" == "true" ]]
                then
                    # publish
                    if [[ "$DOTEST" == "no" ]]
                    then
                        nres=`doaliasupdate $behost $beport $aliasname $regeninterval`
                        if [[ "$nres" == "0" ]]
                        then
                            echo "Published for $behost/$beport via $aliasname"
                            publishedsomething="true"
                        else
                            echo "Failure ($nres) publishing for $behost/$beport via $aliasname"
                        fi
                    else
                        echo "Testing, so not publishing"
                    fi
                fi
                continue
            fi
            # non-alias case
            list=`echo $arrent | jq .ech | sed -e 's/\"//g'`
            if [[ "$list" == "null" ]]
            then
                # skip if no ECH value (aliases handled above)
                continue
            fi
            splitlists=`splitlist`
            #echo "splitlists: $splitlists"
            listarr=( $splitlists )
            listcount=${#listarr[@]}
            port=`echo $arrent | jq .port | sed -e 's/"//g'`
            if [[ "$port" == "null" ]]
            then
                port=443
            fi
            #echo "port: $port"
            priority=`echo $arrent | jq .priority`
            if [[ "$priority" == "null" ]]
            then
                priority=1
            fi
            regeninterval=`echo $arrent | jq .regeninterval`
            if [[ "$regeninterval" == "null" ]]
            then
                regeninterval=3600
            fi
            alpn=`echo $arrent | jq .alpn | sed -e 's/"//g'`
            if [[ "$alpn" == "null" ]]
            then
                alpn_cla="" # command line arg
                alpn_str="" # value for HTTPS RR
            else
                alpn_cla="-a $alpn"
                alpn_str="alpn=$alpn"
            fi
            ipv4hints=`echo $arrent | jq .ipv4hint | sed -e 's/"//g'`
            if [[ "$ipv4hints" == "null" ]]
            then
                ipv4hints_str=""
            else
                ipv4hints_str="ipv4hint=$ipv4hints"
            fi
            ipv6hints=`echo $arrent | jq .ipv6hint | sed -e 's/"//g'`
            if [[ "$ipv6hints" == "null" ]]
            then
                ipv6hints_str=""
            else
                ipv6hints_str="ipv6hint=$ipv6hints"
            fi
            target=`echo $arrent | jq .target`
            if [[ "$target" == "null" ]]
            then
                target=""
            fi
            desired_ttl=$((regeninterval/2))
            # now test for each port and ECHConfig within the ECHConfigList
            echerror="false"
            if [[ "$VERIFY" == "no" ]]
            then
                echworked="true"
            else
                echworked="false"
                # first test entire list then each element
                if [[ "$USE_CURL" == "no" ]]
                then
                    $OSSL/esnistuff/echcli.sh -P $list -H $behost \
                        -p $port $alpn_cla >/dev/null 2>&1
                else
                    # TODO: find a way to pass alpn params
                    $CURLCMD --ech hard --ech ecl:$list "https://$behost:$port/"
                fi
                res=$?
                #echo "Test result is $res"
                if [[ "$res" != "0" ]]
                then
                    echo "ECH list error for $behost $beport"
                    echerror="true"
                else
                    echo "ECH list fine for $behost $beport"
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
                    if [[ "$USE_CURL" == "no" ]]
                    then
                        $OSSL/esnistuff/echcli.sh -P $singletonlist -H $behost \
                            -p $beport $alpn_cla >/dev/null 2>&1
                    else
                        # TODO: find a way to pass alpn params
                        $CURLCMD --ech hard --ech ecl:$singletonlist "https://$behost:$port/"
                    fi
                    res=$?
                    if [[ "$res" != "0" ]]
                    then
                            echo "ECH single error at $behost $beport $singletonlist"
                            echerror="true"
                        else
                            echo "ECH single ($snum/$listcount) fine at $behost $beport"
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
                    if [[ "$port" == "" ]]
                    then
                        port=443
                    fi
                    #echo "Will try publish for $behost:$port"
                    if [[ "$target" == "" ]]
                    then
                        if [[ "$port" == "443" ]]
                        then
                            target="."
                        else
                            target=$behost
                        fi
                    fi
                    if [[ "$alpn_str" != "" || "$ipv4hints_str" != "" || "$ipv6hints_str" != "" ]]
                    then
                        extraparams="$alpn_str $ipv4hints_str $ipv6hints_str"
                    else
                        extraparams=""
                    fi
                    sleep 3
                    nres=`donsupdate $behost $list $desired_ttl $priority $target $beport $extraparams`
                    if [[ "$nres" == "0" ]]
                    then
                        echo "Published for $behost/$beport"
                        publishedsomething="true"
                    else
                        echo "Failure ($nres) in publishing for $behost/$beport"
                    fi
                else
                    echo "Just testing so won't add $behost/$beport"
                    publishedsomething="true"
                fi
            else
                echo "Won't try publish $behost/$beport"
            fi
        done
        if [[ "$publishedsomething" == "true" ]]
        then
            # we're accepting this one, so we something worked from here
            # so save this file for comparison with next time we get run
            mv $ZFTMP/$behost.$beport.json $ZFDIR/$behost.$beport.json
        else
            # nothing worked, so clean up
            rm $ZFTMP/$behost.$beport.json
        fi
    done

    # clean up TMP dir, it should be empty, if not the error will improve us:-)
    rmdir $ZFTMP
fi

if [[ "$someactiontaken" != "false" ]]
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
THEN=$(whenisitagain)
echo "Finished $0 at $THEN (started at $NOW)"
echo "=========================================="

exit 0
