package main

import (
	"bufio"
	"crypto/ed25519"
	"errors"
	"fmt"
	"os"
	"strings"

	"filippo.io/edwards25519"
	"github.com/Mic92/sops-nix/pkgs/bech32"
	"golang.org/x/crypto/ssh"
)

func ed25519PublicKeyToCurve25519(pk ed25519.PublicKey) ([]byte, error) {
	// See https://blog.filippo.io/using-ed25519-keys-for-encryption and
	// https://pkg.go.dev/filippo.io/edwards25519#Point.BytesMontgomery.
	p, err := new(edwards25519.Point).SetBytes(pk)
	if err != nil {
		return nil, err
	}
	return p.BytesMontgomery(), nil
}

func main() {
	if len(os.Args) != 1 {
		println("Usage: " + os.Args[0])
		println("Pipe a SSH public key or the output of ssh-keyscan into it")
		os.Exit(1)
	}

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		text := scanner.Text() + "\n"
		var err error
		var pk ssh.PublicKey
		if strings.HasPrefix(text, "ssh-") {
			pk, _, _, _, err = ssh.ParseAuthorizedKey([]byte(text))
		} else {
			_, _, pk, _, _, err = ssh.ParseKnownHosts([]byte(text))
		}
		if err != nil {
			panic(err)
		}
		// We only care about ed25519
		if pk.Type() != ssh.KeyAlgoED25519 {
			continue
		}
		// Get the bytes
		cpk, ok := pk.(ssh.CryptoPublicKey)
		if !ok {
			panic(errors.New("pk does not implement ssh.CryptoPublicKey"))
		}
		epk, ok := cpk.CryptoPublicKey().(ed25519.PublicKey)
		if !ok {
			panic(errors.New("unexpected public key type"))
		}
		// Convert the key to curve ed25519
		mpk, err := ed25519PublicKeyToCurve25519(epk)
		if err != nil {
			panic(fmt.Errorf("invalid Ed25519 public key: %v", err))
		}
		// Encode the key
		s, err := bech32.Encode("age", mpk)
		if err != nil {
			panic(err)
		}
		fmt.Println(s)
	}
	if err := scanner.Err(); err != nil {
		panic(err)
	}
}
