package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/user"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Mic92/sops-nix/pkgs/sops-install-secrets/sshkeys"
	agessh "github.com/Mic92/ssh-to-age"

	"github.com/getsops/sops/v3/decrypt"
	"github.com/joho/godotenv"
	"github.com/mozilla-services/yaml"
	"gopkg.in/ini.v1"
)

type secret struct {
	Name         string     `json:"name"`
	Key          string     `json:"key"`
	Path         string     `json:"path"`
	Owner        *string    `json:"owner,omitempty"`
	UID          int        `json:"uid"`
	Group        *string    `json:"group,omitempty"`
	GID          int        `json:"gid"`
	SopsFile     string     `json:"sopsFile"`
	Format       FormatType `json:"format"`
	Mode         string     `json:"mode"`
	RestartUnits []string   `json:"restartUnits"`
	ReloadUnits  []string   `json:"reloadUnits"`
	value        []byte
	mode         os.FileMode
	owner        int
	group        int
}

type loggingConfig struct {
	KeyImport     bool `json:"keyImport"`
	SecretChanges bool `json:"secretChanges"`
}

type template struct {
	Name         string   `json:"name"`
	Content      string   `json:"content"`
	Path         string   `json:"path"`
	Mode         string   `json:"mode"`
	Owner        *string  `json:"owner,omitempty"`
	UID          int      `json:"uid"`
	Group        *string  `json:"group,omitempty"`
	GID          int      `json:"gid"`
	File         string   `json:"file"`
	RestartUnits []string `json:"restartUnits"`
	ReloadUnits  []string `json:"reloadUnits"`
	value        []byte
	mode         os.FileMode
	content      string
	owner        int
	group        int
}

type manifest struct {
	Secrets                 []secret          `json:"secrets"`
	Templates               []template        `json:"templates"`
	PlaceholderBySecretName map[string]string `json:"placeholderBySecretName"`
	SecretsMountPoint       string            `json:"secretsMountPoint"`
	SymlinkPath             string            `json:"symlinkPath"`
	KeepGenerations         int               `json:"keepGenerations"`
	SSHKeyPaths             []string          `json:"sshKeyPaths"`
	GnupgHome               string            `json:"gnupgHome"`
	AgeKeyFile              string            `json:"ageKeyFile"`
	AgeSSHKeyPaths          []string          `json:"ageSshKeyPaths"`
	UseTmpfs                bool              `json:"useTmpfs"`
	UserMode                bool              `json:"userMode"`
	Logging                 loggingConfig     `json:"logging"`
}

type secretFile struct {
	cipherText []byte
	keys       map[string]interface{}
	/// First secret that defined this secretFile, used for error messages
	firstSecret *secret
}

type FormatType string

const (
	Yaml   FormatType = "yaml"
	JSON   FormatType = "json"
	Binary FormatType = "binary"
	Dotenv FormatType = "dotenv"
	Ini    FormatType = "ini"
)

func IsValidFormat(format string) bool {
	switch format {
	case string(Yaml),
		string(JSON),
		string(Binary),
		string(Dotenv),
		string(Ini):
		return true
	default:
		return false
	}
}

func (f *FormatType) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	t := FormatType(s)
	switch t {
	case "":
		*f = Yaml
	case Yaml, JSON, Binary, Dotenv, Ini:
		*f = t
	}

	return nil
}

func (f FormatType) MarshalJSON() ([]byte, error) {
	return json.Marshal(string(f))
}

type CheckMode string

const (
	Manifest CheckMode = "manifest"
	SopsFile CheckMode = "sopsfile"
	Off      CheckMode = "off"
)

type options struct {
	checkMode    CheckMode
	manifest     string
	ignorePasswd bool
}

type appContext struct {
	manifest            manifest
	secretFiles         map[string]secretFile
	secretByPlaceholder map[string]*secret
	checkMode           CheckMode
	ignorePasswd        bool
}

// Keep this in sync with `modules/sops/templates/default.nix`
const RenderedSubdir string = "rendered"

func readManifest(path string) (*manifest, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open manifest: %w", err)
	}
	defer file.Close()
	dec := json.NewDecoder(file)
	var m manifest
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("failed to parse manifest: %w", err)
	}
	return &m, nil
}

func linksAreEqual(linkTarget, targetFile string, info os.FileInfo, owner int, group int) bool {
	validUG := true
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		validUG = validUG && int(stat.Uid) == owner
		validUG = validUG && int(stat.Gid) == group
	} else {
		panic("Failed to cast fileInfo Sys() to *syscall.Stat_t. This is possibly an unsupported OS.")
	}
	return linkTarget == targetFile && validUG
}

func createSymlink(targetFile string, path string, owner int, group int, userMode bool) error {
	for {
		stat, err := os.Lstat(path)
		if os.IsNotExist(err) {
			if err = os.Symlink(targetFile, path); err != nil {
				return fmt.Errorf("cannot create symlink '%s': %w", path, err)
			}
			if !userMode {
				if err = SecureSymlinkChown(path, targetFile, owner, group); err != nil {
					return fmt.Errorf("cannot chown symlink '%s': %w", path, err)
				}
			}
			return nil
		} else if err != nil {
			return fmt.Errorf("cannot stat '%s': %w", path, err)
		}
		if stat.Mode()&os.ModeSymlink == os.ModeSymlink {
			linkTarget, err := os.Readlink(path)
			if os.IsNotExist(err) {
				continue
			} else if err != nil {
				return fmt.Errorf("cannot read symlink '%s': %w", path, err)
			} else if linksAreEqual(linkTarget, targetFile, stat, owner, group) {
				return nil
			}
		}
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("cannot override %s: %w", path, err)
		}
	}
}

