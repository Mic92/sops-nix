module github.com/Mic92/sops-nix

go 1.14

require (
	github.com/Mic92/ssh-to-age v0.0.0-20210829164312-1fe15380abe4
	github.com/ProtonMail/go-crypto v0.0.0-20210707164159-52430bf6b52c
	github.com/mozilla-services/yaml v0.0.0-20191106225358-5c216288813c
	go.mozilla.org/sops/v3 v3.7.1
	golang.org/x/crypto v0.0.0-20210817164053-32db794688a5
	golang.org/x/sys v0.0.0-20210831042530-f4d43177bf5e
)

// see https://github.com/mozilla/sops/pull/925
replace go.mozilla.org/sops/v3 v3.7.1 => github.com/Mic92/sops/v3 v3.7.2-0.20210829155005-a7cbb9ffe599
