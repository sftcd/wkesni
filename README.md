# wkesni

A well-known URI for publishing ECHConfigList values from a web server.  The
[Internet draft](https://datatracker.ietf.org/doc/draft-ietf-tls-wkech) is an
IETF TLS WG draft specification.

[This](draft-ietf-tls-wkech.txt) is the local copy. 

[wkech-03.sh](wkech-03.sh) is a bash script that implements (most of) the
draft.  That has a bunch of dependencies, and is a work-in-progress, so don't
use it - it's for testing and not that well tested. That is used for the
[defo.ie](https://defo.ie) ECH deployment.

[wkech-04.sh] is a version that uses our
[ECH-enabled curl](https://github.com/sftcd/curl/blob/ECH-experimental/docs/ECH.md)
rather than ``openssl s_client``. Plan is to replace the above with that
soonish.

(ECH used be called ESNI, hence the repo name.)