func symlinkSecretsAndTemplates(targetDir string, secrets []secret, templates []template, userMode bool) error {
	for _, secret := range secrets {
		targetFile := filepath.Join(targetDir, secret.Name)
		if targetFile == secret.Path {
			continue
		}
		parent := filepath.Dir(secret.Path)
		if err := os.MkdirAll(parent, os.ModePerm); err != nil {
			return fmt.Errorf("cannot create parent directory of '%s': %w", secret.Path, err)
		}
		if err := createSymlink(targetFile, secret.Path, secret.owner, secret.group, userMode); err != nil {
			return fmt.Errorf("failed to symlink secret '%s': %w", secret.Path, err)
		}
	}

	for _, template := range templates {
		targetFile := filepath.Join(targetDir, RenderedSubdir, template.Name)
		if targetFile == template.Path {
			continue
		}
		parent := filepath.Dir(template.Path)
		if err := os.MkdirAll(parent, os.ModePerm); err != nil {
			return fmt.Errorf("cannot create parent directory of '%s': %w", template.Path, err)
		}
		if err := createSymlink(targetFile, template.Path, template.owner, template.group, userMode); err != nil {
			return fmt.Errorf("failed to symlink template '%s': %w", template.Path, err)
		}
	}

	return nil
}

type plainData struct {
	data   map[string]interface{}
	binary []byte
}

func recurseSecretKey(format FormatType, keys map[string]interface{}, wantedKey string) (string, error) {
	var val interface{}
	var ok bool
	currentKey := wantedKey
	currentData := keys
	keyUntilNow := ""

	for {
		slashIndex := strings.IndexByte(currentKey, '/')
		if slashIndex == -1 {
			// We got to the end
			val, ok = currentData[currentKey]
			if !ok {
				if keyUntilNow != "" {
					keyUntilNow += "/"
				}
				return "", fmt.Errorf("the key '%s%s' cannot be found", keyUntilNow, currentKey)
			}
			break
		}
		thisKey := currentKey[:slashIndex]
		if keyUntilNow == "" {
			keyUntilNow = thisKey
		} else {
			keyUntilNow += "/" + thisKey
		}
		currentKey = currentKey[(slashIndex + 1):]
		val, ok = currentData[thisKey]
		if !ok {
			return "", fmt.Errorf("the key '%s' cannot be found", keyUntilNow)
		}
		if format == JSON {
			var valWithWrongType map[string]interface{}
			valWithWrongType, ok = val.(map[string]interface{})
			if !ok {
				return "", fmt.Errorf("key '%s' does not refer to a dictionary", keyUntilNow)
			}
			currentData = make(map[string]interface{})
			for key, value := range valWithWrongType {
				currentData[fmt.Sprintf("%v", key)] = value
			}
		} else {
			var valWithWrongType map[interface{}]interface{}
			valWithWrongType, ok = val.(map[interface{}]interface{})
			if !ok {
				return "", fmt.Errorf("key '%s' does not refer to a dictionary", keyUntilNow)
			}
			currentData = make(map[string]interface{})
			for key, value := range valWithWrongType {
				currentData[fmt.Sprintf("%v", key)] = value
			}
		}
	}

	// If the value is a string, do not marshal it.
	if strVal, ok := val.(string); ok {
		return strVal, nil
	}

	switch format {
	case JSON:
		strVal, err := json.Marshal(val)
		if err != nil {
			return "", fmt.Errorf("cannot marshal the value of key '%s': %w", keyUntilNow, err)
		}
		return string(strVal), nil
	default:
		return "", fmt.Errorf("nested secrets are not supported for %s", format)
	}
}

func decryptSecret(s *secret, sourceFiles map[string]plainData) error {
	sourceFile := sourceFiles[s.SopsFile]
	if sourceFile.data == nil || sourceFile.binary == nil {
		plain, err := decrypt.File(s.SopsFile, string(s.Format))
		if err != nil {
			return fmt.Errorf("failed to decrypt '%s': %w", s.SopsFile, err)
		}

		switch s.Format {
		case Binary, Dotenv, Ini:
			sourceFile.binary = plain
		case Yaml:
			if s.Key == "" {
				sourceFile.binary = plain
			} else {
				if err := yaml.Unmarshal(plain, &sourceFile.data); err != nil {
					return fmt.Errorf("Cannot parse yaml of '%s': %w", s.SopsFile, err)
				}
			}
		case JSON:
			if s.Key == "" {
				sourceFile.binary = plain
			} else {
				if err := json.Unmarshal(plain, &sourceFile.data); err != nil {
					return fmt.Errorf("Cannot parse json of '%s': %w", s.SopsFile, err)
				}
			}
		default:
			return fmt.Errorf("secret of type %s in %s is not supported", s.Format, s.SopsFile)
		}
	}
	switch s.Format {
	case Binary, Dotenv, Ini:
		s.value = sourceFile.binary
	case Yaml, JSON:
		if s.Key == "" {
			s.value = sourceFile.binary
		} else {
			strVal, err := recurseSecretKey(s.Format, sourceFile.data, s.Key)
			if err != nil {
				return fmt.Errorf("secret %s in %s is not valid: %w", s.Name, s.SopsFile, err)
			}
			s.value = []byte(strVal)
		}
	}
	sourceFiles[s.SopsFile] = sourceFile
	return nil
}

