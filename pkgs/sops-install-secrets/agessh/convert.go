package agessh

import (
	"crypto/ed25519"
	"crypto/sha512"
	"fmt"
	"reflect"
	"strings"

	"github.com/Mic92/sops-nix/pkgs/bech32"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/ssh"
)

func ed25519PrivateKeyToCurve25519(pk ed25519.PrivateKey) ([]byte, error) {
	h := sha512.New()
	_, err := h.Write(pk.Seed())
	if err != nil {
		return []byte{}, err
	}
	out := h.Sum(nil)
	return out[:curve25519.ScalarSize], nil
}

func SSHPrivateKeyToBech32(sshPrivateKey []byte) (string, error) {
	privateKey, err := ssh.ParseRawPrivateKey(sshPrivateKey)
	if err != nil {
		return "", err
	}

	ed25519Key, ok := privateKey.(*ed25519.PrivateKey)
	if !ok {
		return "", fmt.Errorf("Only ED25519 keys are supported, got: %s", reflect.TypeOf(privateKey))
	}
	bytes, err := ed25519PrivateKeyToCurve25519(*ed25519Key)
	if err != nil {
		return "", err
	}

	s, err := bech32.Encode("AGE-SECRET-KEY-", bytes)
	if err != nil {
		return "", err
	}
	return strings.ToUpper(s), nil
}
