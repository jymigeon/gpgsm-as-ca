# gpgsm-as-ca

How to turn an OpenPGP card into a low-end certificate authority HSM

# Introduction

For a few different (good) reasons, you might be in need of running a X.509
PKI CA backed up by an (HSM)[1]:
* to store (and sometimes generate) its private key onto the device to
prevent its extraction;
* avoid copying the private key around, but still offer the possibility
for others to issue and sign certificates through a GUI or CLI;
* for performance or HA reasons.

Keylength recommendations [2] can make it difficult to use systems like
PIV [3] or the PKCS11 interfaces provided by low-tier devices as they
are often restricted to RSA with a maximum modulus size of 2048 bits.
EC (or bigger RSA moduli) become only available with high-tier HSMs
which can be costly.

The present document explains how an OpenPGP card could be used
as a low cost HSM. Additionally a script []() shows how new end-entity
certificate could be created in a semi-automated way through a combination
of `gpgsm` and `openssl`.

Note that the following short guide is not meant to be a drop-in
replacement for real, certified solutions (like FIPS 140-2 if mandatory). If
your environment requires this kind of equipment, go get one.

# Card initialization and CA creation

To store and use a CA key with an OpenPGP card, you need:
* an OpenPGP card, obviously. The present guide has been tested with Yubikeys 4;
* have GnuPG 2.1+ installed;
* have a PIN and Admin PIN ready;
* an (offline) host to generate the public/private key pair, and upload it
to the card. Required if you need to keep a backup of the key somewhere,
or need to upload it to multiple cards.

## Configure the card

Setup the card with a PIN and Admin PIN. The PIN will be needed for all
subsequent signing operations, and the Admin PIN for the maintenance/admin
mode of the card:

```
# Check that communication with the card is OK
gpg2 --card-status
gpg2 --card-edit
Command> admin
Admin commands are allowed
# Change the PIN and Admin PIN to the one you chose earlier
Command> passwd
# Enter the name of your company, like "company.org", leave firstname empty
Command> name
# Force PIN for signing activity
Command> forcesig
Command> quit
```

## Key generation

You have to make a choice regarding the private key:
* either you generate the key offline and
upload it to the card. This is the recommended way if you want to build up
your PKI with backup in mind;
* generate the key directly onto the card. The key will never leave the
hardware device so you will not be able to backup it.

Here we chose to generate the key pair through `gpg`,
then proceed to generating a self-signed certificate that will be the CA one.
Note that OpenPGP and X.509 use vastly different formats and standards, so
although we use `gpg` for key generation, the X.509 part will be done through
`gpgsm` instead.

### Generate CA key and upload it to card

We create the keypair locally here. This allows the backup of the key as well as
use multiple smartcards to store multiple copies of it.

Adapt the names and email address to your likings. Those will be used throughout
for `gpg`, but will not matter for X.509 certificate creation.

```
# today + 10 years for expiry date
EXPIRY_DATE=$(expr $(date +%Y) + 10)-$(date +%m-%d)
# Generate key locally. Choose algorithms supported by your card!
gpg2 --gen-key --batch << EOF
Key-Type: RSA
Key-Length: 4096
Name-Real: company.org CA
Name-Email: security@company.org
Expire-Date: $EXPIRY_DATE
Key-Usage: cert,sign
EOF
# Optional: save the key
gpg2 --export-secret-key security@company.org > key.gpg
# Now upload the key to the smartcard
gpg2 --edit-key security@company.org
gpg> keytocard
Really move the primary key? (y/N) y
Please select where to store the key:
   (1) Signature key
   (3) Authentication key
Your selection? 1
Replace existing key? (y/N) y
gpg> quit
Save changes? (y/N) y
# Note down the Key-Grip of the CA private key, we will need it later
gpg2 --list-secret-keys --with-keygrip security@company.org
...
Keygrip = 6139BC175842700D7310952D9A2CAC081B55FC09
Card serial no. = <OpenPGP card-id>
...
```

The CA private key is now stored on the smartcard. We proceed
to the creation of a self-signed certificate, but first we need 
to gather some information to issue properly formatted X.509 certificates.

# Create a certificate

## Random musing with PGP cards

This procedure assumes you have an OpenPGP smartcard that contains a
key usable for certification (a *Signature key*), as done previously:

```
gpg2 --card-status
[...]
Signature key ....: 96FC AA94 26F9 8AAB [...]
      created ....: 2017-01-24 10:13:21
[...]
```

If there is one, we can issue X.509 certificate signing requests and
get those signed by the key. The newly created certificate will
therefore be /certified/ by the corresponding CA.

If the private key is not part of the current keyring, you can still
issue certificate as long as you know the Keygrip associated with the key.
By convention slot 1 is used
for cert,sign types (e.g. OPENPGP.1) on the card:

```
# Get the different Keygrips known by the connected smartcard
# We will take the one for OPENPGP.1
echo "LEARN --sendinfo" | gpg-connect-agent | grep KEYPAIRINFO
S KEYPAIRINFO 365FF87A1DB5D0D6ABB3F49C7A773B76636E87EF OPENPGP.2
S KEYPAIRINFO 6139BC175842700D7310952D9A2CAC081B55FC09 OPENPGP.1
...
```

X.509 certificates often come with extensions, like *AuthorityKeyIdentifier* (AKI), *SubjectKeyIdentifier* (SKI), *Key Usage* or *Basic Constraints*.
`gpgsm` does not necessarily take care of all those by
itself, so we have to perform a few extra steps to manage these extensions.

The process is typically as followed:
1. gather the various values we need to craft a proper X.509 certificate;
1. prepare a CSR for `gpgsm` to work with;
1. sign the generated certificate via `gpgsm`, thanks to the created CSR.

