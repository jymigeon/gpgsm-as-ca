#!/bin/sh

# This script is used to generate a key + cert that needs to be signed by
# a CA managed through an OpenPGP card (on which the CA's private key is
# stored).

# Bail out as soon as something goes wrong.
set -eu

_cleanup() {
	gpgconf --kill gpg-agent
	if [ -d "$TMPDIR" ]; then
		rm -rf "$TMPDIR"
	fi
	exit 1
}
trap _cleanup EXIT INT TERM
TMPDIR=$(mktemp -d)

usage() {
	exec >&2
	echo "Usage: ${0##/*}: <conf-file> <basename>"
	echo "  conf-file: path to the configuration file"
	echo "  basename : basename for entity's PKCS12 and PEM files"
	exit 1
}

_setup() {
	CONF_FILE="$1"

	if [ ! -r "$CONF_FILE" ]; then
		echo "conf-file: \`$CONF_FILE' is not a readable configuration file." 1>&2
		usage
	fi

	# Loop and escape all conf variables for sed(1) and construct
	# command out of the variables specified in conf file
	. "$CONF_FILE"
	VARS="NAMEDN KEYTYPE SIZE HASH DATE ALIAS KEYUSAGE EKEYUSAGE"
	VARS="$VARS CADN AKI SIGNINGKEY PASSPHRASE"
	SEDCMD=""
	for VAR in $VARS; do
		VAL=$(eval echo "\$$VAR" | sed -e 's/[\/&|]/\\&/g')
		eval $VAR='$VAL'
		export "$VAR"
		export SEDCMD="s|@$VAR@|$VAL|g;$SEDCMD"
	done

	if [ "$KEYTYPE" != "RSA" ]; then
		echo "Only RSA Key-Type is supported." 1>&2
		usage
	fi

	# Skeletons and their generation targets
	export EDIR=${0%/*}
	export CSR_SKEL="$EDIR/gpgsm.csr.skel"
	export CSR_CFG="$TMPDIR/gpgm.csr"
	export PIN_PRGM="$(pwd)/$EDIR/pinentry-standalone"
	if [ ! -x "$PIN_PRGM" ]; then
		echo "Fixing \`$PIN_PRGM\' rights: adding u+x"
		chmod u+x "$PIN_PRGM"
	fi

	# Temporary directory and files, for GPGSM
	export GNUPGHOME="$TMPDIR"
	export PRIVKEY="$TMPDIR/privkey.pem"
	export CERTFILE="$TMPDIR/cert.pem"
	export P12FILE="$TMPDIR/third-party.p12"
	export DERFILE="$TMPDIR/third-party.der"

	# Final targets
	export FINALPEM="${BASENAME}.pem"
	export FINALP12="${BASENAME}.p12"
	export FINALJKS="${BASENAME}.jks"
}

# RSA key + CSR (through GPGSM) generation step.
_gen_csr() {
	# Generate RSA key and a scratch self-signed certificate
	openssl req -x509 -newkey rsa:"$SIZE" -out "$CERTFILE" \
	    -passout env:PASSPHRASE -keyout "$PRIVKEY" -subj '/CN=placeholder/'
	# Compute Subject Key Identifier
	SKI=$(openssl x509 -in "$CERTFILE" -pubkey -outform DER | \
	    openssl asn1parse -strparse 19 -noout -out /dev/stdout | \
	    openssl dgst -sha1 -r /dev/stdin | cut -d" " -f1)
	# GPGSM only accepts importing private keys using PKCS12, so
	# we need to create one.
	openssl pkcs12 -export -passout env:PASSPHRASE -out "$P12FILE" \
	    -passin env:PASSPHRASE -inkey "$PRIVKEY" -in "$CERTFILE"
	# Import keypair into gpgsm
	gpg-agent -q --pinentry-program "$PIN_PRGM" --daemon
	gpgsm --import "$P12FILE"
	# Get associated keygrip
	KGRIP=$(gpgsm --dump-cert | awk '/keygrip:/ {print $2}')
	# Write down the CSR for the imported self-signed cert
	sed -e "s|@KGRIP@|$KGRIP|g;s|@SKI@|$SKI|g;$SEDCMD" \
	    "$CSR_SKEL" > "$CSR_CFG"

	echo
	echo "==============================================================="
	echo "The following CSR has been created:"
	echo "==============================================================="
	cat  "$CSR_CFG"
	echo "==============================================================="
}

_sign_csr() {
	printf "Proceed to signing? [Y/N]"
	while true; do
		read ANSWER
		case $ANSWER in
		[yY] ) break;;
		[nN] ) exit;;
		* ) printf "Please answer (Y)es or (N)o:";;
	    esac
	done

	gpgconf --kill gpg-agent
	gpgsm --learn-card
	gpgsm --gen-key --batch "$CSR_CFG" > "$DERFILE"
	# Copy over the final PEMs and PKCS12 files to final destination
	openssl x509 -inform DER -in "$DERFILE" -outform PEM -out "$FINALPEM"
	cat "$PRIVKEY" >> "$FINALPEM"
}

_fini() {
	# Generate a PKCS12 file
	openssl pkcs12 -export -passin "env:PASSPHRASE" -in "$FINALPEM" \
	    -passout "env:PASSPHRASE" -out "$FINALP12" -name "$ALIAS"

	echo 
	echo "The following third-party files were generated:"
	echo "  $FINALPEM : PEM file with private key and signed cert"
	echo "  $FINALP12 : PKCS12 file with private key and signed cert"
	echo
	echo "Private elements are protected with the following password:"
	echo "  $PASSPHRASE"
	echo "under alias:"
	echo "  $ALIAS"
	echo
	echo "You can verify the validity of the certificate via openssl":
	echo "  openssl verify -x509_strict -CAfile <your-ca-cert.pem> \"$FINALPEM\""
}

if [ $# -ne 2 ]; then
	usage
fi
export CONF_FILE="$1"
export BASENAME="$2"

_setup "$CONF_FILE"
_gen_csr
_sign_csr
_fini
