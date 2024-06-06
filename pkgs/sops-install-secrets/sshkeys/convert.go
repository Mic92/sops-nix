package sshkeys

import (
	"crypto"
	"crypto/rsa"
	"fmt"
	"reflect"
	"time"

	"github.com/ProtonMail/go-crypto/openpgp"
	"github.com/ProtonMail/go-crypto/openpgp/packet"
	"golang.org/x/crypto/ssh"
)

func parsePrivateKey(sshPrivateKey []byte) (*rsa.PrivateKey, error) {
	privateKey, err := ssh.ParseRawPrivateKey(sshPrivateKey)
	if err != nil {
		return nil, err
	}

	rsaKey, ok := privateKey.(*rsa.PrivateKey)

	if !ok {
		return nil, fmt.Errorf("only RSA keys are supported right now, got: %s", reflect.TypeOf(privateKey))
	}

	return rsaKey, nil
}

func SSHPrivateKeyToPGP(sshPrivateKey []byte) (*openpgp.Entity, error) {
	key, err := parsePrivateKey(sshPrivateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private ssh key: %w", err)
	}

	// Let's make keys reproducible
	timeNull := time.Unix(0, 0)

	gpgKey := &openpgp.Entity{
		PrimaryKey: packet.NewRSAPublicKey(timeNull, &key.PublicKey),
		PrivateKey: packet.NewRSAPrivateKey(timeNull, key),
		Identities: make(map[string]*openpgp.Identity),
	}
	uid := packet.NewUserId("root", "Imported from SSH", "root@localhost")
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
	err = gpgKey.Identities[uid.Id].SelfSignature.SignUserId(uid.Id, gpgKey.PrimaryKey, gpgKey.PrivateKey, nil)
	if err != nil {
		return nil, err
	}

	return gpgKey, nil
}
