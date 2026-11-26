# APIM APIOps

Extract and publish our Azure API Management resources with [APIOps CLI](https://github.com/Azure/apiops-cli) `@azure-tools/apiops-cli@1.0.5`.

## Repository structure

| Path | Description |
|---|---|
| `configuration.extractor.yaml` | Filter: the resources this repo manages. Used by extract and publish. |
| `configuration.extractor.example.yaml` | Filter examples. Not used by pipelines. |
| `configuration.<env>.yaml` | Overrides for `dev`, `test1`, `test2`, `prod`. |
| `configuration.example.yaml` | Override examples (URLs, credentials, Key Vault references). Not used by pipelines. |
| `apim-artifacts/` | Extracted resources. Created by the extract pipeline. |
| `pipelines/apiops-extract.yml` | Extract from dev and open a PR. |
| `pipelines/apiops-publish.yml` | Publish to dev → test1 → test2 → prod. |
| `pipelines/templates/` | Shared steps and stages. |
| `pipelines/variables/<env>.yml` | Service connection, resource group, APIM name and Azure DevOps environment per environment. |
| `scripts/Test-Ownership.ps1` | Ownership check, run by both pipelines. |

## Environments

| Environment | Role | Settings file | Approval |
|---|---|---|---|
| dev | Extract source, publish target | `pipelines/variables/dev.yml` | No |
| test1 | Publish target | `pipelines/variables/test1.yml` | No |
| test2 | Publish target | `pipelines/variables/test2.yml` | No |
| prod | Publish target | `pipelines/variables/prod.yml` | Yes |

## Setup

### 1. Fill in placeholders

Replace every `REPLACE-ME` value:

| File | Values |
|---|---|
| `configuration.extractor.yaml` | API, backend and other resource names. See `configuration.extractor.example.yaml`. |
| `configuration.test1.yaml`, `configuration.test2.yaml`, `configuration.prod.yaml` | Environment-specific values. See `configuration.example.yaml`. |
| `pipelines/variables/<env>.yml` | Service connection name, resource group, APIM name, Azure DevOps environment name. |

The pipelines fail while placeholders remain.

### 2. Azure DevOps

- [ ] **Service connections**: one per environment (Azure Resource Manager, workload identity federation). Names must match `pipelines/variables/<env>.yml`.
- [ ] **Role assignments**: each service connection identity needs `API Management Service Contributor` on its APIM instance.
- [ ] **Environments**: one Azure DevOps environment per APIM environment (Pipelines > Environments). Names go in `devOpsEnvironment` in `pipelines/variables/<env>.yml`.
- [ ] **Exclusive lock**: add an **Exclusive lock** check to all four environments.
- [ ] **Prod approval**: add an **Approvals** check to the prod Azure DevOps environment.
- [ ] **Branch control** (optional): add a **Branch control** check allowing only `refs/heads/main` to each environment.
- [ ] **Pipelines**: create pipelines from `pipelines/apiops-extract.yml` and `pipelines/apiops-publish.yml`.
- [ ] **Pipeline permissions**: authorize `apiops-publish` on the four service connections and four environments, and `apiops-extract` on the dev service connection.
- [ ] **Repository permissions**: grant the project build service identity **Contribute**, **Create branch** and **Contribute to pull requests** on this repository.
- [ ] **Key Vault**: grant each APIM instance's managed identity `Key Vault Secrets User` on the Key Vault it reads.

Notes:

- **Variable groups (Library)**: not used. Secrets are Key Vault-backed named values; APIM reads them from Key Vault.
- **Marketplace extensions**: none required.
- **Approval checks on service connections**: do not add them. The prod dry-run stage would wait for them.

### 3. Local check (optional)

Requires PowerShell 7.

```powershell
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser
./scripts/Test-Ownership.ps1 -Filter configuration.extractor.yaml -Artifacts apim-artifacts `
  -Overrides configuration.dev.yaml, configuration.test1.yaml, configuration.test2.yaml, configuration.prod.yaml
```

## Extract

1. Make the change in the **dev** APIM.
2. Run **apiops-extract** from `main`.
3. Review and merge the PR from `apiops/extract-<buildId>`.

The pipeline runs:

```bash
apiops extract --filter ./configuration.extractor.yaml --no-transitive --remove-stale
```

It then runs the ownership check. If the check fails, no PR is created.

## Publish

Merging to `main` with changes in `apim-artifacts/` or `configuration.*.yaml` starts **apiops-publish**.

| Stage | Steps |
|---|---|
| Validate | Ownership check against all override files. |
| Publish dev, test1, test2 | Ownership check → `--dry-run` → publish. |
| Dry-run prod | Ownership check → `--dry-run`. |
| Publish prod | Approval → ownership check → `--dry-run` → publish. |

Every publish runs:

```bash
apiops publish --filter ./configuration.extractor.yaml --no-transitive --overrides ./configuration.<env>.yaml
```

- Publish stages run only on `main`.
- Each run publishes all filtered resources (not incremental).
- No DELETE requests are sent (`--delete-unmatched` is not used).

## Add a new API

1. Create the API in the **dev** APIM.
2. Create a branch. In `configuration.extractor.yaml`, add:
   - the API resource name under `apis`;
   - the backends, named values, policy fragments and version sets that we own and the API uses.
3. In `configuration.test1.yaml`, `configuration.test2.yaml` and `configuration.prod.yaml`, add an entry for each new environment-specific value (backend URL, named value, Key Vault reference).
4. In all four override files, including `configuration.dev.yaml`, add credentials for each new backend whose extracted credentials contain `null`. See `configuration.example.yaml`.
5. Push the branch and run **apiops-extract** on it.
6. Review and merge the PR. It contains the filter change and the extracted artifacts.
7. After each environment's publish stage, add the API to its products and tags in that environment (see [Limitations](#limitations)).

## Remove an API

1. Remove the API from `configuration.extractor.yaml`.
2. Delete `apim-artifacts/apis/<name>/` and every `apim-artifacts/apis/<name>;rev=*/` folder.
3. Remove backends, named values, policy fragments and version sets used only by that API from the filter, the artifacts and the override files.
4. Merge. The API stays in APIM; delete it there manually if required.

## Overrides

Examples: [configuration.example.yaml](configuration.example.yaml).

- `name` is the folder name under `apim-artifacts/<type>/`.
- `properties` holds the ARM properties to replace. Keys are case-sensitive.
- Dictionaries are merged into the extracted values; lists and scalar values replace them.
- Values without an override are published with the dev value.
- Names must exist in `apim-artifacts/`. The ownership check fails on unknown names.
- Full format: [environment-overrides.md](https://github.com/Azure/apiops-cli/blob/v1.0.5/docs/guides/environment-overrides.md).

## Secrets

Secrets are Key Vault-backed named values. Secret values are never stored in git or in pipeline variables.

1. In each environment's Key Vault, create the secret (same secret name in every vault).
2. Grant the APIM managed identity `Key Vault Secrets User` on the vault.
3. In the **dev** APIM, create the named value as **Key vault** type, pointing at the dev vault.
4. Add the named value's resource name to `namedValues` in `configuration.extractor.yaml`.
5. In `configuration.test1.yaml`, `configuration.test2.yaml` and `configuration.prod.yaml`, set `keyVault.secretIdentifier` to that environment's vault. See `configuration.example.yaml`.
6. Reference it as `{{<display-name>}}` in policies and backend credentials.

Facts:

- Key Vault-backed named values are extracted with their `secretIdentifier`.
- Secret named values that are not Key Vault-backed are extracted as `*** REDACTED ***`. Publish and dry-run fail in every environment while that value remains.
- `{#[...]#}` tokens are not substituted. The ownership check fails if an override file contains one.

## Ownership check

`scripts/Test-Ownership.ps1` fails when:

| Check | Condition |
|---|---|
| Filter | A filter key is missing, empty, not a list, or has the wrong case. |
| Filter | An entry contains `*` or `?`, starts with `!`, or contains `REPLACE-ME`. |
| Filter | `policies` or `workspaces` is not `[]`. |
| Artifacts | A folder in `apim-artifacts/` is not in the filter. |
| Artifacts | `apim-artifacts/policy.xml` (service-level policy) exists. |
| Backends | A header value, authorization parameter, or `code` / `sig` / `subscription-key` query value is a literal instead of a `{{named-value}}` reference. |
| Overrides | A key is unknown or has the wrong case. |
| Overrides | A value contains `REPLACE-ME` or a `{#[...]#}` token. |
| Overrides | A name does not exist in `apim-artifacts/`. |
| Overrides | A backend would be published with `null` credential values, or the override sets `credentials` to `null`. |

## Limitations

- **Shared dependencies**: shared named values, backends, policy fragments, loggers and version sets referenced by our APIs are not extracted or published. They must exist in every environment.
- **Tags and products**: API tag links and product membership are not published (`tags: []`, `products: []`). Add them manually in each environment.
- **Dry-run**: the output lists the resources to be written. It does not show a diff or check that shared dependencies exist.
- **Partial publish**: if a publish fails partway, earlier resources in that environment are already written.
- **Publishing to dev**: overwrites changes made in dev after the last extract, for resources in the filter.

## Upgrade the CLI

1. Set the exact version in `package.json`.
2. Run `npm install`.
3. Commit `package.json` and `package-lock.json`.

Release notes: [CHANGELOG.md](https://github.com/Azure/apiops-cli/blob/v1.0.5/CHANGELOG.md).
