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
ROUTE53_DOMAIN_NAME=<fqdn>
AWS_ACCESS_KEY_ID=<ACCESS_KEY>
AWS_SECRET_ACCESS_KEY=<SECRET KEY>
```

## Build & Run

```shell
docker compose up -d
```