func decryptSecrets(secrets []secret) error {
	sourceFiles := make(map[string]plainData)
	for i := range secrets {
		if err := decryptSecret(&secrets[i], sourceFiles); err != nil {
			return err
		}
	}
	return nil
}

const (
	RamfsMagic int32 = -2054924042
	TmpfsMagic int32 = 16914836
)

func prepareSecretsDir(secretMountpoint string, linkName string, keysGID int, userMode bool) (*string, error) {
	var generation uint64
	linkTarget, err := os.Readlink(linkName)
	if err == nil {
		if strings.HasPrefix(linkTarget, secretMountpoint) {
			targetBasename := filepath.Base(linkTarget)
			generation, err = strconv.ParseUint(targetBasename, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("cannot parse %s of %s as a number: %w", targetBasename, linkTarget, err)
			}
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("cannot access %s: %w", linkName, err)
	}
	generation++
	dir := filepath.Join(secretMountpoint, strconv.Itoa(int(generation)))
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("cannot remove existing %s: %w", dir, err)
		}
	}
	if err := os.Mkdir(dir, os.FileMode(0o751)); err != nil {
		return nil, fmt.Errorf("mkdir(): %w", err)
	}
	if !userMode {
		if err := os.Chown(dir, 0, int(keysGID)); err != nil {
			return nil, fmt.Errorf("cannot change owner/group of '%s' to 0/%d: %w", dir, keysGID, err)
		}
	}
	return &dir, nil
}

func createParentDirs(parent string, target string, keysGID int, userMode bool) error {
	dirs := strings.Split(filepath.Dir(target), "/")
	pathSoFar := parent
	for _, dir := range dirs {
		pathSoFar = filepath.Join(pathSoFar, dir)
		if err := os.MkdirAll(pathSoFar, 0o751); err != nil {
			return fmt.Errorf("cannot create directory '%s' for %s: %w", pathSoFar, filepath.Join(parent, target), err)
		}
		if !userMode {
			if err := os.Chown(pathSoFar, 0, int(keysGID)); err != nil {
				return fmt.Errorf("cannot own directory '%s' for %s: %w", pathSoFar, filepath.Join(parent, target), err)
			}
		}
	}
	return nil
}

func writeSecrets(secretDir string, secrets []secret, keysGID int, userMode bool) error {
	for _, secret := range secrets {
		fp := filepath.Join(secretDir, secret.Name)

		if err := createParentDirs(secretDir, secret.Name, keysGID, userMode); err != nil {
			return err
		}
		if err := os.WriteFile(fp, []byte(secret.value), secret.mode); err != nil {
			return fmt.Errorf("cannot write %s: %w", fp, err)
		}
		if !userMode {
			if err := os.Chown(fp, secret.owner, secret.group); err != nil {
				return fmt.Errorf("cannot change owner/group of '%s' to %d/%d: %w", fp, secret.owner, secret.group, err)
			}
		}
	}
	return nil
}

func lookupGroup(groupname string) (int, error) {
	group, err := user.LookupGroup(groupname)
	if err != nil {
		return 0, fmt.Errorf("failed to lookup 'keys' group: %w", err)
	}
	gid, err := strconv.ParseInt(group.Gid, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("cannot parse keys gid %s: %w", group.Gid, err)
	}
	return int(gid), nil
}

func lookupKeysGroup() (int, error) {
	gid, err1 := lookupGroup("keys")
	if err1 == nil {
		return gid, nil
	}
	gid, err2 := lookupGroup("nogroup")
	if err2 == nil {
		return gid, nil
	}
	return 0, fmt.Errorf("can't find group 'keys' nor 'nogroup' (%w)", err2)
}

func (app *appContext) loadSopsFile(s *secret) (*secretFile, error) {
	if app.checkMode == Manifest {
		return &secretFile{firstSecret: s}, nil
	}

	cipherText, err := os.ReadFile(s.SopsFile)
	if err != nil {
		return nil, fmt.Errorf("failed reading %s: %w", s.SopsFile, err)
	}

	var keys map[string]interface{}

	switch s.Format {
	case Binary:
		if err := json.Unmarshal(cipherText, &keys); err != nil {
			return nil, fmt.Errorf("cannot parse json of '%s': %w", s.SopsFile, err)
		}
		return &secretFile{cipherText: cipherText, firstSecret: s}, nil
	case Yaml:
		if err := yaml.Unmarshal(cipherText, &keys); err != nil {
			return nil, fmt.Errorf("cannot parse yaml of '%s': %w", s.SopsFile, err)
		}
	case Dotenv:
		env, err := godotenv.Unmarshal(string(cipherText))
		if err != nil {
			return nil, fmt.Errorf("cannot parse dotenv of '%s': %w", s.SopsFile, err)
		}
		keys = map[string]interface{}{}
		for k, v := range env {
			keys[k] = v
		}
	case JSON:
		if err := json.Unmarshal(cipherText, &keys); err != nil {
			return nil, fmt.Errorf("cannot parse json of '%s': %w", s.SopsFile, err)
		}
	case Ini:
		_, err := ini.Load(bytes.NewReader(cipherText))
		if err != nil {
			return nil, fmt.Errorf("cannot parse ini of '%s': %w", s.SopsFile, err)
		}
		// TODO: we do not actually check the contents of the ini here...
	}

	return &secretFile{
		cipherText:  cipherText,
		keys:        keys,
		firstSecret: s,
	}, nil
}

