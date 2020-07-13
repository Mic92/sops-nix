package main

import (
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"syscall"

	"github.com/Mic92/sops-nix/pkgs/sshkeys"
	"golang.org/x/crypto/openpgp"
	"golang.org/x/crypto/openpgp/armor"
	"golang.org/x/crypto/ssh/terminal"
)

type options struct {
	publicKey, privateKey, format, out string
}

func parseFlags(args []string) options {
	var opts options
	f := flag.NewFlagSet(args[0], flag.ExitOnError)
	f.StringVar(&opts.publicKey, "pubkey", "", "Path to public key. Reads from standard input if equal to '-'")
	f.StringVar(&opts.privateKey, "privkey", "", "Path to private key. Reads from standard input if equal to '-'")
	f.StringVar(&opts.format, "format", "auto", "GPG format encoding (auto|binary|armor)")
	f.StringVar(&opts.out, "o", "-", "Output path. Prints by default to standard output")
	f.Parse(args[1:])

	if opts.format == "auto" {
		if opts.out == "-" && terminal.IsTerminal(syscall.Stdout) {
			opts.format = "armor"
		} else {
			opts.format = "binary"
		}
	}
	if opts.publicKey != "" && opts.privateKey != "" {
		fmt.Fprintln(os.Stderr, "-pubkey and -privkey are mutual exclusive")
		os.Exit(1)
	}

	if opts.publicKey == "" && opts.privateKey == "" {
		fmt.Fprintln(os.Stderr, "Either -pubkey and -privkey must be specified")
		os.Exit(1)
	}

	return opts
}

func convertKeys(args []string) error {
	opts := parseFlags(args)
	var err error
	var sshKey []byte
	keyPath := opts.privateKey
	if opts.publicKey != "" {
		keyPath = opts.publicKey
	}
	if keyPath == "-" {
		sshKey, _ = ioutil.ReadAll(os.Stdin)
		if err != nil {
			return fmt.Errorf("error reading stdin: %s", err)
		}
	} else {
		sshKey, err = ioutil.ReadFile(keyPath)
		if err != nil {
			return fmt.Errorf("error reading %s: %s", opts.privateKey, err)
		}
	}

	writer := io.WriteCloser(os.Stdout)
	if opts.out != "-" {
		writer, err = os.Create(opts.out)
		if err != nil {
			return fmt.Errorf("failed to create %s: %s", opts.out, err)
		}
		defer writer.Close()
	}

	if opts.format == "armor" {
		keyType := openpgp.PrivateKeyType
		if opts.publicKey != "" {
			keyType = openpgp.PublicKeyType
		}
		writer, err = armor.Encode(writer, keyType, make(map[string]string))
		if err != nil {
			return fmt.Errorf("failed to encode armor writer")
		}
	}

	if opts.publicKey != "" {
		gpgKey, err := sshkeys.SSHPublicKeyToPGP(sshKey)
		if err != nil {
			return err
		}
		err = gpgKey.Serialize(writer)
	} else {
		gpgKey, err := sshkeys.SSHPrivateKeyToPGP(sshKey)
		if err != nil {
			return err
		}
		err = gpgKey.SerializePrivate(writer, nil)
	}
	if err == nil && opts.format == "armor" {
		writer.Close()
	}
	return err
}

func main() {
	if err := convertKeys(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %s", os.Args[0], err)
		os.Exit(1)
	}
}
