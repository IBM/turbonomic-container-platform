#!/usr/bin/env bash

set -euo pipefail

#########################################
# Edit host and credentials
host='https://<TURBO-SERVER>'
creds='username=<UNAME>&password=<PSWD>'
#########################################

acceptj="-H 'accept: application/json'"
contentj="-H 'content-type: application/json'"
loginep='api/v3/login'
tep='vmturbo/rest/targets'

# get session cookie
printf "\nConnecting to $host\n"
scookie=$(curl $host/$loginep -c - -skX POST -H 'content-type: application/x-www-form-urlencoded' -d $creds | grep -i session | awk '{print $6 "=" $7}')

# get target Uuids for connected k8s targets that require upgrading
printf "\nGet k8s target list\n"
curlCMD="curl -sk '$host/$tep?target_type=KUBERNETES&target_type=PROMETHEUS&health_state=MAJOR' -b $scookie $acceptj | jq -r '.[].uuid'"
targets=($(eval "$curlCMD"))
printf "Number of targets to process: ${#targets[@]}\n\n"

# upgrade one by one
for item in "${targets[@]}"; do 
    printf "Upgrade $item => ";
    curlCMD="curl -skX POST '$host/$tep/$item/upgrades' -b $scookie $acceptj $contentj -d '{}'";
    eval "$curlCMD";
    echo
done
printf "\nDone\n"
