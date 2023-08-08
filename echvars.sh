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

# variables/settings, some can be overwritten from environment

# where the ECH-enabled OpenSSL is built, needed if ECH-checking is enabled
: ${OSSL:=$HOME/code/openssl}
export LD_LIBRARY_PATH=$OSSL

# script to restart or reload configuations for front/back-end
: ${BE_RESTARTER:=/home/sftcd/bin/be_restart.sh}
: ${FE_RESTARTER:=/home/strcd/bin/fe_restart.sh}

# Top of ECH key file directories
: ${ECHTOP:=$HOME/ech}

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


# default top of DocRoots
: ${DRTOP:="/var/www"}

# key is FE Origin (host:port), value is DocRoot for that
declare -A fe_arr=(
    [cover.defo.ie]="$DRTOP/cover/"
    [foo.ie:443]="$DRTOP/foo.ie/www/"
)

# key is BE Origin (host:port), value is DocRoot for that
declare -A be_arr=(
    [defo.ie]="$DRTOP/defo.ie"
    [aliased.defo.ie]="$DRTOP/aliased.defo.ie"
    [draft-13.esni.defo.ie:8413]="$DRTOP/draft-13.esni.defo.ie/8413"
    [draft-13.esni.defo.ie:8414]="$DRTOP/draft-13.esni.defo.ie/8414"
    [draft-13.esni.defo.ie:9413]="$DRTOP/draft-13.esni.defo.ie/9413"
    [draft-13.esni.defo.ie:10413]="$DRTOP/draft-13.esni.defo.ie/10413"
    [draft-13.esni.defo.ie:11413]="$DRTOP/draft-13.esni.defo.ie/11413"
    [draft-13.esni.defo.ie:12413]="$DRTOP/draft-13.esni.defo.ie/12413"
    [draft-13.esni.defo.ie:12414]="$DRTOP/draft-13.esni.defo.ie/12414"
)

# key is BE Origin (host:port), value is alias DNS name, or empty string
# only backends that use aliases need have entries here
declare -A be_alias_arr=(
    [aliased.defo.ie]="cdn.example.net"
)

# key is BE Origin (host:port), value is alias DNS name, or empty string
# only backends that use alpns need have entries here
declare -A be_alpn_arr=(
    [defo.ie]="h2,http/1.1"
    [draft-13.esni.defo.ie:8413]="http/1.1"
)

# Fixed by draft but may change as we go
WESTR="origin-svcb"
FEWKECHDIR="$FEDOCROOT/.well-known"
FEWKECHFILE="$FEDOCROOT/.well-known/$WESTR"

# uid for writing files to DocRoot, whoever runs this script
# needs to be able to sudo to that uid
: ${WWWUSER:="www-data"}

# A timeout in case accessing the FRONTEND .well-known is gonna
# fail - believe it or not: this is 10 seconds
: ${CURLTIMEOUT:="10s"}

# A directory for Zone factory files
: ${ZFDIR:="$HOME/zfdir"}

# A temp dir below that
ZFTMP=$ZFDIR/tmp