func (app *appContext) validateSopsFile(s *secret, file *secretFile) error {
	if file.firstSecret.Format != s.Format {
		return fmt.Errorf("secret %s defined the format of %s as %s, but it was specified as %s in %s before",
			s.Name, s.SopsFile, s.Format,
			file.firstSecret.Format, file.firstSecret.Name)
	}
	if app.checkMode != Manifest && !(s.Format == Binary || s.Format == Dotenv || s.Format == Ini) && s.Key != "" {
		_, err := recurseSecretKey(s.Format, file.keys, s.Key)
		if err != nil {
			return fmt.Errorf("secret %s in %s is not valid: %w", s.Name, s.SopsFile, err)
		}
	}
	return nil
}

func validateMode(mode string) (os.FileMode, error) {
	parsed, err := strconv.ParseUint(mode, 8, 16)
	if err != nil {
		return 0, fmt.Errorf("invalid number in mode: %s: %w", mode, err)
	}
	return os.FileMode(parsed), nil
}

func validateOwner(owner string) (int, error) {
	lookedUp, err := user.Lookup(owner)
	if err != nil {
		return 0, fmt.Errorf("failed to lookup user '%s': %w", owner, err)
	}
	ownerNr, err := strconv.ParseUint(lookedUp.Uid, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("cannot parse uid %s: %w", lookedUp.Uid, err)
	}
	return int(ownerNr), nil
}

func validateGroup(group string) (int, error) {
	lookedUp, err := user.LookupGroup(group)
	if err != nil {
		return 0, fmt.Errorf("failed to lookup group '%s': %w", group, err)
	}
	groupNr, err := strconv.ParseUint(lookedUp.Gid, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("cannot parse gid %s: %w", lookedUp.Gid, err)
	}
	return int(groupNr), nil
}

func (app *appContext) validateSecret(secret *secret) error {
	mode, err := validateMode(secret.Mode)
	if err != nil {
		return err
	}
	secret.mode = mode

	if app.ignorePasswd || os.Getenv("NIXOS_ACTION") == "dry-activate" {
		secret.owner = 0
		secret.group = 0
	} else if app.checkMode == Off || app.ignorePasswd {
		if secret.Owner == nil {
			secret.owner = secret.UID
		} else {
			owner, err := validateOwner(*secret.Owner)
			if err != nil {
				return err
			}
			secret.owner = owner
		}

		if secret.Group == nil {
			secret.group = secret.GID
		} else {
			group, err := validateGroup(*secret.Group)
			if err != nil {
				return err
			}
			secret.group = group
		}
	}

	if secret.Format == "" {
		secret.Format = "yaml"
	}

	if !IsValidFormat(string(secret.Format)) {
		return fmt.Errorf("unsupported format %s for secret %s", secret.Format, secret.Name)
	}

	file, ok := app.secretFiles[secret.SopsFile]
	if !ok {
		maybeFile, err := app.loadSopsFile(secret)
		if err != nil {
			return err
		}
		app.secretFiles[secret.SopsFile] = *maybeFile

		file = *maybeFile
	}

	return app.validateSopsFile(secret, &file)
}

func renderTemplates(templates []template, secretByPlaceholder map[string]*secret) {
	for i := range templates {
		template := &templates[i]
		rendered := renderTemplate(&template.content, secretByPlaceholder)
		template.value = []byte(rendered)
	}
}

func renderTemplate(content *string, secretByPlaceholder map[string]*secret) string {
	rendered := *content
	for placeholder, secret := range secretByPlaceholder {
		rendered = strings.ReplaceAll(rendered, placeholder, string(secret.value))
	}
	return rendered
}

func (app *appContext) validateTemplate(template *template) error {
	mode, err := validateMode(template.Mode)
	if err != nil {
		return err
	}
	template.mode = mode

	if app.ignorePasswd || os.Getenv("NIXOS_ACTION") == "dry-activate" {
		template.owner = 0
		template.group = 0
	} else if app.checkMode == Off || app.ignorePasswd {
		if template.Owner == nil {
			template.owner = template.UID
		} else {
			owner, err := validateOwner(*template.Owner)
			if err != nil {
				return err
			}
			template.owner = owner
		}

		if template.Group == nil {
			template.group = template.GID
		} else {
			group, err := validateGroup(*template.Group)
			if err != nil {
				return err
			}
			template.group = group
		}
	}

	var templateText string
	if template.Content != "" {
		templateText = template.Content
	} else if template.File != "" {
		templateBytes, err := os.ReadFile(template.File)
		if err != nil {
			return fmt.Errorf("cannot read %s: %w", template.File, err)
		}
		templateText = string(templateBytes)
	} else {
		return fmt.Errorf("neither content nor file was specified for template %s", template.Name)
	}

	template.content = templateText

	return nil
}

