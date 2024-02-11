#!/usr/bin/bash
SCRIPTDIR=$(dirname $0)

## FOCUS-vpn-wrapper.sh
# This script is a wrapper for the poor employees of the Focus team who cannot use the RDM for the VPN.
# Usage: FOCUS-vpn-wrapper.sh <host> [username]

# Config:
CONFIG_PATH_TO_CHROME=/opt/google/chrome/google-chrome # todo: make this configurable
CONFIG_PATH_TO_VPNCONFIGFOLDER=$SCRIPTDIR/openvpncfg
#####################

HOST=$1
USERNAME=${2:-vpnuser}

# check if the host parameter is set
if [ -z "$HOST" ]; then
    echo "Usage: $0 <host> [username]"
    exit 1
fi

# check if the vpn config folder exists
echo "Checking if the vpn config folder exists..."
if [ ! -d "$CONFIG_PATH_TO_VPNCONFIGFOLDER" ]; then
    echo "The vpn config folder does not exist. Try to create it with 'mkdir -p $CONFIG_PATH_TO_VPNCONFIGFOLDER'"
    exit 1
fi

# check if the tmp folder exists for cookies or create it
if [ ! -d "$SCRIPTDIR/tmp" ]; then
    echo "The tmp folder does not exist. Try to create it with 'mkdir -p $SCRIPTDIR/tmp'"
    exit 1
fi

# check if the cookies file exists or create it
if [ ! -f "$SCRIPTDIR/tmp/cookies" ]; then
    touch $"SCRIPTDIR"/tmp/cookies
fi

# check if the chrome binary exists
echo "Checking if the chrome binary exists..."
if [ ! -f "$CONFIG_PATH_TO_CHROME" ]; then
    echo "The chrome binary does not exist. Please check the path in the script."
    exit 1
fi

# load loginpage for captchadata (hex) and assign it to variable
echo "Fetching the captcha..."
CAPTCHA_Challenge=$(curl --cookie-jar $SCRIPTDIR/tmp/cookies \
                        --cookie $SCRIPTDIR/tmp/cookies \
                        -k \
                        -s \
                        "https://$HOST/userportal/webpages/myaccount/login.jsp" | \
                        sed -n '/<div class="captcha-container">/,/<\/div>/p')


# open captcha in browser
# appmode to hide addressbar and tabs + move and resize window with javascript
google-chrome --app="data:text/html,<html><header><title>Captcha</title></header><body>$CAPTCHA_Challenge<script>window.moveTo(0, 0);window.resizeTo(200,100);</script></body></html>"

# read captcha and password from user
read -p "Please enter the captcha: " CAPTCHA_Response
read -p "Please enter the password for $USERNAME:" -s PASSWORD


# authenticate and save the cookie
HTTPCode=$(curl --cookie $SCRIPTDIR/tmp/cookies \
                    --cookie-jar $SCRIPTDIR/tmp/cookies \
                    --data-urlencode "mode=451" \
                    --data-urlencode "t=$(date +%s)" \
                    --data-urlencode 'json={"username":"'$USERNAME'","password":"'$PASSWORD'","languageid":1,"captcha":"'$CAPTCHA_Response'"}' \
                    --header 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
                    -o - \
                    -k \
                    -s \
                    --write-out '%{http_code}' \
                    "https://${HOST}/userportal/Controller")

# check if authentication was successful
if [[ "$HTTPCode" == *"-1"* ]]; then
    echo "Authentication failed. Please check your credentials and try again."
    exit 1
  fi
echo "Authentication successful."


# grep csfr token
echo "Fetching the CSRF token..."
CyberoamCSRFToken=$(curl --cookie $SCRIPTDIR/tmp/cookies \
                    --cookie-jar $SCRIPTDIR/tmp/cookies \
                    -o - \
                    -k \
                    -s \
                    "https://${HOST}/userportal/webpages/myaccount/index.jsp" | sed -n "s/.*Cyberoam.c\$rFt0k3n = '\([^']*\)';.*/\1/p")


# fetch the config with authentication cookie
echo "Fetching the config with authentication cookie..."
curl --cookie $SCRIPTDIR/tmp/cookies \
      -X POST \
     -o $CONFIG_PATH_TO_VPNCONFIGFOLDER/"$HOST".openvpn \
     --header 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
     --referer "https://${HOST}/userportal/webpages/myaccount/index.jsp" \
     --data-urlencode 'csrf='"$CyberoamCSRFToken" \
     -k \
     --url "https://${HOST}/userportal/webpages/sslvpnuserportal/clientdownload.jsp?download=sslvpnclient&ipaddress=0&type=config-generic"

# comment the unsupported route option
echo "Commenting the unsupported route option..."
sed -i 's/^route/#route/' $CONFIG_PATH_TO_VPNCONFIGFOLDER/"$HOST".openvpn

# import the config into networkmanager
echo "Importing the config into networkmanager..."
nmcli connection import type openvpn file $CONFIG_PATH_TO_VPNCONFIGFOLDER/"$HOST".openvpn

# write credentials to the connection
echo "Writing credentials to the connection..."
nmcli connection modify $HOST vpn.user-name $USERNAME
nmcli connection modify $HOST vpn.secrets password=$PASSWORD

# set the default route only to the vpn networks
echo "Setting default route only to the vpn networks..."
nmcli connection modify $HOST ipv4.never-default yes

# connect
echo "Connecting to $HOST..."
nmcli connection up $HOST
