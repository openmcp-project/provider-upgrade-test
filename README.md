[![REUSE status](https://api.reuse.software/badge/github.com/openmcp-project/provider-upgrade-test)](https://api.reuse.software/info/github.com/openmcp-project/provider-upgrade-test)

# provider-upgrade-test

## About this project

This tool is designed to test the upgradability of Crossplane providers. It verifies whether a provider can be successfully upgraded from one version to another while ensuring that the resources (CRs) deployed with the source version remain healthy and functional after the upgrade.

### How it works

The tool provides a CLI script, `provider-test.sh`, to run the tests locally.

To view the help message, run:
```bash
./provider-test.sh -h
```

The tool follows these steps to test provider version upgradability:

1. **Deploy Source Version Provider**: Deploy the provider at the specified source version.
2. **Apply Source Provider CRs**: Apply the Custom Resources (CRs) associated with the source version.
3. **Upgrade Provider to Target Version**: Upgrade the provider to the specified target version.
4. **Check CR Health**: Verify that the CRs deployed before the upgrade remain healthy after the upgrade.
5. **Check Provider Health**: Ensure that the provider stays healthy for 10 minutes after the upgrade.


## Requirements and Setup

To run the test, you need to have following cli installed: `kind`, `kubectl`, [`chainsaw`](https://kyverno.github.io/chainsaw/latest/quick-start/), `sed`, `yq`, `jq`

### Example usage
```bash
REGISTRY=ghcr.io/sap/crossplane-provider-btp/crossplane/provider-btp
./provider-test.sh upgrade-test --source "${REGISTRY}:v1.0.3" --target "${REGISTRY}:v1.1.0" --provider provider-btp --initialize providers/provider-btp/scripts/initialize.sh --cleanup providers/provider-btp/scripts/cleanup.sh --wait-user-input
```

### General structure
```bash
./provider-test.sh upgrade-test [--source <arg>] [--target <arg>] [--source-dir <arg>] [--provider <arg>] [--source-docker-auth] [--target-docker-auth] [--initialize <arg>] [--cleanup <arg>] [--use-cluster-context <arg>] [--wait-user-input] [--skip-crossplane-install] [-h|--help]
```

### Options

- --source: Source version provider Docker registry with tag (required, no default).
- --target: Target version provider Docker registry with tag (required, no default).
- --source-dir: Source provider CR test directory relative to the providers folder.
- --source-docker-auth: toggle on use docker auth for source provider image, credentials need to be set from ENV
- --target-docker-auth: toggle on use docker auth for target provider image, credentials need to be set from ENV
- --provider: Name of the provider to test (default: provider-btp).
- --initialize: specify initiliaze shell script to run before applying source provider CRs tests
- --cleanup: specify clean up script to run after test process finishes
- --use-cluster-context: Use an existing Kubernetes cluster context instead of creating a new cluster.
- --wait-user-input: Prompt for user input during test steps.
- --skip-crossplane-install: Skip installing Crossplane in the Kubernetes cluster.
- -h, --help: Display the help message.

## Development
Continuing development of this tool remains necessary to adapt to changing providers and its versions.
Understanding the details of the tool is beneficial to developers. 

### Detail Test Execution Explain
1. Create kind k8s cluster or use k8s context instead provided by --use-cluster-context
2. Install crossplane to the k8s cluster if --skip-crossplane-install not specified
3. Deploy source provider from docker registry provided by --source
4. Apply k8s resources in setup folder of source provider, variables in format INJECT_ENV.VAR_NAME will be replaced with VAR_NAME's ENV value
5. Run chainsaw-test.yaml located in the source folder if specified via --source-dir, otherwise try to locate the chainsaw-test.yaml from providers/--provider-name/--source:version
6. After resouces applied successfully, upgrade provider to version provided by --target and verify if provider stay healthy for 3 minutes
7. Verify if resources applied before stay healthy
8. Verify if provider still healthy for 10 minutes
9. Test finished, generate test results

### Add test resources for a new provider
To enable upgrade test for a new provider, you could follow below steps. Let's assume we'd like to create a new test for provider `provider-example` version `v1.0` and `v2.0`

1. create new folders under providers
```shell
mkdir providers/provider-example
mkdir providers/provider-example/v1.0 providers/provider-example/v2.0
```

2. add CR resources specific to the source version and the related chainsaw tests
```shell
export VERSION=v1.0
# folder to put CRs
mkdir providers/provider-example/$VERSION/crs

# folder to put set up resources contain credentials before CRs, credentials can be injected via INJECT_ENV.VAR_NAME
mkdir providers/provider-example/$VERSION/setup

# add your set up config to the setup folder if exists, for example provider-config, for example:
cat <<EOF > providers/provider-example/$VERSION/setup/config.yaml
apiVersion: v1
kind: Secret
metadata:
    name: sa-provider-secret
stringData:
    credentials: |
        {
          "username": "tech_user",
          "password": "INJECT_ENV.TECH_USER_PASSWORD"
        }
EOF


# add your crs to the crs folder, for example:
cat <<EOF > providers/provider-example/$VERSION/crs/book.yaml
apiVersion: example.crossplane.io/v1alpha1
kind: Book
metadata:
  name: my-book
spec:
  forProvider:
    name: example-book
EOF

cat <<EOF > providers/provider-example/$VERSION/crs/shelf.yaml
apiVersion: example.crossplane.io/v1alpha1
kind: Shelf
metadata:
  name: my-shelf
spec:
  forProvider:
    name: example-shelf
EOF

# now generate the chainsaw-test.yaml for the crs, which will be used in the upgrade-test to determin how and which resources to be applied for the source provider, you could create it manually or use the helper shell script to generate a start up test file for you to adapt.
./generate-chainsaw-test.sh providers/provider-example/$VERSION/crs
mv auto-generated-chainsaw-test.yaml providers/provider-example/$VERSION/chainsaw-test.yaml
```
with steps above, you can already run a test for provider provider-example to upgrade from version v1.0 to version v2.0, remeember, before running the tests set the env variables needed 
```shell
export TECH_USER_PASSWORD=your_password
REGISTRY=ghcr.io/sap/crossplane-provider-btp/crossplane/provider-btp
./provider-test.sh upgrade-test --source "${REGISTRY}:v1.0" --target "${REGISTRY}:v2.0" --provider provider-example
```
If you need to do some initialize or clean up scripts, you could create some shell scripts and specify them via --initialize and --cleanup.

And to make the provider upgrade tests for versions after v2.0, you should also add the crs, setup config, chainsaw-test.yaml for version v2.0, there's no need to copy the same crs from v1.0 to v2.0, you only need to add what's specific to the version v2.0, as when create the chainsaw-test.yaml for it you could specify the files from other versions for example: `file: ../v1.0/crs/book.yaml`

### Add new version for existing provider
When there's new version released for the existing tests provider for example `provider-btp` version `v8.0`, you should add the resources here and enable it for future versions upgrade test.
```shell
export VERSION=v8.0
mkdir providers/provider-btp/$VERSION  providers/provider-btp/$VERSION/setup
# add setup folder and adjust content if needed
cp -r providers/provider-btp/v1.0.3/setup/ providers/provider-btp/$VERSION/setup/

# add v8.0 specific resource if exists to crs
mkdir providers/provider-btp/$VERSION/crs
cat <<EOF > providers/provider-btp/$VERSION/crs/subaccount.yaml
apiVersion: account.btp.sap.crossplane.io/v1alpha1
kind: Subaccount
metadata:
  name: upgrade-test-subaccount
spec:
  forProvider:
    description: hello subaccount
    new-field-v8: this is a new key-value
EOF

# add or copy chainsaw-test.yaml and modify the content
cp providers/provider-btp/v1.0.3/chainsaw-test.yaml providers/provider-btp/$VERSION/chainsaw-test.yaml
# modify test content file locations for crs if needed: change from file: crs/directory.yaml to file: ../v1.0.3/crs/directory.yaml
```
adjust the initialize and clean up scripts if needed.

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/openmcp-project/provider-upgrade-test/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/openmcp-project/provider-upgrade-test/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/SAP/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2025 SAP SE or an SAP affiliate company and provider-upgrade-test contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/openmcp-project/provider-upgrade-test).
