# route53-updater

Push updates to AWS route53 

## Configuration 

Copy the skeleton file and adjust the configuration parameter.

```shell
cp route53.env.skel route53.env
```

```shell
cat route53.env
UPDATE_INTERVAL=900
ROUTE53_HOSTED_ZONE_ID=<ID>
ROUTE53_HOSTNAME=<hostname, e.g. rpi>
ROUTE53_DOMAIN=<domain, e.g. your-route53-domain.com>
ROUTE53_TTL=600
RECORD_TYPES=A
AWS_ACCESS_KEY_ID=<ACCESS_KEY>
AWS_SECRET_ACCESS_KEY=<SECRET KEY>
```

### Configuration parameters

| Variable                 | Required | Description |
|--------------------------|----------|--------------|
| `ROUTE53_HOSTED_ZONE_ID` | yes      | Your Route 53 Hosted Zone ID (e.g. `ZXC...AMPLE`). |
| `ROUTE53_HOSTNAME`       | yes      | The host/record name to update (e.g. `rpi`). |
| `ROUTE53_DOMAIN`         | yes      | The domain the hostname lives under (e.g. `your-route53-domain.com`). Combined with `ROUTE53_HOSTNAME` to form the FQDN. |
| `UPDATE_INTERVAL`        | no       | If set, the script runs in a loop, updating every this many seconds. If unset, it runs once and exits. |
| `ROUTE53_TTL`            | no       | TTL (seconds) applied to updated records. Default: `600`. |
| `RECORD_TYPES`           | no       | Space separated list of record types (`A` and/or `AAAA`) to create when **neither** an A nor an AAAA record exists yet for the hostname (first-time bootstrap). Default: `A`. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` | yes | AWS credentials with permission to read/write records in the hosted zone. |

The script automatically detects which record type(s) (A/AAAA) already exist
for the configured hostname and only keeps those in sync -- e.g. if only an
AAAA record exists, only the IPv6 address is checked and updated, and the
IPv4/A record is left untouched (and vice versa). `RECORD_TYPES` only comes
into play the very first time, when no record of either type exists yet.

## Build & Run

```shell
docker compose up -d
```
