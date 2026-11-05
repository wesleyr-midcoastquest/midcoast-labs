# Setting up a new MidCoast Lab site

This is for an engineer who has been handed this repo and wants the same lab on
their own Proxmox, with their own domain name and Microsoft 365 tenant. It's the
second of three documents: README **Requirements** first, then this, then the
`RUNBOOK.md` that step 3 generates for you, which is the build itself.

Everything about **what** the lab is (roles, sizes, slots, host numbers, OU
tree, groups, tiering, naming, validation) lives in `inventory/lab.yaml` and is
the same at every site. Everything about **where** it runs lives in
`inventory/site.yaml`. You only edit `site.yaml`.

| Same everywhere (`lab.yaml`) | Yours (`site.yaml`) |
|---|---|
| Roles, CPU/RAM/disk, templates | Site name, time zone |
| Hostnames `<Role>-<YYMMDD>-<NN>` | AD domain and NetBIOS name |
| Host numbers: DCs .10–.12, ADES .20, MGMT .30/.31, W11 .40; lab range .10–.49 | Lab subnet (a /24), gateway, DNS forwarders, NTP |
| VMID offsets: servers +0–99, template versions +100–147, staging +148–149 | `vmid_base` (where your 150-ID block starts) |
| OU tree, tiering, groups, service accounts, LAPS | Entra tenant domain (UPN suffix), your administrators |
| Pool `MidCoast-Lab`, user `terraform-prov@pve`, vault `MidCoastLab` | Proxmox node, endpoint, bridge, storages, ISO names |

## What you need

Hardware sizing (RAM, CPU, disk) and the full list of software, accounts and
licensing are in the README under **Requirements**. In short:

- **Proxmox VE 9.x**, root shell on the node the lab will run on. One lab per
  Proxmox cluster: the pool, role and `terraform-prov@pve` user are cluster-wide
  names.
- **Storage** that holds disk images, ideally **LVM-thin, ZFS or Ceph RBD** (e.g.
  `local-lvm`, `local-zfs`): the lab's VMs are linked clones of their template, which
  those support. Use the same storage for templates and VMs. On any other storage (a
  directory, NFS), set `proxmox.clone_mode: full`; it works the same but uses about
  twice the disk. Decide before the first build: a change later only applies to VMs
  built after it. On node-local storage, linked clones can't be migrated to another
  node, so the lab stays on its node. Plus one storage that holds ISO images (e.g. `local`).
- **A Linux bridge for the lab** (e.g. `vmbr2`) with a **router on it** (usually at `.1`;
  anywhere outside `.10`–`.49`) that serves DHCP *outside* `.10`–`.49`. New VMs take a DHCP address on first boot;
  the lab's static addresses are all in `.10`–`.49`.
- **A /24 nobody else uses**: not your home LAN, and not the subnet of any other
  MidCoast lab you might reach over a shared tailnet or VPN.
- **A domain you own**, verified as a custom domain in your **Microsoft 365 / Entra
  tenant** (E5 developer licences are fine). The AD forest is a subdomain of it,
  e.g. tenant domain `example.com`, AD domain `ad.example.com`. Phase 3 (Entra
  Connect) isn't built yet; until then the tenant domain is used as every user's
  UPN suffix, so pick it now: changing it later means re-suffixing accounts.
- **ISOs**: Windows Server 2022 evaluation, Windows 11 Enterprise evaluation,
  `virtio-win.iso`.