func (app *appContext) validateManifest() error {
	m := &app.manifest
	if m.GnupgHome != "" {
		errorFmt := "gnupgHome and %s were specified in the manifest. " +
			"Both options are mutually exclusive."
		if len(m.SSHKeyPaths) > 0 {
			return fmt.Errorf(errorFmt, "sshKeyPaths")
		}
		if m.AgeKeyFile != "" {
			return fmt.Errorf(errorFmt, "ageKeyFile")
		}
	}

	for i := range m.Secrets {
		secret := &m.Secrets[i]
		if err := app.validateSecret(secret); err != nil {
			return err
		}

		// The Nix module only defines placeholders for secrets if there are
		// templates.
		if len(m.Templates) > 0 {
			placeholder := m.PlaceholderBySecretName[secret.Name]
			app.secretByPlaceholder[placeholder] = secret
		}
	}

	for i := range m.Templates {
		template := &m.Templates[i]
		if err := app.validateTemplate(template); err != nil {
			return err
		}
	}
	return nil
}

func atomicSymlink(oldname, newname string) error {
	if err := os.MkdirAll(filepath.Dir(newname), 0o755); err != nil {
		return err
	}

	// Fast path: if newname does not exist yet, we can skip the whole dance
	// below.
	if err := os.Symlink(oldname, newname); err == nil || !os.IsExist(err) {
		return err
	}

	// We need to use ioutil.TempDir, as we cannot overwrite a ioutil.TempFile,
	// and removing+symlinking creates a TOCTOU race.
	d, err := os.MkdirTemp(filepath.Dir(newname), "."+filepath.Base(newname))
	if err != nil {
		return err
	}
	cleanup := true
	defer func() {
		if cleanup {
			os.RemoveAll(d)
		}
	}()

	symlink := filepath.Join(d, "tmp.symlink")
	if err := os.Symlink(oldname, symlink); err != nil {
		return err
	}

	if err := os.Rename(symlink, newname); err != nil {
		return err
	}

	cleanup = false
	return os.RemoveAll(d)
}

func pruneGenerations(secretsMountPoint, secretsDir string, keepGenerations int) error {
	if keepGenerations == 0 {
		return nil // Nothing to prune
	}

	// Prepare our failsafe
	currentGeneration, err := strconv.Atoi(path.Base(secretsDir))
	if err != nil {
		return fmt.Errorf("logic error, current generation is not numeric: %w", err)
	}

	// Read files in the mount directory
	file, err := os.Open(secretsMountPoint)
	if err != nil {
		return fmt.Errorf("cannot open %s: %w", secretsMountPoint, err)
	}
	defer file.Close()

	generations, err := file.Readdirnames(0)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", secretsMountPoint, err)
	}
	for _, generationName := range generations {
		generationNum, err := strconv.Atoi(generationName)
		// Not a number? Not relevant
		if err != nil {
			continue
		}
		// Not strictly necessary but a good failsafe to
		// make sure we don't prune the current generation
		if generationNum == currentGeneration {
			continue
		}
		if currentGeneration-keepGenerations >= generationNum {
			os.RemoveAll(path.Join(secretsMountPoint, generationName))
		}
	}

	return nil
}

func importSSHKeys(logcfg loggingConfig, keyPaths []string, gpgHome string) error {
	secringPath := filepath.Join(gpgHome, "secring.gpg")
	pubringPath := filepath.Join(gpgHome, "pubring.gpg")

	secring, err := os.OpenFile(secringPath, os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return fmt.Errorf("cannot create %s: %w", secringPath, err)
	}
	defer secring.Close()

	pubring, err := os.OpenFile(pubringPath, os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return fmt.Errorf("cannot create %s: %w", pubringPath, err)
	}
	defer pubring.Close()

	for _, p := range keyPaths {
		sshKey, err := os.ReadFile(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Cannot read ssh key '%s': %s\n", p, err)
			continue
		}
		gpgKey, err := sshkeys.SSHPrivateKeyToPGP(sshKey)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s\n", err)
			continue
		}

		if err := gpgKey.SerializePrivate(secring, nil); err != nil {
			fmt.Fprintf(os.Stderr, "Cannot write secring: %s\n", err)
			continue
		}

		if err := gpgKey.Serialize(pubring); err != nil {
			fmt.Fprintf(os.Stderr, "Cannot write pubring: %s\n", err)
			continue
		}

		if logcfg.KeyImport {
			fmt.Printf("%s: Imported %s as GPG key with fingerprint %s\n", path.Base(os.Args[0]), p, hex.EncodeToString(gpgKey.PrimaryKey.Fingerprint[:]))
		}
	}

	return nil
}

