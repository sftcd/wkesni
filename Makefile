# XML2RFC=/Users/paul/Documents/xml2rfc-1.35/xml2rfc.tcl
XML2RFC=xml2rfc --text --legacy

DATE=`date +%s`

all: core 

core: 
	$(XML2RFC) draft-ietf-tls-wkech.xml

oldcore: 
	$(XML2RFC) draft-farrell-tls-wkesni.xml

upload:
	scp draft-farrell-tls-wkesni.txt  down.dsg.cs.tcd.ie:/var/www/misc/draft-farrell-tls-wkesni.txt
	scp draft-farrell-tls-wkesni.xml  down.dsg.cs.tcd.ie:/var/www/misc/draft-farrell-tls-wkesni.xml

backuup:
	- mkdir backups
	cp draft-farrell-tls-wkesni.txt backups/draft-farrell-tls-wkesni-$(DATE).txt
	cp draft-farrell-tls-wkesni.xml backups/draft-farrell-tls-wkesni-$(DATE).xml

clean:
	rm -f   draft-farrell-tls-wkesni.txt *~