- **A machine with PowerShell 7** and the `powershell-yaml` module for the first two
  steps (your workstation; MGMT-00 doesn't exist yet):
  `Install-Module powershell-yaml -Scope CurrentUser`.

## 1. Start your own copy

Start from a clean copy, not the original site's history or state.

**Unblock it first** if it came as a zip or a download, or no script will run ("… is not
digitally signed"): `Unblock-File <the zip>` before extracting, or
`Get-ChildItem -Recurse | Unblock-File` inside the extracted folder (README, top).

First make sure Git is installed and knows who you are (once per machine). If
`git --version` says "not recognized", install it, then **open a new PowerShell
window** so it's on the PATH:

```powershell
git --version                                    # install if this fails:
winget install --id Git.Git -e --source winget   # or download from git-scm.com
```

No `winget` (Windows Server, older Windows 10)? In an **elevated** PowerShell:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$rel   = Invoke-RestMethod https://api.github.com/repos/git-for-windows/git/releases/latest
$asset = $rel.assets | Where-Object name -like 'Git-*-64-bit.exe' | Select-Object -First 1
$exe   = Join-Path $env:TEMP $asset.name
Invoke-WebRequest $asset.browser_download_url -OutFile $exe -UseBasicParsing
Start-Process $exe -ArgumentList '/VERYSILENT', '/NORESTART' -Wait
```

Then, in a new window:

```powershell
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

**Cloned it?** (recommended: you can pull later releases.) Keep the public repo as
`upstream` and give your copy a **private** home of its own, because your `site.yaml` and
ledger will describe your lab:

```powershell
git remote rename origin upstream
Copy-Item inventory/site.template.yaml inventory/site.yaml
git add inventory/site.yaml inventory/instances.yaml; git commit -m "MidCoast Lab: new site"
# later, after creating an empty private repo:  git remote add origin <its URL>; git push -u origin master
```

Taking a new release later is `git pull upstream master`: releases never contain a
`site.yaml`, and their `instances.yaml` is the empty one you already have, so your files
stay as they are.

**Downloaded a zip instead?** From the folder you unzipped (each command on its own line;
if you paste several at once, check they didn't run together onto one line):

```powershell
Get-ChildItem -Recurse | Unblock-File    # files from a zip are marked "from the internet"
Copy-Item inventory/site.template.yaml inventory/site.yaml -Force
Set-Content inventory/instances.yaml "instances: []`ntemplates: []"
Remove-Item -Recurse -Force .git, inventory/resolved, out, terraform/.terraform -ErrorAction SilentlyContinue
git init
git add .
git commit -m "MidCoast Lab: new site"
```

These work in Windows PowerShell 5.1 and PowerShell 7.

`instances.yaml` is the ledger of what exists *at a site*; you must not inherit
someone else's (validation refuses a ledger whose addresses or VMIDs don't fit
your site). There is no `.kdbx` or state file in the repo; each site makes its
own.

## 2. Fill in `site.yaml`

Replace every `<placeholder>` in `inventory/site.yaml`, **angle brackets included**:
`domain: <ad.your-domain>` becomes `domain: ad.example.com`. The comments say what each
one is. The ones to think about:

- **`identity.active_directory.domain`**: permanent for the life of the forest.
  A subdomain of your tenant domain (`ad.example.com`), never `.local`, never a
  single label.
- **`netbios`**: 15 characters or fewer, no dots.
- **`administrators`**: at least one at tier 0. Each gets `<username>` (standard) and
  `<username>-a` (admin, in `Admin/Tier<n>/Accounts`).
- **`network.subnet`**: a unique /24 (see above). Lab hosts land at fixed host numbers, so
  with `10.88.20.0/24` the first DC is `10.88.20.10`, MGMT-00 is `10.88.20.30`.
- **`proxmox.vmid_base`**: the lab uses `vmid_base` … `vmid_base + 149`. Pick a block
  with nothing in it (`pvesh get /cluster/resources --type vm`); e.g. `3000` means
  servers 3000–3099, templates 3100–3149, MGMT-00 is 3020.
- **`site.time_zone`**: a Windows ID such as `Eastern Standard Time`, not `America/New_York`.
- **`isos`**: `<iso storage>:iso/<exact file name>`, as Proxmox shows them.
- **`tailscale.enabled`** (optional): every lab machine joins your tailnet. The auth key
  goes in the vault (runbook step 6), never in `site.yaml`. Make it **reusable**, **tagged** (e.g. `tag:midcoast-lab`) and **not ephemeral** (leave *Ephemeral* off): an ephemeral device is removed from the tailnet once it's offline for a while and can't rejoin by itself; lab machines restart, and the key is deleted from each machine after setup.

Then check it:

```powershell
./orchestration/Test-LabInventory.ps1
```

It refuses placeholders, `.local` names, anything but a /24 network address, a
gateway inside the lab range or outside the subnet, a `vmid_base` under 100, ISOs not
on the ISO storage, and product settings put in `site.yaml`. It warns about common
home-router subnets. Fix and re-run until it has no errors, then commit it:

```powershell
git add inventory/site.yaml; git commit -m "Site settings"
```

`inventory/site.example.yaml` is a filled-in example (`example.com`, `pve01`) to compare
with; your `site.yaml` started from the blank template, so none of its sample values carry
over.

## 3. Generate your site kit

```powershell
./setup/New-LabSiteKit.ps1
```

It writes `out/site-kit/<site>/`:

- **`RUNBOOK.md`**: the first-build runbook ([mgmt-00.md](mgmt-00.md)) with every
  command and value filled in for your site.
- **`proxmox-setup.sh`**: the Proxmox setup script with your site's values baked in.

Re-run it whenever you change `site.yaml`. `out/` isn't committed.

## 4. Follow `RUNBOOK.md`

From step 1. In short:

1. Router: the gateway address, DHCP excludes `.10`–`.49`.
2. Upload the ISOs.
3. On the node, as root: `bash proxmox-setup.sh check`, then `bash proxmox-setup.sh`.
   It also installs Windows 11 on MGMT-00 unattended and waits for it.
   The check fails (and changes nothing) if you're on the wrong node, a storage or
   the bridge is wrong, an ISO MGMT-00 needs is missing, or **any lab VMID is
   already taken** by something that isn't this lab. Then it creates the pool,
   role, user, API tokens (copy the two secrets) and the MGMT-00 VM.
4. Sign in to MGMT-00, Windows updates, the toolchain and the vault.
5. `Test-LabInventory.ps1`, then `Test-LabSite.ps1`: the live check from MGMT with
   the provisioning token (Proxmox, storages, bridge, ISOs, pool, VMIDs, and **nothing
   outside the lab answering on a lab address**). Then both templates and Phase 1.
6. Join MGMT-00 to the domain.
7. Replace MGMT-00 with a pipeline-built MGMT (the first MGMT rotation).

From there, the README applies unchanged: Phase 1 output, replacing MGMT, validation
IDs. Commit `inventory/instances.yaml` after every run that changes it.

## Keeping in step with the original

To keep "everything else consistent":

- **Don't edit `lab.yaml`**, or anything outside `inventory/site.yaml` and
  `inventory/instances.yaml`, for your own site. If something there doesn't work for
  you, it's a product change: send it back to the repo's owner so every site gets it.
- **Taking product updates**: replace everything except `inventory/site.yaml`,
  `inventory/instances.yaml` and your `.kdbx`. Then run `Test-LabInventory.ps1`: if a
  new version needs a new site value, it says which, and `site.template.yaml` has the
  key with a comment. Regenerate the site kit if you'll need the runbook again.
- `lab.yaml`'s `release` says which release you're on, and `version` its compatibility
  number. Each release in `CHANGELOG.md` starts with what it needs from you: nothing,
  rebuilding templates, replacing machines, or (a new **major** version) a `site.yaml` change.

## If something's already there

- **VMID collision** (from `proxmox-setup.sh check` or `Test-LabSite.ps1`): pick
  another `vmid_base`, re-run `New-LabSiteKit.ps1`, and run the check again. Don't
  move the other VM to make room.
- **Address in use** (`Test-LabSite.ps1`): a device outside the lab answers on a lab
  address. Move it out of `.10`–`.49`, or fix the router's DHCP pool.
- **Existing `MidCoast-Lab` pool or `terraform-prov@pve`** on your cluster: from an
  earlier attempt at this lab, the setup script updates them in place. From something
  else, stop: one lab per cluster.