func importAgeSSHKeys(logcfg loggingConfig, keyPaths []string, ageFile os.File) error {
	for _, p := range keyPaths {
		// Read the key
		sshKey, err := os.ReadFile(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Cannot read ssh key '%s': %s\n", p, err)
			continue
		}
		// Convert the key to age
		privKey, pubKey, err := agessh.SSHPrivateKeyToAge(sshKey, []byte{})
		if err != nil {
			fmt.Fprintf(os.Stderr, "Cannot convert ssh key '%s': %s\n", p, err)
			continue
		}
		// Append it to the file
		_, err = ageFile.WriteString(*privKey + "\n")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Cannot write key to age file: %s\n", err)
			continue
		}

		if logcfg.KeyImport {
			fmt.Fprintf(os.Stderr, "%s: Imported %s as age key with fingerprint %s\n", path.Base(os.Args[0]), p, *pubKey)
			continue
		}
	}

	return nil
}

// Like filepath.Walk but symlink-aware.
// Inspired by https://github.com/facebookarchive/symwalk
func symlinkWalk(filename string, linkDirname string, walkFn filepath.WalkFunc) error {
	symWalkFunc := func(path string, info os.FileInfo, err error) error {
		if fname, err := filepath.Rel(filename, path); err == nil {
			path = filepath.Join(linkDirname, fname)
		} else {
			return err
		}

		if err == nil && info.Mode()&os.ModeSymlink == os.ModeSymlink {
			finalPath, err := filepath.EvalSymlinks(path)
			if err != nil {
				return err
			}
			info, err := os.Lstat(finalPath)
			if err != nil {
				return walkFn(path, info, err)
			}
			if info.IsDir() {
				return symlinkWalk(finalPath, path, walkFn)
			}
		}

		return walkFn(path, info, err)
	}
	return filepath.Walk(filename, symWalkFunc)
}

func handleModifications(isDry bool, logcfg loggingConfig, symlinkPath string, secretDir string, secrets []secret, templates []template) error {
	var restart []string
	var reload []string

	newSecrets := make(map[string]bool)
	modifiedSecrets := make(map[string]bool)
	removedSecrets := make(map[string]bool)

	newTemplates := make(map[string]bool)
	modifiedTemplates := make(map[string]bool)
	removedTemplates := make(map[string]bool)

	// When the symlink path does not exist yet, we are being run in stage-2-init.sh
	// where switch-to-configuration is not run so the services would only be restarted
	// the next time switch-to-configuration is run.
	if _, err := os.Stat(symlinkPath); os.IsNotExist(err) {
		return nil
	}

	// Find modified/new secrets
	for _, secret := range secrets {
		oldPath := filepath.Join(symlinkPath, secret.Name)
		newPath := filepath.Join(secretDir, secret.Name)

		// Read the old file
		oldData, err := os.ReadFile(oldPath)
		if err != nil {
			if os.IsNotExist(err) {
				// File did not exist before
				restart = append(restart, secret.RestartUnits...)
				reload = append(reload, secret.ReloadUnits...)
				newSecrets[secret.Name] = true
				continue
			}
			return err
		}

		// Read the new file
		newData, err := os.ReadFile(newPath)
		if err != nil {
			return err
		}

		if !bytes.Equal(oldData, newData) {
			restart = append(restart, secret.RestartUnits...)
			reload = append(reload, secret.ReloadUnits...)
			modifiedSecrets[secret.Name] = true
		}
	}

	// Find modified/new templates
	for _, template := range templates {
		oldPath := filepath.Join(symlinkPath, RenderedSubdir, template.Name)
		newPath := filepath.Join(secretDir, RenderedSubdir, template.Name)

		// Read the old file
		oldData, err := os.ReadFile(oldPath)
		if err != nil {
			if os.IsNotExist(err) {
				// File did not exist before
				restart = append(restart, template.RestartUnits...)
				reload = append(reload, template.ReloadUnits...)
				newTemplates[template.Name] = true
				continue
			}
			return err
		}

		// Read the new file
		newData, err := os.ReadFile(newPath)
		if err != nil {
			return err
		}

		if !bytes.Equal(oldData, newData) {
			restart = append(restart, template.RestartUnits...)
			reload = append(reload, template.ReloadUnits...)
			modifiedTemplates[template.Name] = true
		}
	}

	writeLines := func(list []string, file string) error {
		if len(list) != 0 {
			if _, err := os.Stat(filepath.Dir(file)); err != nil {
				if os.IsNotExist(err) {
					return nil
				} else {
					return err
				}
			}
			f, err := os.OpenFile(file, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
			if err != nil {
				return err
			}
			defer f.Close()
			for _, unit := range list {
				if _, err = f.WriteString(unit + "\n"); err != nil {
					return err
				}
			}
		}
		return nil
	}
	var dryPrefix string
	if isDry {
		dryPrefix = "/run/nixos/dry-activation"
	} else {
		dryPrefix = "/run/nixos/activation"
	}
	if err := writeLines(restart, dryPrefix+"-restart-list"); err != nil {
		return err
	}
	if err := writeLines(reload, dryPrefix+"-reload-list"); err != nil {
		return err
	}

	// Do not output changes if not requested
	if !logcfg.SecretChanges {
		return nil
	}

	// Find removed secrets/templates.
	symlinkRenderedPath := filepath.Join(symlinkPath, RenderedSubdir)
	err := symlinkWalk(symlinkPath, symlinkPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}

		// If the path we're looking at isn't in `symlinkRenderedPath`, then
		// it's a secret.
		rel, err := filepath.Rel(symlinkRenderedPath, path)
		if err != nil {
			return err
		}
		isSecret := strings.HasPrefix(rel, "..")

		if isSecret {
			path = strings.TrimPrefix(path, symlinkPath+string(os.PathSeparator))
			for _, secret := range secrets {
				if secret.Name == path {
					return nil
				}
			}
			removedSecrets[path] = true
		} else {
			path = strings.TrimPrefix(path, symlinkRenderedPath+string(os.PathSeparator))
			for _, template := range templates {
				if template.Name == path {
					return nil
				}
			}
			removedTemplates[path] = true
		}
		return nil
	})
	if err != nil {
		return err
	}

	// Output new/modified/removed secrets/templates
	outputChanged := func(noun string, changed map[string]bool, regularPrefix, dryPrefix string) {
		if len(changed) > 0 {
			s := ""
			if len(changed) != 1 {
				s = "s"
			}
			if isDry {
				fmt.Printf("%s %s%s: ", dryPrefix, noun, s)
			} else {
				fmt.Printf("%s %s%s: ", regularPrefix, noun, s)
			}

			// Sort the output for deterministic behavior.
			keys := make([]string, 0, len(changed))
			for key := range changed {
				keys = append(keys, key)
			}
			sort.Strings(keys)

			fmt.Println(strings.Join(keys, ", "))
		}
	}
	outputChanged("secret", newSecrets, "adding", "would add")
	outputChanged("secret", modifiedSecrets, "modifying", "would modify")
	outputChanged("secret", removedSecrets, "removing", "would remove")
	outputChanged("rendered secret", newTemplates, "adding", "would add")
	outputChanged("rendered secret", modifiedTemplates, "modifying", "would modify")
	outputChanged("rendered secret", removedTemplates, "removing", "would remove")

	return nil
}

