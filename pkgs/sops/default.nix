{
    sops,
    fetchFromGitHub,
}: sops.overrideAttrs {

    version = "age-sops";

    src = fetchFromGitHub {
        owner = "age-sops";
        repo = "sops";
        rev = "df6d1d330d9fcd461e1f15852229f8cf41cab061";
        hash = "sha256-h3Zc++m2v9jLDGGVqQVq911ZOsZ0+DN7FgpIq+rleKE=";
    };

    vendorHash = "sha256-WChizpCjaRYcFoCbfLKNE6SPk1PV/aF3OkG62YdnpOw=";
}