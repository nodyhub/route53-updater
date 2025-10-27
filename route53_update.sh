#!/bin/bash

# This script updates a Route 53 A record with the current external IP address of the machine.
# It checks if the IP address has changed before updating.
# It can optionally run in a loop to periodically update the IP address.
#
## Source of the idea: https://unix.stackexchange.com/a/410518

# **Important:**
# * Ensure the following environment variables are set:
# * `ROUTE53_HOSTED_ZONE_ID`: Your Route 53 Hosted Zone ID (e.g., ZXC...AMPLE)
# * `ROUTE53_DOMAIN_NAME`: The hostname to update (e.g., rpi.your-route53-domain.com)
# * Ensure the AWS CLI is installed and configured with appropriate permissions to update Route 53 records.
# * You can configure it using `aws configure`.
# * Optional:
# * `UPDATE_INTERVAL`:  If set, the script will run in a loop, updating the IP every this many seconds.
# * For example, set UPDATE_INTERVAL=300 to update every 5 minutes.

# Log function to prepend timestamp
log() {
  echo "$(date -Iseconds) $@"
}

# Check if required environment variables are set
if [ -z "$ROUTE53_HOSTED_ZONE_ID" ] || [ -z "$ROUTE53_DOMAIN_NAME" ]; then
  log "Error:  Both ROUTE53_HOSTED_ZONE_ID and ROUTE53_DOMAIN_NAME environment variables must be set."
  log "  For example:"
  log "  export ROUTE53_HOSTED_ZONE_ID=ZXCVBNMEXAMPLE"
  log "  export ROUTE53_DOMAIN_NAME=rpi.your-route53-domain.com"
  exit 1
fi

# Check if UPDATE_INTERVAL is set
if [ -n "$UPDATE_INTERVAL" ] && ! [[ "$UPDATE_INTERVAL" =~ ^[0-9]+$ ]]; then
  log "Error: UPDATE_INTERVAL must be a positive integer (number of seconds)."
  exit 1
fi

# Function to perform the IP update
update_ip() {
  # Get the external IP address
  RPI_EXT_IP=$(curl -s http://ifconfig.co)
  if [ $? -ne 0 ]; then
    log "Failed to retrieve external IP address."
    return 1 # Use return instead of exit, so the loop continues
  fi
  log "Current external IP address: $RPI_EXT_IP"

  # Get the current Route 53 record value
  CURRENT_RECORD_VALUE=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
      --query "ResourceRecordSets[?Name == '$ROUTE53_DOMAIN_NAME.'][].ResourceRecords" \
      --output text)

  if [ $? -ne 0 ]; then
    log "Failed to retrieve current Route 53 record."
    return 1 #  Use return instead of exit
  fi

  log "Current Route53 record value: $CURRENT_RECORD_VALUE"

  # Check if the IP address has changed
  if [ "$RPI_EXT_IP" = "$CURRENT_RECORD_VALUE" ]; then
    log "IP address has not changed.  No update needed."
    return 0
  fi

  # Create the JSON file for the Route 53 update
  cat > /tmp/r53-update.json <<__EOF__
  {
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "$ROUTE53_DOMAIN_NAME",
          "Type": "A",
          "TTL": 600,
          "ResourceRecords": [
            {
              "Value": "${RPI_EXT_IP}"
            }
          ]
        }
      }
    ]
  }
__EOF__

  log "JSON file created: /tmp/r53-update.json"
  cat /tmp/r53-update.json

  # Update the Route 53 record
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
    --change-batch file:///tmp/r53-update.json

  if [ $? -ne 0 ]; then
    log "Failed to update Route 53 record."
    return 1 # Use return instead of exit
  fi

  log "Route 53 record updated successfully."

  # Optionally, you can delete the temporary JSON file:
  # rm /tmp/r53-update.json
  # echo "Deleted temporary file: /tmp/r53-update.json"
  return 0
}

# Check if UPDATE_INTERVAL is set, and run in a loop if it is.
if [ -n "$UPDATE_INTERVAL" ]; then
  log "Running in a loop, updating every $UPDATE_INTERVAL seconds."
  while true; do
    update_ip
    sleep "$UPDATE_INTERVAL"
  done
else
  # Otherwise, just run the update once.
  update_ip
fi

exit 0