type keyring struct {
	path string
}

func (k *keyring) Remove() {
	os.RemoveAll(k.path)
	os.Unsetenv("GNUPGHOME")
}

func setupGPGKeyring(logcfg loggingConfig, sshKeys []string, parentDir string) (*keyring, error) {
	dir, err := os.MkdirTemp(parentDir, "gpg")
	if err != nil {
		return nil, fmt.Errorf("cannot create gpg home in '%s': %w", parentDir, err)
	}
	k := keyring{dir}

	if err := importSSHKeys(logcfg, sshKeys, dir); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	os.Setenv("GNUPGHOME", dir)

	return &k, nil
}

func parseFlags(args []string) (*options, error) {
	var opts options
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage: %s [OPTION] manifest.json\n", args[0])
		fs.PrintDefaults()
	}
	var checkMode string
	fs.StringVar(&checkMode, "check-mode", "off", `Validate configuration without installing it (possible values: "manifest","sopsfile","off")`)
	fs.BoolVar(&opts.ignorePasswd, "ignore-passwd", false, `Don't look up anything in /etc/passwd. Causes everything to be owned by root:root or the user executing the tool in user mode`)
	if err := fs.Parse(args[1:]); err != nil {
		return nil, err
	}

	switch CheckMode(checkMode) {
	case Manifest, SopsFile, Off:
		opts.checkMode = CheckMode(checkMode)
	default:
		return nil, fmt.Errorf("invalid value provided for -check-mode flag: %s", opts.checkMode)
	}

	if fs.NArg() != 1 {
		flag.Usage()
		return nil, flag.ErrHelp
	}
	opts.manifest = fs.Arg(0)
	return &opts, nil
}

func replaceRuntimeDir(path, rundir string) (ret string) {
	parts := strings.Split(path, "%%")
	first := true
	for _, part := range parts {
		if !first {
			ret += "%"
		}
		first = false
		ret += strings.ReplaceAll(part, "%r", rundir)
	}
	return
}

func writeTemplates(targetDir string, templates []template, keysGID int, userMode bool) error {
	for _, template := range templates {
		fp := filepath.Join(targetDir, template.Name)

		if err := createParentDirs(targetDir, template.Name, keysGID, userMode); err != nil {
			return err
		}

		if err := os.WriteFile(fp, []byte(template.value), template.mode); err != nil {
			return fmt.Errorf("cannot write %s: %w", fp, err)
		}
		if !userMode {
			if err := os.Chown(fp, template.owner, template.group); err != nil {
				return fmt.Errorf("cannot change owner/group of '%s' to %d/%d: %w", fp, template.owner, template.group, err)
			}
		}
	}
	return nil
}

