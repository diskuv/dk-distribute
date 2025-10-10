# dk distribute GitHub Action

This GitHub Action distributes your [dk forms and their dependencies](https://github.com/diskuv/dk.git)
by following the [Preparation](#preparation) and adding a step to your workflow:

```yaml
- name: Distribute Modules
  uses: diskuv/dk-distribute@v1
  if: github.ref_type == 'tag'
  with:
    id: YourLibrary_Std@${{ github.ref_name }} # change!
    pubkey: ${{ secrets.distribute_1_0_pubkey }} # change based on `version`
    seckey: ${{ secrets.distribute_1_0_seckey }} # change based on `version`
    slots: |
        Debug.Agnostic
        Release.Agnostic
    forms: |
        YourLibrary_Std.Abc@1.2.3
        YourLibrary_Std.Def@4.5.6
        YourLibrary_Std.Ghi.Jkl@7.8.9
```

All combinations of slots and forms will be built.

The following directories will be created in your project directory:

| Directory    | Contents                                    |
| ------------ | ------------------------------------------- |
| `dk0/`       | The dk build system                         |
| `target/dk/` | Data directories for value and trace stores |

## Preparation

The distribution keys and files will be prepared for you if you run:

```sh
dk0/mlfront-shell -- prepare-version --ci github 1.0
```

## Cache value and trace stores

Caching reduces build and download time. Caching is disabled by default since pristine builds are recommended when distributing builds to the public.

You can opt in to caching by passing `'true'` to the `use-cache` input:

```yaml
- name: Distribute Modules
  uses: diskuv/dk-distribute@v1
  with:
    use-cache: 'true'
```

## Experimental Features

### Reference Build System

Normally the Action uses the latest release of the `dk0/mlfront-shell` reference build system.

However, the following will build the [reference build system](https://gitlab.com/dkml/build-tools/MlFront.git) with the specific git reference:

```yaml
- name: dk distribute
  uses: diskuv/dk-distribute@v1
  with:
    experimental-mlfront-ref: HEAD
```

Building the reference system takes time. And the reference system builds slower than `dk`.

Do not use for production. This is meant only for troubleshooting issues or in high-compliance situations.