The main difference between the (root) CA certificate and an end-entity one
is that it will be self-signed, whereas end-entity certificates are not
(their public key is different from the CA one for obvious reasons).

## Generate a self-signed certificate

### Gather X.509 extension values

```
# Export the public key in SSH format, then convert it to PEM
FPR=$(gpg2 --with-colons --list-key security@company.org \
	| grep '^fpr' | cut -d: -f10)
gpg2 --export-ssh-key "$FPR"'!' | ssh-keygen -e -m PKCS8 -f /dev/stdin > pub.pem

# Compute SKI (SubjectKeyIdentifier). 
SKI=$(openssl asn1parse -strparse 19 -noout -in pub.pem -out /dev/stdout | \
	openssl dgst -sha1 -r /dev/stdin | cut -d" " -f1)
# The Name-DN and Issuer-DN that will be the one from our own CA.
CA_NAME="EMail=security@company.org, CN=Company.org CA, OU=Security, O=CompanyOrg, L=YourLocality, ST=YourState, C=XX"
# Expiration: T + 10 years
EXPIRY_DATE=$(expr $(date +%Y) + 10)-$(date +%m-%d)
# Use batch mode, and generate a certificate with the correct Constraints and KU
# Note that Keygrip and Signing-key match, because we are self-signing here
gpgsm --gen-key --batch << EOF | openssl x509 -inform DER -out cacert.pem
Key-Type: RSA
Key-Grip: 6139BC175842700D7310952D9A2CAC081B55FC09
Subject-Key-Id: $SKI
Name-DN: $CA_NAME
Issuer-DN: $CA_NAME
Serial: random
Hash-Algo: SHA256
Not-After: $EXPIRY_DATE
Signing-Key: 6139BC175842700D7310952D9A2CAC081B55FC09
# x509 extensions. Format is <OID> [nc] <hex-value>
# n: non-critical, c: critical
# BasicConstraints: CA:TRUE
Extension: 2.5.29.19 c 30030101FF
# KeyUsage: Certificate Sign, CRL Sign
Extension: 2.5.29.15 c 03020106
EOF
```

You know should have a proper CA certificate in /cacert.pem/ .

## Generate a new key pair and end-entity certificate(s)

End-entity certificates follow almost the exact same example as above, except
that:
1. we have to create a new keypair first, the one associated with the entity;
1. the X.509 extensions and DNs will differ.

We will follow the same steps as above. This implies that the CA handles the
keypair generation, which is not necessarily the case in more robust setups
(entity keeps its private key secret and only share its public key).

```
# we need the entity's public key. You can obtain one from multiple ways,
# from receiving a CSR or an already X.509 certificate. You can also
# generate your own keypair, should you manage the private key yourself.
# We will import one from an openssl-req command.
openssl req -x509 -newkey rsa:2048 -keyout private-key.pem -out non-approved-cert.pem
# Set entity name
NAME="EMail=entity@company.org, CN=Entity company.org, OU=Entity, O=CompanyOrg, L=YourLocality, ST=YourState, C=XX"
# Set CA name (required for the Issuer DN)
CA_NAME="EMail=security@company.org, CN=Company.org CA, OU=Security, O=CompanyOrg, L=YourLocality, ST=YourState, C=XX"
# Expire in 3 years
EXPIRY_DATE=$(expr $(date +%Y) + 3)-$(date +%m-%d)
# The entity's AuthorityKeyIdentifier shall match the CA's SubjectKeyIdentifier
# You can fetch CA's SKI for its certificate if needed. We re-use the one
# previously set
AKI="$SKI"
# Compute entity's SKI (or grab it directly from cert)
SKI=$(openssl x509 -in non-approved-cert.pem -pubkey -outform DER | \
    openssl asn1parse -strparse 19 -noout -out /dev/stdout | \
    openssl dgst -sha1 -r /dev/stdin | cut -d" " -f1)
# Import the non-yet approved certificate into keyring
gpgsm --import non-approved-cert.pem
# We need its associated keygrip
gpgsm --list-keys --with-keygrip
...
keygrip: D3513A1ED332557D9654CF547DD3848E0BDB6D35
# We can now proceed to issuing the entity's certificate.
gpgsm --gen-key --batch << EOF | openssl x509 -inform DER -out entity-cert.pem
Key-Type: RSA
Key-Grip: D3513A1ED332557D9654CF547DD3848E0BDB6D35
Authority-Key-Id: $AKI
Subject-Key-Id: $SKI
Name-DN: $NAME
Issuer-DN: $CA_NAME
Serial: random
Hash-Algo: SHA256
Not-After: $EXPIRY_DATE
Signing-Key: 6139BC175842700D7310952D9A2CAC081B55FC09
# x509 extensions for entity cert -- like a webserver here
# BasicConstraints: CA:FALSE
Extension: 2.5.29.19 c 3000
# KeyUsage: Digital Signature, Key Encipherment
Extension: 2.5.29.15 c 030205A0
# ExtendedKeyUsage: Web Server Authentication, Web Client Authentication
Extension: 2.5.29.37 n 301406082B0601050507030106082B06010505070302
EOF
```

You shall know have the end-entity certificate found in /entity-cert.pem/.

# Typical X.509 extensions and values

Incoming!

# Conclusion

Given the rich set of features now available through GPGSM, there is no real
reason anymore to keep having your devops and system administrators copy/paste
the private key of your internal CA all around, or (worse) commit it to some
random public repository and share the password via chat or SMS.

For convenience, an example script to generate new keypairs is attached.
It allows someone to almost completely provision new entities signed by the CA
on demand, as long as he manages to know the OpenPGP card PIN.

[1] https://en.wikipedia.org/wiki/Hardware_security_module
[2] https://www.keylength.com/
[3] https://csrc.nist.gov/Projects/PIV