func installSecrets(args []string) error {
	opts, err := parseFlags(args)
	if err != nil {
		return err
	}

	manifest, err := readManifest(opts.manifest)
	if err != nil {
		return err
	}

	if manifest.UserMode {
		var rundir string
		rundir, err = RuntimeDir()
		if opts.checkMode == Off && err != nil {
			return fmt.Errorf("cannot figure out runtime directory: %w", err)
		}
		manifest.SecretsMountPoint = replaceRuntimeDir(manifest.SecretsMountPoint, rundir)
		manifest.SymlinkPath = replaceRuntimeDir(manifest.SymlinkPath, rundir)
		var newSecrets []secret
		for _, secret := range manifest.Secrets {
			secret.Path = replaceRuntimeDir(secret.Path, rundir)
			newSecrets = append(newSecrets, secret)
		}
		manifest.Secrets = newSecrets
	}

	app := appContext{
		manifest:            *manifest,
		checkMode:           opts.checkMode,
		ignorePasswd:        opts.ignorePasswd,
		secretFiles:         make(map[string]secretFile),
		secretByPlaceholder: make(map[string]*secret),
	}

	if err = app.validateManifest(); err != nil {
		return fmt.Errorf("manifest is not valid: %w", err)
	}

	if app.checkMode != Off {
		return nil
	}

	var keysGID int
	if opts.ignorePasswd {
		keysGID = 0
	} else {
		keysGID, err = lookupKeysGroup()
		if err != nil {
			return err
		}
	}

	isDry := os.Getenv("NIXOS_ACTION") == "dry-activate"

	if err = MountSecretFs(manifest.SecretsMountPoint, keysGID, manifest.UseTmpfs, manifest.UserMode); err != nil {
		return fmt.Errorf("failed to mount filesystem for secrets: %w", err)
	}

	if len(manifest.SSHKeyPaths) != 0 {
		var keyring *keyring
		keyring, err = setupGPGKeyring(manifest.Logging, manifest.SSHKeyPaths, manifest.SecretsMountPoint)
		if err != nil {
			return fmt.Errorf("error setting up gpg keyring: %w", err)
		}
		defer keyring.Remove()
	} else if manifest.GnupgHome != "" {
		os.Setenv("GNUPGHOME", manifest.GnupgHome)
	}

	// Import age keys
	if len(manifest.AgeSSHKeyPaths) != 0 || manifest.AgeKeyFile != "" {
		keyfile := filepath.Join(manifest.SecretsMountPoint, "age-keys.txt")
		os.Setenv("SOPS_AGE_KEY_FILE", keyfile)
		// Create the keyfile
		var ageFile *os.File
		ageFile, err = os.OpenFile(keyfile, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			return fmt.Errorf("cannot create '%s': %w", keyfile, err)
		}
		defer ageFile.Close()
		fmt.Fprintf(ageFile, "# generated by sops-nix at %s\n", time.Now().Format(time.RFC3339))

		// Import SSH keys
		if len(manifest.AgeSSHKeyPaths) != 0 {
			err = importAgeSSHKeys(manifest.Logging, manifest.AgeSSHKeyPaths, *ageFile)
			if err != nil {
				return err
			}
		}
		// Import the keyfile
		if manifest.AgeKeyFile != "" {
			// Read the keyfile
			var contents []byte
			contents, err = os.ReadFile(manifest.AgeKeyFile)
			if err != nil {
				return fmt.Errorf("cannot read keyfile '%s': %w", manifest.AgeKeyFile, err)
			}
			// Append it to the file
			_, err = ageFile.WriteString(string(contents) + "\n")
			if err != nil {
				return fmt.Errorf("cannot write key to age file: %w", err)
			}
		}
	}

	if err := decryptSecrets(manifest.Secrets); err != nil {
		return err
	}

	// Now that the secrets are decrypted, we can render the templates.
	renderTemplates(manifest.Templates, app.secretByPlaceholder)

	secretDir, err := prepareSecretsDir(manifest.SecretsMountPoint, manifest.SymlinkPath, keysGID, manifest.UserMode)
	if err != nil {
		return fmt.Errorf("failed to prepare new secrets directory: %w", err)
	}
	if err := writeSecrets(*secretDir, manifest.Secrets, keysGID, manifest.UserMode); err != nil {
		return fmt.Errorf("cannot write secrets: %w", err)
	}

	if err := writeTemplates(path.Join(*secretDir, RenderedSubdir), manifest.Templates, keysGID, manifest.UserMode); err != nil {
		return fmt.Errorf("cannot render templates: %w", err)
	}

	if !manifest.UserMode {
		if err := handleModifications(isDry, manifest.Logging, manifest.SymlinkPath, *secretDir, manifest.Secrets, manifest.Templates); err != nil {
			return fmt.Errorf("cannot request units to restart: %w", err)
		}
	}
	// No need to perform the actual symlinking
	if isDry {
		return nil
	}
	if err := symlinkSecretsAndTemplates(manifest.SymlinkPath, manifest.Secrets, manifest.Templates, manifest.UserMode); err != nil {
		return fmt.Errorf("failed to prepare symlinks to secret store: %w", err)
	}
	if err := atomicSymlink(*secretDir, manifest.SymlinkPath); err != nil {
		return fmt.Errorf("cannot update secrets symlink: %w", err)
	}
	if err := pruneGenerations(manifest.SecretsMountPoint, *secretDir, manifest.KeepGenerations); err != nil {
		return fmt.Errorf("cannot prune old secrets generations: %w", err)
	}

	return nil
}

func main() {
	if err := installSecrets(os.Args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		fmt.Fprintf(os.Stderr, "%s: %s\n", os.Args[0], err)
		os.Exit(1)
	}
}
