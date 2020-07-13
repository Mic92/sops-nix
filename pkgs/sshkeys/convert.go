package sshkeys

import (
	"crypto"
	"crypto/rsa"
	"fmt"
	"reflect"
	"time"

	"golang.org/x/crypto/openpgp"
	"golang.org/x/crypto/openpgp/packet"
	"golang.org/x/crypto/ssh"
)

func parsePublicKey(publicKey []byte) (*rsa.PublicKey, error) {
	key, _, _, _, err := ssh.ParseAuthorizedKey(publicKey)
	if err != nil {
		return nil, fmt.Errorf("failed to parse public ssh key: %s", err)
	}

	cryptoPublicKey, ok := key.(ssh.CryptoPublicKey)

	if !ok {
		return nil, fmt.Errorf("Unsupported public key algo: %s", key.Type())
	}

	rsaKey, ok := cryptoPublicKey.CryptoPublicKey().(*rsa.PublicKey)

	if !ok {
		return nil, fmt.Errorf("Unsupported public key algo: %s", key.Type())
	}

	return rsaKey, nil
}

func SSHPublicKeyToPGP(sshPublicKey []byte) (*packet.PublicKey, error) {
	rsaKey, err := parsePublicKey(sshPublicKey)
	if err != nil {
		return nil, err
	}
	return packet.NewRSAPublicKey(time.Unix(0, 0), rsaKey), nil
}

func parsePrivateKey(sshPrivateKey []byte) (*rsa.PrivateKey, error) {
	privateKey, err := ssh.ParseRawPrivateKey(sshPrivateKey)
	if err != nil {
		return nil, err
	}

	rsaKey, ok := privateKey.(*rsa.PrivateKey)

	if !ok {
		return nil, fmt.Errorf("Only RSA keys are supported right now, got: %s", reflect.TypeOf(privateKey))
	}

	return rsaKey, nil
}

func SSHPrivateKeyToPGP(sshPrivateKey []byte) (*openpgp.Entity, error) {
	key, err := parsePrivateKey(sshPrivateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private ssh key: %s", err)
	}

	// Let's make keys reproducible
	timeNull := time.Unix(0, 0)

	gpgKey := &openpgp.Entity{
		PrimaryKey: packet.NewRSAPublicKey(timeNull, &key.PublicKey),
		PrivateKey: packet.NewRSAPrivateKey(timeNull, key),
		Identities: make(map[string]*openpgp.Identity),
	}
	uid := packet.NewUserId("root", "", "root@localhost")
	isPrimaryID := true
	gpgKey.Identities[uid.Id] = &openpgp.Identity{
		Name:   uid.Id,
		UserId: uid,
		SelfSignature: &packet.Signature{
			CreationTime:              timeNull,
			SigType:                   packet.SigTypePositiveCert,
			PubKeyAlgo:                packet.PubKeyAlgoRSA,
			Hash:                      crypto.SHA256,
			IsPrimaryId:               &isPrimaryID,
			FlagsValid:                true,
			FlagSign:                  true,
			FlagCertify:               true,
			FlagEncryptStorage:        true,
			FlagEncryptCommunications: true,
			IssuerKeyId:               &gpgKey.PrimaryKey.KeyId,
		},
	}

	return gpgKey, nil
}
