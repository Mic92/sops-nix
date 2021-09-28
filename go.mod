module github.com/Mic92/sops-nix

go 1.14

require (
	cloud.google.com/go v0.94.0 // indirect
	github.com/Azure/azure-sdk-for-go v57.0.0+incompatible // indirect
	github.com/Azure/go-autorest/autorest v0.11.20 // indirect
	github.com/Azure/go-autorest/autorest/adal v0.9.15 // indirect
	github.com/Azure/go-autorest/autorest/azure/auth v0.5.8 // indirect
	github.com/Azure/go-autorest/autorest/azure/cli v0.4.3 // indirect
	github.com/Azure/go-autorest/autorest/to v0.4.0 // indirect
	github.com/Azure/go-autorest/autorest/validation v0.3.1 // indirect
	github.com/Mic92/ssh-to-age v0.0.0-20210928145128-a36d587b53c6
	github.com/ProtonMail/go-crypto v0.0.0-20210707164159-52430bf6b52c
	github.com/aws/aws-sdk-go v1.40.34 // indirect
	github.com/cenkalti/backoff/v3 v3.2.2 // indirect
	github.com/fatih/color v1.12.0 // indirect
	github.com/golang/groupcache v0.0.0-20210331224755-41bb18bfe9da // indirect
	github.com/golang/snappy v0.0.4 // indirect
	github.com/hashicorp/errwrap v1.1.0 // indirect
	github.com/hashicorp/go-cleanhttp v0.5.2 // indirect
	github.com/hashicorp/go-multierror v1.1.1 // indirect
	github.com/hashicorp/go-retryablehttp v0.7.0 // indirect
	github.com/hashicorp/vault/api v1.1.1 // indirect
	github.com/howeyc/gopass v0.0.0-20190910152052-7cb4b85ec19c // indirect
	github.com/lib/pq v1.10.2 // indirect
	github.com/mattn/go-isatty v0.0.13 // indirect
	github.com/mitchellh/go-wordwrap v1.0.1 // indirect
	github.com/mitchellh/mapstructure v1.4.1 // indirect
	github.com/mozilla-services/yaml v0.0.0-20201007153854-c369669a6625
	github.com/pierrec/lz4 v2.6.1+incompatible // indirect
	github.com/sirupsen/logrus v1.8.1 // indirect
	go.mozilla.org/sops/v3 v3.7.1
	golang.org/x/crypto v0.0.0-20210817164053-32db794688a5
	golang.org/x/net v0.0.0-20210825183410-e898025ed96a // indirect
	golang.org/x/sys v0.0.0-20210903071746-97244b99971b
	golang.org/x/text v0.3.7 // indirect
	golang.org/x/time v0.0.0-20210723032227-1f47c861a9ac // indirect
	google.golang.org/api v0.56.0 // indirect
	gopkg.in/ini.v1 v1.62.0 // indirect
	gopkg.in/square/go-jose.v2 v2.6.0 // indirect
	gopkg.in/yaml.v3 v3.0.0-20210107192922-496545a6307b // indirect
)

// see https://github.com/mozilla/sops/pull/925
replace go.mozilla.org/sops/v3 v3.7.1 => github.com/Mic92/sops/v3 v3.7.2-0.20210829155005-a7cbb9ffe599
