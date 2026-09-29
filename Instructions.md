# End-to-end deployment instructions

This runbook describes how to take a fresh fork of this repository from an empty Azure
environment to a working Microsoft Foundry Autopilot in Microsoft Teams and Microsoft 365
Copilot.

It is intentionally more detailed than the shortest path in [README.md](README.md). It includes
the repository customization, authentication, private GitHub runner, Microsoft 365 approval, and
Autopilot instance creation steps that are easy to miss.

These instructions were validated against the repository state on September 28, 2026. Microsoft
Foundry hosted agents and Microsoft Agent 365 use preview APIs, so confirm the linked Microsoft
documentation if a portal label or licensing requirement changes.

## What this deployment does

The completed deployment has five distinct stages:

1. Fork and customize the repository.
2. Run `azd up` from an operator workstation to provision Azure and deploy the MCP and YARP apps.
3. Use the in-VNet Linux GitHub Actions runner to deploy and govern the Foundry agent.
4. Use a delegated user sign-in during the workflow to submit the Autopilot to Microsoft 365.
5. Have a Microsoft 365 administrator approve the blueprint, then create an Autopilot instance.

`azd up` alone does not deploy the agent or make it available in Microsoft 365.

## Where each operation runs

| Location | Responsibilities |
|---|---|
| Operator workstation | Fork/clone, customize configuration, authenticate CLIs, run `azd`, and dispatch/monitor GitHub workflows. |
| In-VNet Linux VM | Persistent self-hosted GitHub Actions runner. It deploys agents and applies private Foundry, APIM, MCP, YARP, and Teams governance. |
| Optional Windows dev VM | Human diagnostics through Azure Bastion only. It is not required for deployment and is not the GitHub runner. |
| GitHub Actions web UI | Dispatch and monitor the agent workflow. The device-code authentication instructions appear in the workflow log. |
| Microsoft 365 admin center | Approve the submitted Autopilot blueprint, choose its audience and policy, and grant appropriate consent. |
| Teams or Microsoft 365 Copilot | Create, or "hire," an approved Autopilot instance and test it. |

You do not need to connect to the Windows jumpbox to deploy the agent. The trusted Linux runner is
the component that gives the GitHub workflow private network access.

## 1. Confirm prerequisites

### 1.1 Accounts and permissions

The people performing the deployment need the following access.

| Operation | Required access |
|---|---|
| Fork configuration and runner registration | Administrator access to the GitHub fork. |
| Azure provisioning | Azure **Owner**, or **Contributor** plus **Role Based Access Control Administrator**, at the deployment scope. |
| Foundry blueprint deployment and publication | **Foundry User** at the project scope. |
| Microsoft 365 publication sign-in | A user in the same tenant as `TEAMS_TENANT_ID` who can publish the blueprint. |
| Microsoft 365 approval | **Global Administrator** or **AI Administrator**. Reader roles cannot approve. |
| Autopilot instance creation | The user must be included in the hiring/activation scope chosen by the administrator. |

Provisioning creates role assignments, so Azure Contributor by itself is not enough.

### 1.2 Microsoft Agent 365 readiness

Before publishing, confirm that the Microsoft 365 tenant:

- is enrolled in the applicable Microsoft Agent 365/Frontier program;
- has accepted the Microsoft Agent 365 terms of service;
- has at least one qualifying Microsoft 365 Copilot or Microsoft Agent 365 license;
- has an available Autopilot/Frontier seat for every instance that will be created; and
- has a Global Administrator or AI Administrator available to approve the blueprint.

An Azure deployment can succeed even when the tenant is not ready to create an Autopilot instance.
Check this before spending time troubleshooting the Azure environment.

See:

