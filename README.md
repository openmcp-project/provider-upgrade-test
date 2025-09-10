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
2. **Apply Source Provider CRs**: Apply the Custom Resources (CRs) associated with the source version (with automatic timestamp initialization).
3. **Upgrade Provider to Target Version**: Upgrade the provider to the specified target version.
4. **Check CR Health**: Verify that the CRs deployed before the upgrade remain healthy after the upgrade.
5. **Check Provider Health**: Ensure that the provider stays healthy for 10 minutes after the upgrade.
6. **Automatic Cleanup**: Clean up all test resources with proper managed resource deletion waiting.

## Requirements and Setup

To run the test, you need to have following cli installed: `kind`, `kubectl`, [`chainsaw`](https://kyverno.github.io/chainsaw/latest/quick-start/), `sed`, `yq`, `jq`

## Usage

### Basic Command
```bash
./provider-test.sh upgrade-test \
  --source crossplane/provider-btp:v1.0.3 \
  --target crossplane/provider-btp:v1.1.0 \
  --source-dir provider-btp/v1.0.3
```

### Available Options

| Option | Required | Description | Default |
|--------|----------|-------------|---------|
| `--source` | Yes | Source version provider docker registry with tag | - |
| `--target` | Yes | Target version provider docker registry with tag | - |
| `--source-dir` | Yes | Source provider CR test directory (relative to providers/) | - |
| `--provider` | No | Provider name to deploy | provider-btp |
| `--wait-user-input` | No | Prompt for user input at each step | No prompting |
| `--use-cluster-context` | No | Use existing cluster context instead of creating new cluster | Creates new cluster |
| `--skip-crossplane-install` | No | Skip crossplane installation | Installs crossplane |

### Example Commands

**Basic upgrade test:**
```bash
./provider-test.sh upgrade-test \
  --source crossplane/provider-btp:v1.0.3 \
  --target crossplane/provider-btp:v1.1.0 \
  --source-dir provider-btp/v1.0.3
```

**Interactive mode with user prompts:**
```bash
./provider-test.sh upgrade-test \
  --source crossplane/provider-btp:v1.0.3 \
  --target crossplane/provider-btp:v1.1.0 \
  --source-dir provider-btp/v1.0.3 \
  --wait-user-input
```

**Using existing cluster:**
```bash
./provider-test.sh upgrade-test \
  --source crossplane/provider-btp:v1.0.3 \
  --target crossplane/provider-btp:v1.1.0 \
  --source-dir provider-btp/v1.0.3 \
  --use-cluster-context my-cluster
```

### Auto-Copy Feature for New Versions

When testing upgrades from a provider version that doesn't have test manifests yet, the tool automatically helps by copying manifests from the latest available version that is lower than your specified source version.

**How it works:**
1. If the specified `--source-dir` doesn't exist, the tool checks if the Docker image exists in the registry
2. If the image exists, it finds the latest known version lower than your source version
3. Copies the test manifests from that version to your specified version
4. Displays: *"Could not be found - copying manifests from latest known version and applying them to this version"*
5. Continues with the upgrade test

**Example:**
```bash
# Testing upgrade from v1.0.5 (source) to v1.1.0 (newly released target)
# where v1.0.5 doesn't have manifests yet
./provider-test.sh upgrade-test \
  --source crossplane/provider-btp:v1.0.5 \
  --target crossplane/provider-btp:v1.1.0 \
  --source-dir provider-btp/v1.0.5
```

This feature unblocks testing when you need to upgrade from a version that doesn't have manifests, allowing you to test the upgrade path to newly released versions.

## Development
Understanding the details of the tool is beneficial to developers. 

### Detailed Test Execution Process
1. Create kind k8s cluster or use k8s context provided by `--use-cluster-context`
2. Install crossplane to the k8s cluster if `--skip-crossplane-install` not specified
3. Deploy source provider from docker registry provided by `--source`
4. Generate test resources to `generated/` directory and apply k8s resources in setup folder, variables in format `INJECT_ENV.VAR_NAME` will be replaced with `VAR_NAME`'s ENV value
5. **Automatic initialization**: Replace `PLACEHOLDER` strings in generated YAML files with unique timestamps
6. Apply the initialized Custom Resources (CRs)
7. Run chainsaw test to verify resource creation
8. Upgrade provider to version provided by `--target` and verify provider stays healthy for 2 minutes
9. Verify if resources applied before upgrade remain healthy
10. Verify if provider stays healthy for 10 minutes
11. **Automatic cleanup**: Delete all test resources and wait for managed resource cleanup
12. Generate test results summary

### Add test resources for a new provider
To enable upgrade test for a new provider, follow these steps. Let's assume we'd like to create a new test for provider `provider-example` version `v1.0` and `v2.0`

1. Create new folders under providers
```shell
mkdir providers/provider-example
mkdir providers/provider-example/v1.0 providers/provider-example/v2.0
```

2. Add CR resources specific to the source version and the related chainsaw tests
```shell
export VERSION=v1.0
# folder to put CRs
mkdir providers/provider-example/$VERSION/crs

# folder to put set up resources containing credentials before CRs, credentials can be injected via INJECT_ENV.VAR_NAME
mkdir providers/provider-example/$VERSION/setup

# add your set up config to the setup folder if exists, for example provider-config:
cat <<EOF > providers/provider-example/$VERSION/setup/config.yaml
apiVersion: v1
kind: Secret
metadata:
    name: sa-provider-secret
stringData:
    credentials: |
        {
          "username": "tech_user",
          "password": "INJECT_ENV.TECHNICAL_USER_EMAIL"
        }
EOF

# add your crs to the crs folder, using PLACEHOLDER for unique naming:
cat <<EOF > providers/provider-example/$VERSION/crs/book.yaml
apiVersion: example.crossplane.io/v1alpha1
kind: Book
metadata:
  name: my-bookPLACEHOLDER
spec:
  forProvider:
    name: example-book
EOF

cat <<EOF > providers/provider-example/$VERSION/crs/shelf.yaml
apiVersion: example.crossplane.io/v1alpha1
kind: Shelf
metadata:
  name: my-shelf-PLACEHOLDER
spec:
  forProvider:
    name: example-shelf
EOF

# generate the chainsaw-test.yaml for the crs using the helper script:
./generate-chainsaw-test.sh providers/provider-example/$VERSION/crs
mv auto-generated-chainsaw-test.yaml providers/provider-example/$VERSION/chainsaw-test.yaml
```

With steps above, you can run a test for provider provider-example to upgrade from version v1.0 to version v2.0:
```shell
export TECHNICAL_USER_EMAIL=your_password
REGISTRY=ghcr.io/sap/crossplane-provider-example
./provider-test.sh upgrade-test --source "${REGISTRY}:v1.0" --target "${REGISTRY}:v2.0" --source-dir provider-example/v1.0 --provider provider-example
```

### Add new version for existing provider
When there's a new version released for existing provider (e.g. `provider-btp` version `v8.0`):
```shell
export VERSION=v8.0
mkdir providers/provider-btp/$VERSION providers/provider-btp/$VERSION/setup
# add setup folder and adjust content if needed
cp -r providers/provider-btp/v1.0.3/setup/ providers/provider-btp/$VERSION/setup/

# add v8.0 specific resources if they exist
mkdir providers/provider-btp/$VERSION/crs
cat <<EOF > providers/provider-btp/$VERSION/crs/subaccount.yaml
apiVersion: account.btp.sap.crossplane.io/v1alpha1
kind: Subaccount
metadata:
  name: upgrade-test-subaccount-PLACEHOLDER
spec:
  forProvider:
    description: hello subaccount
    new-field-v8: this is a new key-value
EOF

# copy and modify chainsaw-test.yaml
cp providers/provider-btp/v1.0.3/chainsaw-test.yaml providers/provider-btp/$VERSION/chainsaw-test.yaml
# modify file locations for crs if needed: change from file: crs/directory.yaml to file: ../v1.0.3/crs/directory.yaml
```

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/openmcp-project/provider-upgrade-test/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/openmcp-project/provider-upgrade-test/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/SAP/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2025 SAP SE or an SAP affiliate company and provider-upgrade-test contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/openmcp-project/provider-upgrade-test).
