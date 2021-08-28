package main

import (
	"fmt"
	"io/ioutil"
	"os"

	"github.com/Mic92/sops-nix/pkgs/sops-install-secrets/agessh"
)

func main() {
	if len(os.Args) != 2 {
		println("Usage: " + os.Args[0] + " [path to ssh private key]")
		os.Exit(1)
	}

	sshKey, err := ioutil.ReadFile(os.Args[1])
	if err != nil {
		panic(fmt.Errorf("Cannot read ssh key '%s': %w", os.Args[1], err))
	}

	// Convert the key to bech32
	bech32, err := agessh.SSHPrivateKeyToBech32(sshKey)
	if err != nil {
		panic(fmt.Errorf("Cannot convert ssh key '%s': %w", os.Args[1], err))
	}
	fmt.Println(bech32)
}
