# dk distribute GitHub Action

This GitHub Action distributes your [dk values and their dependencies](https://github.com/diskuv/dk.git).

Follow the [Preparation](#preparation) and add the GitHub Workflow file `.github/workflows/distribute-0.1.yml` (adjust the filename and contents if major/minor version is different):

```yaml
# file: .github/workflows/distribute-0.1.yml
on:
  push:
    tags:
      - '0.1.*' # secrets are tied to major/minor version
  workflow_dispatch: # allow manual triggering from GitHub page

jobs:
  distribute:
    permissions:
      contents: write # for action-gh-release
      id-token: write # for actions/attest-build-provenance
      attestations: write # for actions/attest-build-provenance
      artifact-metadata: write # for actions/attest-build-provenance

    # The secrets created by `./dk0 prepare-version --ci github MAJOR.MINOR`
    # are tied to this environment only.
    environment: dk-distribution

    strategy:
      fail-fast: true
      matrix:
        # the list of platforms to build on.
        include:
          # IS YOUR PACKAGE CROSS-PLATFORM?
          # Yes ...
          - runs-on: ubuntu-latest
            distscript: dist-any.u

          # No .... each of your supported platforms should have its own distribution script
          - runs-on: windows-latest
            distscript: dist-win32.u
          - runs-on: ubuntu-latest
            distscript: dist-linux.u
          - runs-on: macos-latest
            distbase: dist-macos.u

    runs-on: ${{ matrix.runs-on }}
    steps:
      - name: Harden Runner # Optional but recommended
        uses: step-security/harden-runner@f808768d1510423e83855289c910610ca9b43176 # v2.17.0
        with: { egress-policy: audit }
      - name: Checkout repository
        uses: actions/checkout@v6

      - name: Distribute Modules
        uses: diskuv/dk-distribute@v2
        with:
            pubkey: ${{ secrets.distribute_1_0_pubkey }} # change based on MAJOR.MINOR
            seckey: ${{ secrets.distribute_1_0_seckey }} # change based on MAJOR.MINOR
            use-cache: true
            distscript: ${{ matrix.distscript }}

      - name: Attest
        id: attest
        uses: actions/attest-build-provenance@v3
        with: { subject-path: dk-dist/* }

      - name: Release ${{ github.job }}
        uses: softprops/action-gh-release@153bb8e04406b158c6c84fc1615b65b24149a1fe # v2.6.1. Mar 15, 2026
        with: { files: dk-dist/*, body_path: "${{ github.workspace }}-CHANGELOG.txt" }
```

Be sure to review the following places carefully:

+ the filename should match the `MAJOR.MINOR` version you prepared
+ the `jobs / 'distribute' / strategy / matrix / include`
+ the `jobs / 'distribute' / steps / 'Distribute Modules' / pubkey`
+ the `jobs / 'distribute' / steps / 'Distribute Modules' / seckey`

Now, when you push a git tag, the GitHub Actions will create the following directories in your project directory:

| Directory | Contents                        |
| --------- | ------------------------------- |
| `dksrc/`  | The dk build system             |
| `t/`      | Cache, data and key directories |

and build the dk values from your distribution script (`distscript`).

## Preparation

The distribution keys and files will be prepared for you when you run the command `prepare-version --ci github MAJOR.MINOR`.

For example, if this is your first major and minor version, open PowerShell or a UNIX shell and type:

```sh
./dk0 -- prepare-version --ci github 0.1
```

## Cache value and trace stores

Caching reduces build and download time. Caching is disabled by default since pristine builds are recommended when distributing builds to the public.

You can opt in to caching by passing `'true'` to the `use-cache` input:

```yaml
- name: Distribute Modules
  uses: diskuv/dk-distribute@v2
  with:
    use-cache: 'true'
```

## Experimental Features

### Reference Build System

Normally the Action uses the latest release of the `dksrc/dk0` reference build system.

However, the following will build the [reference build system](https://gitlab.com/dkml/build-tools/MlFront.git) with the specific git reference:

```yaml
- name: dk distribute
  uses: diskuv/dk-distribute@v2
  with:
    experimental-mlfront-ref: HEAD
```

Building the reference system takes time. And the reference system builds slower than `dk`.

Do not use for production. This is meant only for troubleshooting issues or in high-compliance situations.
