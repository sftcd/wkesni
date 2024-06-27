##

XML2RFC =xml2rfc
DATE=`date +%s`

all: core 

core: 
	$(XML2RFC) --text draft-ietf-tls-wkech.xml

html:
	$(XML2RFC) --html draft-ietf-tls-wkech.xml

oldcore: 
	$(XML2RFC) --legacy draft-farrell-tls-wkesni.xml

upload:
	scp draft-farrell-tls-wkesni.txt  down.dsg.cs.tcd.ie:/var/www/misc/draft-farrell-tls-wkesni.txt
	scp draft-farrell-tls-wkesni.xml  down.dsg.cs.tcd.ie:/var/www/misc/draft-farrell-tls-wkesni.xml

backuup:
	- mkdir backups
	cp draft-farrell-tls-wkesni.txt backups/draft-farrell-tls-wkesni-$(DATE).txt
	cp draft-farrell-tls-wkesni.xml backups/draft-farrell-tls-wkesni-$(DATE).xml

clean:
	rm -f   draft-farrell-tls-wkesni.txt *~