- [Microsoft Agent 365 integration with Foundry](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-365-integration)
- [Build your first Autopilot](https://learn.microsoft.com/azure/foundry/agents/how-to/agent-365)

### 1.3 Local tools

Install these tools on the workstation:

- Git;
- Azure CLI (`az`);
- Azure Developer CLI (`azd`);
- GitHub CLI (`gh`);
- PowerShell 7 (`pwsh`);
- Node.js/npm for the MCP App Service build; and
- .NET 10 SDK for the YARP gateway build.

Confirm the important tools:

```powershell
git --version
az version
azd version
gh --version
pwsh --version
node --version
npm --version
dotnet --version
```

### 1.4 Region and model capacity

Choose one Azure region that:

- supports Microsoft Foundry hosted agents;
- supports the models and versions declared in [infra/main.parameters.json](infra/main.parameters.json);
- has sufficient quota for the requested capacity; and
- is acceptable for the organization's data residency requirements.

Do not begin in one region with the intention of moving the deployed environment later. Resource
names, private endpoints, model deployments, and the Foundry project are created together.

## 2. Fork and clone the repository

Fork the source repository into the GitHub account or organization that will own the deployment.
A public fork works, but read [Public-fork runner security](#public-fork-runner-security) before
provisioning the runner.

Clone the fork, not the upstream repository:

```powershell
git clone https://github.com/<YOUR_GITHUB_OWNER>/locked-down-foundry-m365-agent.git
Set-Location .\locked-down-foundry-m365-agent
git remote add upstream https://github.com/graemefoster/locked-down-foundry-m365-agent.git
git remote -v
```

Expected:

```text
origin    https://github.com/<YOUR_GITHUB_OWNER>/locked-down-foundry-m365-agent.git
upstream  https://github.com/graemefoster/locked-down-foundry-m365-agent.git
```

Enable GitHub Actions on the fork if GitHub initially disables workflows inherited from the
source repository.

## 3. Verify that the fork contains the deployment fixes

These checks are important when the fork was created from a source revision older than this
workspace. Do not deploy until all of them are true.

### 3.1 Linux shell line endings

[.gitattributes](.gitattributes) must contain:

```gitattributes
*.sh text eol=lf
```

[infra/stages/40-runner/resources/vm-runner-extension.bicep](infra/stages/40-runner/resources/vm-runner-extension.bicep)
must normalize the embedded runner bootstrap script:

```bicep
var bootstrapScript = replace(loadTextContent('bootstrap-github-runner.sh'), '\r\n', '\n')
```

Without both protections, a Windows checkout can cause the Linux runner installation to fail with:

```text
set: pipefail\r: invalid option name
```

### 3.2 Foundry local authentication

[infra/stages/13-foundry/foundry/ai-services-account.bicep](infra/stages/13-foundry/foundry/ai-services-account.bicep)
must set:

```bicep
disableLocalAuth: true
```

### 3.3 APIM hardening in both declarations

Both of these full-resource APIM declarations must preserve the same portal, NAT, TLS, and cipher
settings:

- [infra/stages/10-platform/model-gateway/apim.bicep](infra/stages/10-platform/model-gateway/apim.bicep)
- [infra/stages/30-governance/model-gateway/apim-lockdown.bicep](infra/stages/30-governance/model-gateway/apim-lockdown.bicep)

At minimum, confirm:

```bicep
developerPortalStatus: 'Disabled'
legacyPortalStatus: 'Disabled'
natGatewayState: 'Enabled'
```

and that SSL 3.0, TLS 1.0, TLS 1.1, and 3DES are disabled in `customProperties`.

The second APIM declaration is a full PUT. If it omits these properties, a later deployment can
undo the settings from the initial declaration.

## 4. Customize the fresh fork

Commit these changes to the fork before provisioning. The runner checks out committed GitHub
content, not uncommitted files from the workstation.

### 4.1 Retarget exact repository guards

Privileged workflows contain an exact `github.repository` guard. Find every guard:

```powershell
git grep -n "github.repository ==" -- .github/workflows
```

Change the repository slug in every result to:

```yaml
if: github.repository == '<YOUR_GITHUB_OWNER>/locked-down-foundry-m365-agent'
```

The current repository uses guards in reusable deployment/governance workflows, publishing
workflows, Autopilot workflows, and the nightly evaluation workflow. Do not update only the
top-level dispatchable workflow; a reusable job with the old guard will silently skip.

Run the search again and confirm all guard values target the fork. Retain the exact-repository
guard. Do not replace it with a broad owner check.

The URL in [.github/ISSUE_TEMPLATE/config.yml](.github/ISSUE_TEMPLATE/config.yml) is not part of
deployment, but update it if the fork will use GitHub issue templates.

### 4.2 Replace tenant-specific token principals

[agents/grf-2026-autopilot-agent/network.json](agents/grf-2026-autopilot-agent/network.json)
contains example email addresses and a placeholder application ID. Replace or remove them.

Each token-limit principal must contain:

- a real user email, a real Entra application/client ID, or both;
- a justified `tokensPerMinute`; and
- an optional positive quota and valid quota period.

Never leave the placeholder application ID
`11111111-1111-1111-1111-111111111111` in a real deployment.

If the `/agents/<agentName>/...` YARP route is not needed, consider setting
`exposeFoundryApi` to `false` rather than publishing an unused route.

See [docs/configuration.md](docs/configuration.md) for the complete contract.

### 4.3 Align the hosted agent with a deployed model

The model name in
[agents/grf-2026-autopilot-agent/agent.yaml](agents/grf-2026-autopilot-agent/agent.yaml)
must match a model deployment available to the Foundry project.

The current infrastructure defaults deploy the primary model as `gpt-5.4`, while the agent
manifest currently contains:

```yaml
AZURE_AI_MODEL_DEPLOYMENT_NAME: gpt-5-mini
```

For an unchanged infrastructure configuration, change the agent value to:

```yaml
AZURE_AI_MODEL_DEPLOYMENT_NAME: gpt-5.4
```

Alternatively, deliberately deploy `gpt-5-mini` and use that exact deployment name. Do not treat a
successful source-ZIP upload as proof that the model name is valid; the mismatch appears only when
the agent handles a message.

### 4.4 Review Autopilot metadata and permissions

Update [agents/grf-2026-autopilot-agent/autopilot.json](agents/grf-2026-autopilot-agent/autopilot.json)
with real organizational metadata:

- developer name;
- developer website;
- privacy URL;
- terms-of-use URL;
- accurate short and full descriptions; and
- an intentional semantic `appVersion`.

Do not place secrets in these fields. They are visible to users and administrators.

The current simple agent in
[agents/grf-2026-autopilot-agent/simple-autopilot-agent/agent/app.py](agents/grf-2026-autopilot-agent/simple-autopilot-agent/agent/app.py)
only sends message text to the Foundry Responses API. It does not currently call Work IQ, the
repository MCP server, Mail, Word, OneDrive/SharePoint, Teams tools, Excel, or Calendar.

For a least-privilege deployment of the simple agent:

1. remove the unused `optionalPermissionScopes` array from `autopilot.json`; and
2. remove claims about Work IQ from the description.

Keep or add permission scopes only after the implementation actually uses them and the tenant
administrator has reviewed the resulting data access.

If an agent is changed after a Microsoft 365 version has been published, increment `appVersion`.
Publishing the same version again is a no-op.

### 4.5 Decide how Microsoft 365 reaches the Activity Protocol

The GRF Autopilot manifest currently uses:

```yaml
activity:
  enable_m365_public_endpoint: true
```

This is a Foundry-managed, source-filtered public exception for the Activity Protocol. It does not
set the Foundry account's general `publicNetworkAccess` property to `Enabled`, and all non-Activity
project APIs remain private.

If organizational policy permits that scoped exception, keep the setting. This is the simplest
Autopilot path.

If policy prohibits every Foundry-hosted public exception, use the customer-owned YARP/APIM front
door approach documented in [docs/publish-m365-vnet.md](docs/publish-m365-vnet.md). In that design:

- set `enable_m365_public_endpoint` to `false`;
- keep Foundry fully private;
- publish the public YARP/APIM Activity Protocol endpoint; and
- update the blueprint endpoint as documented.

Do not enable general public network access on the Foundry account as a shortcut.

### 4.6 Configure MCP access only if the agent uses MCP

[mcp/mcp-policy.json](mcp/mcp-policy.json) currently permits
`grf-2026-teams-agent`, not `grf-2026-autopilot-agent`.

That is acceptable for the current simple Autopilot because it does not call MCP. If MCP tools are
added to the Autopilot, add its exact agent name to the appropriate MCP server policy and choose an
intentional request limit. An omitted agent remains denied by design.

### 4.7 Commit and push the customization

Review the changes before committing:

```powershell
git diff --check
git diff
git status --short
```

Commit and push them to the fork's default branch. The exact commit message is up to the operator:

```powershell
git add .github agents .gitattributes infra mcp
git commit -m "Configure locked-down Foundry deployment for tenant"
git push origin main
```

Do not commit the `.azure/` directory, PATs, access tokens, passwords, or generated agent ZIP
files.

## 5. Authenticate the workstation

Use the tenant, subscription, and GitHub account that own the deployment:

```powershell
az login --tenant <AZURE_TENANT_ID>
az account set --subscription <AZURE_SUBSCRIPTION_ID>
azd auth login --tenant-id <AZURE_TENANT_ID>
gh auth login
```

Verify the selected identities:

```powershell
az account show --query "{tenant:tenantId,subscription:id,user:user.name}" --output table
gh auth status
gh repo view <YOUR_GITHUB_OWNER>/locked-down-foundry-m365-agent --json nameWithOwner,url
```

The `gh` account must have permission to:

- manage the fork's self-hosted runners; and
- create/update GitHub Actions repository variables.

It is possible to be authenticated to GitHub successfully while using a different account that
has read-only access to the fork. Correct that before provisioning.

## 6. Create the one azd environment

This repository manages one Azure/Foundry environment. The local azd environment name is just a
local state label; it is not a dev/test deployment lane.

Create and select it:

```powershell
azd env new <AZD_ENV_NAME>
azd env set AZURE_LOCATION <SUPPORTED_AZURE_REGION>
```

Use one region and unsuffixed resource/workflow variables. Do not create parallel
environment-suffixed manifests or repository variables.

## 7. Create the GitHub runner bootstrap PAT

The private runner needs a fine-grained GitHub PAT only to request a short-lived runner
registration token.

Create the PAT at:

<https://github.com/settings/personal-access-tokens>

Use:

- resource owner: the fork owner;
- repository access: only this fork;
- repository permission: **Administration: Read and write**;
- a short, managed expiration appropriate for the environment; and
- no unrelated permissions.

This PAT is not:

- a GitHub Actions secret;
- the token used by the workflow to access Azure;
- the Microsoft 365 delegated publication token; or
- committed to Git.

During provisioning, the PAT is written to the gitignored azd environment, then stored as a Key
Vault secret. The Linux VM managed identity reads it from Key Vault during runner bootstrap.

## 8. Preview the deployment and answer first-run questions

Run the provisioning preview from the repository root:

```powershell
azd provision --preview
```

The interactive `preprovision` hook asks:

1. **Deploy the Windows dev VM?**
   Recommended for the normal deployment: `N`. It is an optional diagnostics machine with
   additional VM and Bastion cost.

2. **GitHub repository URL for the self-hosted runner?**
   Enter:

   ```text
   https://github.com/<YOUR_GITHUB_OWNER>/locked-down-foundry-m365-agent
   ```

3. **Fine-grained PAT?**
   Paste the PAT when prompted. Input is hidden.

4. **Allow the operator's public IP through the public YARP edge?**
   Recommended: `N` unless direct workstation testing of the public edge is required. Microsoft
   Teams service ranges remain allowed.

The Bicep deployment can also prompt for:

- Basic versus Standard agent setup;
- the Linux VM administrator username; and
- a strong VM administrator password.

The Basic setup is faster and uses Microsoft-managed agent state. The Standard setup adds the
customer-owned Cosmos DB, Storage, and AI Search state stores. Choose based on the intended
architecture, not merely to avoid deployment time.

### Existing empty values do not reprompt

The hook treats an existing azd key as answered even when its value is empty. If the runner URL or
PAT was previously skipped, set both explicitly before retrying:

```powershell
azd env set GITHUB_RUNNER_REPO_URL https://github.com/<YOUR_GITHUB_OWNER>/locked-down-foundry-m365-agent
azd env set GITHUB_RUNNER_PAT <FINE_GRAINED_PAT>
```

The second command can be visible in shell history and process arguments. Prefer the hidden
first-run prompt when possible, and protect the workstation when explicit recovery is required.

### Review the preview

For a genuinely fresh environment, the preview should predominantly create resources.

For an existing environment, stop and investigate changes that would:

- enable general public access on Foundry or private backends;
- set `disableLocalAuth` to `false`;
- enable APIM developer or legacy portals;
- disable the APIM NAT Gateway;
- remove APIM TLS/cipher hardening;
- remove private endpoints, private DNS, CMK, or managed identities; or
- broaden YARP/APIM/MCP allowlists.

Azure What-If often reports expression-versus-resolved-value differences and removal of
service-generated read-only properties. Review security-sensitive full-resource PUTs instead of
assuming every reported removal is harmless.

## 9. Provision Azure and deploy the platform apps

After accepting the preview:

```powershell
azd up
```

`azd up`:

1. provisions the hub/spoke network, firewall, private DNS, Foundry, models, APIM, Key Vault, ACR,
   App Services, private endpoints, managed identities, RBAC, and Linux runner VM;
2. installs/registers the self-hosted GitHub runner;
3. builds and deploys the MCP Node application;
4. builds and deploys the YARP .NET application;
5. temporarily opens only the required App Service SCM access for deployment;
6. relocks SCM access in the post-deploy hook; and
7. copies Bicep outputs to GitHub Actions repository variables.

APIM and private endpoint provisioning can take a significant amount of time. Do not cancel the
operation merely because one resource remains in progress for several minutes.

The phase-specific recovery commands are:

```powershell
azd provision
azd deploy
azd hooks run postprovision
azd hooks run postdeploy
```

Use `azd` exclusively for infrastructure and MCP/YARP application deployment. Do not introduce a
parallel `az deployment` lifecycle.

## 10. Verify the platform before deploying the agent

### 10.1 Confirm azd succeeded

There must be no failed provisioning or service deployment step. If `azd deploy` was interrupted
after opening SCM, run:

```powershell
azd hooks run postdeploy
```

Treat an SCM endpoint left open as a failed deployment.

### 10.2 Confirm the runner

In the fork, open:

```text
Settings -> Actions -> Runners
```

Confirm one idle/online Linux runner with these labels:

```text
self-hosted
Linux
X64
vnet
foundry-private
```

The VM is expected to initiate outbound GitHub connectivity. No inbound SSH/RDP path to the Linux
runner is needed.

### 10.3 Confirm repository variables

List the variables:

```powershell
gh variable list --repo <YOUR_GITHUB_OWNER>/locked-down-foundry-m365-agent
```

At minimum, verify the variables consumed by
[.github/workflows/deploy-grf-2026-autopilot-agent.yml](.github/workflows/deploy-grf-2026-autopilot-agent.yml),
including:

- `AZURE_SUBSCRIPTION_ID`;
- `AZURE_RESOURCE_GROUP`;
- `AZURE_AI_PROJECT_ENDPOINT`;
- `AZURE_AI_PROJECT_NAME`;
- `MCP_SERVER_URL`;
- `MCP_COMPLIANCE_APIM_NAME`;
- `MCP_COMPLIANCE_AUDIENCE`;
- `MCP_WEBAPP_NAME`;
- `FOUNDRY_AGENTS_APIM_NAME`;
- `FOUNDRY_AGENTS_API_NAME`;
- `FOUNDRY_AGENTS_API_PATH`;
- `FOUNDRY_AGENTS_ACCOUNT_NAME`;
- `FOUNDRY_AGENTS_AUDIENCE`;
- `TEAMS_APIM_NAME`;
- `TEAMS_APIM_API_NAME`;
- `TEAMS_TENANT_ID`;
- `TEAMS_YARP_WEBAPP_NAME`; and
- `AZURE_CONTAINER_REGISTRY_NAME`.

If they are missing, first confirm `gh auth status` is using the fork administrator, then run:

```powershell
azd hooks run postprovision
```

Do not copy the runner PAT into GitHub Actions secrets.

### 10.4 Confirm security invariants

Verify in Azure Portal or with read-only Azure CLI queries that:

- the primary Foundry account has general public network access disabled;
- Foundry local authentication is disabled;
- Foundry and its state stores have approved private endpoints;
- APIM public network access is disabled after private endpoint creation;
- APIM developer and legacy portals are disabled;
- APIM NAT Gateway remains enabled;
- the MCP App Service is private;
- the YARP edge is public only where intended and uses a default-deny IP policy; and
- temporary SCM allow rules are absent.

Do not weaken these settings to make a workstation reach the private Foundry data plane. Agent
deployment belongs on the in-VNet runner.

## 11. Deploy, govern, and submit the Autopilot

The most reliable first run is from the GitHub web UI because the delegated device code is printed
in the live job log.

1. Open the fork on GitHub.
2. Select **Actions**.
3. Select **Deploy grf-2026-autopilot-agent**.
4. Select **Run workflow** on the default branch.
5. Open the running job.
6. Expand **Sign in and acquire the delegated user token**.
7. Open the Microsoft device-login URL shown in the log.
8. Enter the displayed code.
9. Sign in as the intended publishing user in the `TEAMS_TENANT_ID` tenant.

The device-code prompt is not entered into a GitHub input field. GitHub only displays the code;
authentication is completed in a normal browser.

The workflow then:

1. checks out the committed fork;
2. creates the Python source ZIP;
3. normalizes `agent.yaml` to JSON;
4. obtains the delegated user token;
5. deploys a new hosted-agent version to private Foundry;
6. restores the VM managed-identity Azure session;
7. applies Foundry token limits;
8. applies YARP routes;
9. applies the MCP allowlist;
10. applies Teams audiences; and
11. publishes the Autopilot blueprint to Microsoft 365.

Shared governance writes are deliberately serialized. Do not run multiple agent lifecycle
workflows concurrently in an attempt to make deployment faster.

### Workflow success criteria

The run is successful only when every step is green and the publication step reports:

- the Foundry agent name/version;
- a Microsoft 365 title ID;
- the Autopilot `appVersion`; and
- the resolved agent identity blueprint/client ID.

Record the run URL, title ID, blueprint/client ID, and app version for the administrator.

A warning that the repository MCP policy has no live allowed Autopilot identity is expected only
when the deployed simple agent does not use MCP. It must not be ignored after MCP tools are added.

## 12. Approve the blueprint in Microsoft 365

Workflow success means the request was submitted. It does not make the Autopilot available to
users.

The approver must be a Global Administrator or AI Administrator.

1. Sign in to the [Microsoft 365 admin center](https://admin.cloud.microsoft/?#/agents/all/requested).
2. Navigate to **Agents -> All agents -> Requests**.
3. Clear existing filters if the request is not visible.
4. Locate the Autopilot by display name or the title ID from the workflow output.
5. Confirm the state is **Pending activate**, **Pending review**, or **Pending update**.
6. Open the request and review its capabilities, data sources, tools, custom actions, security,
   requested permissions, developer metadata, and owner.
7. Select **Publish to store** or open the **Publish new agent** wizard.
8. Choose the users/groups who can discover the blueprint.
9. Under **Activate**, choose who can create instances: none, everyone, or specific users/groups.
   This is the hiring scope.
10. Optionally choose users/groups for preinstallation if that option applies.
11. Choose the applicable default, existing, or custom policy template.
12. Review every permission and grant admin consent only where appropriate.
13. Review the audience, activation scope, policy, and license availability.
14. Select **Publish**.
15. Verify the blueprint appears in the Agent 365 registry as **Available**.

See [Agent requests in the Microsoft 365 admin center](https://learn.microsoft.com/microsoft-365/admin/manage/agent-requests?view=o365-worldwide).

Admin consent controls what kinds of calls the Autopilot may make. It does not by itself grant
arbitrary user data, but unnecessary scopes still violate least privilege. If the simple agent
still requests Mail, Word, OneDrive/SharePoint, Teams tool, Excel, or Calendar access, reject or
pause the request and correct `autopilot.json` before approval.

## 13. Create an Autopilot instance

After the blueprint status is **Available**, a user in the hiring scope creates an instance.
Creating an instance consumes an Autopilot/Frontier license and creates an agent identity and agent
user account.

In Microsoft Teams:

```text
Apps -> Agents for your team -> <Autopilot> -> Create instance
```

In Microsoft 365 Copilot:

```text
Agents -> Agents for your team -> <Autopilot> -> Create instance
```

Provide the requested instance name, alias/domain, and manager, then create it. Instance creation
is asynchronous and can take several minutes.

If **Create instance** is missing:

- confirm the tenant is enrolled and terms were accepted;
- confirm the blueprint is **Available**;
- confirm the user is in the activation/hiring scope; and
- confirm a license seat is available.

## 14. Perform an end-to-end smoke test

After the instance starts a Teams chat, send a deterministic test:

```text
Reply with exactly: DEPLOYMENT_OK
```

Expected result:

```text
DEPLOYMENT_OK
```

This test validates more than the GitHub workflow. It confirms:

- Microsoft 365 catalog publication;
- administrator approval;
- instance creation and identity propagation;
- Activity Protocol delivery;
- hosted-agent startup;
- Foundry project authentication;
- model-deployment name correctness; and
- response delivery back to Teams.

If deployment succeeded but the first message fails, check the model alignment in section 4.3
before changing network policy.

Initial identity/catalog propagation can produce transient `500` or `502` responses. Retry after a
short wait, but investigate persistent failures through the runner, Foundry/App Insights telemetry,
APIM logs, and [docs/troubleshooting.md](docs/troubleshooting.md).

## 15. Public-fork runner security

A public fork can be used because the current privileged workflows are manually dispatched or
scheduled and exact-repository guards are present. It still requires careful operation.

The self-hosted runner:

- can reach private Foundry and APIM endpoints;
- uses a privileged Azure managed identity;
- executes workflow code from the repository; and
- is persistent rather than an isolated GitHub-hosted runner.

For a public fork:

1. Never add `pull_request` or `pull_request_target` triggers to jobs that use
   `[self-hosted, vnet, foundry-private]`.
2. Do not run untrusted fork/PR code on the private runner.
3. Keep exact `github.repository` guards in reusable and dispatchable privileged workflows.
4. Restrict write/collaborator access to trusted operators.
5. Protect the default branch and review workflow changes before merging.
6. Keep the runner PAT repository-scoped with only Administration read/write.
7. Rotate/revoke the PAT according to organizational policy.
8. Treat every committed workflow or script change as privileged code.
9. Do not commit Azure credentials, PATs, delegated tokens, `.azure/`, or generated environment
   files.

The absence of committed secrets does not eliminate self-hosted runner risk. The main risk is
executing changed repository code with private network reach and managed-identity permissions.

## 16. Updating the deployment

Use the correct lifecycle for the change:

| Change | Required operation |
|---|---|
| Bicep/infrastructure | Review with `azd provision --preview`, then run `azd provision` or `azd up`. |
| MCP or YARP application code | Run `azd deploy` or `azd up`. |
| Agent source or `agent.yaml` | Commit/push and rerun the agent lifecycle workflow. |
| `network.json`, `mcp.json`, or `mcp-policy.json` | Commit/push and rerun an agent lifecycle workflow so all governance is reconciled. |
| `autopilot.json` metadata/permissions | Increment `appVersion`, commit/push, rerun the Autopilot workflow, and have an administrator approve the pending update. |
| Admin audience/policy | Update through the Microsoft 365 admin center. |

The repository has one environment. Do not add environment-suffixed agent manifests, routes, or
repository variables.

## 17. Common recovery paths

### Workflow remains queued

- Confirm the Linux runner VM is running.
- Confirm the runner is online in GitHub.
- Confirm labels include `self-hosted`, `vnet`, and `foundry-private`.
- Confirm the workflow's exact repository guard targets the fork.
- Confirm the committed branch contains the customized guard.

### Runner registration failed

- Confirm `GITHUB_RUNNER_REPO_URL` targets the fork.
- Confirm the fine-grained PAT has repository Administration read/write.
- Confirm the PAT has not expired.
- Allow time for Key Vault RBAC propagation.
- Rerun `azd provision`.

### Linux runner bootstrap reports `pipefail\r`

The fork is missing the line-ending protections from section 3.1. Add both protections, commit,
push, and rerun `azd provision`.

### VM extension cannot be modified because the VM is stopped

Start the Linux runner VM, then rerun:

```powershell
azd provision
```

### Optional Windows VM causes disk-SKU or extension conflicts

The Windows VM is not required for automation. For a new deployment, keep it disabled:

```powershell
azd env set DEPLOY_WINDOWS_VM false
azd provision
```

For an adopted environment, disabling it removes it from future Bicep management but does not
automatically delete an existing VM. Review and remove the residual diagnostic resources
separately if appropriate.

### GitHub repository variables are missing

Authenticate `gh` as the fork administrator and rerun:

```powershell
azd hooks run postprovision
```

### App Service ZIP deployment returns `403 Ip Forbidden`

Rerun:

```powershell
azd deploy
```

The SCM hook learns the actual proxy IP seen by App Service. After any interrupted deployment,
also run:

```powershell
azd hooks run postdeploy
```

### Device-code sign-in is waiting

Open the live workflow log and expand **Sign in and acquire the delegated user token**. Enter the
displayed code at the Microsoft device-login page. Do not look for a GitHub text box.

### Publication says the version already exists

Increment `appVersion` in `autopilot.json`, commit/push, and rerun the workflow. Reusing an
existing version does not update Microsoft 365.

### Approval request is missing

- Clear Microsoft 365 admin center filters.
- Search by the workflow's title ID.
- Confirm the workflow publication step succeeded rather than no-op/failing.
- Confirm the approver is a Global Administrator or AI Administrator.
- Confirm Microsoft Agent 365 is enabled and its terms were accepted.

### Instance creation is missing or fails

- Confirm the blueprint is **Available**.
- Confirm the user is in the activation scope.
- Confirm the tenant has a free license seat.
- Allow time for catalog/identity propagation.

### Agent deploys but cannot answer

- Confirm `AZURE_AI_MODEL_DEPLOYMENT_NAME` matches a real model deployment.
- Confirm the hosted agent is running and ready.
- Confirm its managed identity has the required Foundry/model access.
- Confirm the Activity Protocol exposure choice is configured consistently.
- Check Foundry and Application Insights telemetry before weakening any firewall or private
  endpoint setting.

## 18. Teardown

From the same selected azd environment:

```powershell
azd down
```

The pre-down hook attempts to:

1. deregister the deterministic GitHub runner;
2. remove project capability hosts;
3. remove account capability hosts; and
4. allow azd to delete the remaining Azure resources.

Authenticate `gh` as the fork administrator before teardown. If deregistration fails, remove the
offline runner manually under **Settings -> Actions -> Runners**.

Deleting Azure resources does not automatically retire the approved blueprint or delete Autopilot
instances hired in Microsoft 365. The Microsoft 365 administrator must retire/remove those through
Agent 365 and reclaim the associated licenses.

## Final completion checklist

- [ ] The repository was forked and cloned from the fork.
- [ ] Every privileged workflow guard targets the fork exactly.
- [ ] The LF, Foundry local-auth, and APIM hardening fixes are present.
- [ ] Tenant-specific principals and metadata were replaced.
- [ ] The agent model name matches the deployed model.
- [ ] Unused Microsoft 365 permission scopes were removed.
- [ ] Azure, azd, and GitHub CLI identities were verified.
- [ ] One azd environment was created in a supported region.
- [ ] The repository-scoped runner PAT was supplied securely.
- [ ] `azd provision --preview` was reviewed.
- [ ] `azd up` completed, including MCP/YARP application deployment and SCM relock.
- [ ] The private Linux runner is online with the required labels.
- [ ] GitHub Actions repository variables were synchronized.
- [ ] Foundry, APIM, private endpoint, CMK, and deny-by-default security invariants were verified.
- [ ] The Autopilot lifecycle workflow completed successfully.
- [ ] The workflow's title ID, blueprint/client ID, app version, and run URL were recorded.
- [ ] A Global Administrator or AI Administrator approved and activated the blueprint.
- [ ] The blueprint appears as **Available** in Agent 365.
- [ ] A user in the hiring scope created an instance with an available license.
- [ ] The Teams/Copilot `DEPLOYMENT_OK` smoke test succeeded.
