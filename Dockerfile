# Use an Alpine Linux base image for its small size
FROM alpine:latest

# Install necessary packages: curl, bash, and the AWS CLI.
#  - curl:  For fetching the external IP address.
#  - bash: For running the script.
#  - aws-cli: For interacting with Amazon Route 53.
RUN apk add --no-cache curl bash aws-cli jq

# Copy the script into the container.  It's good practice to put it in /usr/local/bin
COPY route53_update.sh /usr/local/bin/run.sh

# Make the script executable.  This is essential for it to run.
RUN chmod +x /usr/local/bin/run.sh

# Set the entrypoint to execute the script.
#  - This means that when the container runs, it will execute this script.
ENTRYPOINT ["/usr/local/bin/run.sh"]

#  Define the environment variables that the script expects.
#  -  These are *not* set to real values here.  The user will provide them
#     when running the container (using  `docker run -e ...`).
#  -  It's crucial to define them here as documentation for the user.
ENV ROUTE53_HOSTED_ZONE_ID=""
ENV ROUTE53_DOMAIN_NAME=""
ENV AWS_ACCESS_KEY_ID=""
ENV AWS_SECRET_ACCESS_KEY=""
ENV AWS_DEFAULT_REGION=""
ENV UPDATE_INTERVAL=""

#  The working directory doesn't matter much for this script, but setting it
#  is generally good practice.
WORKDIR /app

