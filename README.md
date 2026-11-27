# MidCoast Lab

A hybrid identity lab on Proxmox, built entirely from this repo: Active Directory domain
controllers and a management machine, from your own Windows templates, with your own
domain and Microsoft 365 tenant. Packer builds the templates, Terraform creates the VMs,
and PowerShell sets each one up and checks it. Nothing is repaired by hand: a machine that
is old, outdated or broken is replaced by a new one from the current template.

**Read this page first, before doing anything.** Everything you need to *do* is in the
**checklist at the end**; the sections before it explain what you're building and what
you'll need.

> **A lab, not production.** It builds Windows evaluation editions (Server 2022 180 days,
> Windows 11 90 days) that it replaces rather than renews, uses self-signed certificates,
> and keeps every secret in a KeePass vault on one management machine. Run it on a network
> of its own, never exposed to the internet. MIT licensed ([LICENSE](LICENSE)); security
> reports: [SECURITY.md](SECURITY.md).

## How the documents fit together

1. **This README**: what the lab is, its lifecycle, and what you need. Read it all.
2. **[docs/NEW-SITE.md](docs/NEW-SITE.md)**: the information to collect about your
   environment, and how it goes into your `site.yaml`.
3. **The checklist at the end of this README**: get the repo, fill in `site.yaml`, check
   it, and generate your **site kit**.
4. **`RUNBOOK.md`**, in your site kit: the build itself, from an empty Proxmox node to a
   working lab, and how to start over. It's [docs/runbook.md](docs/runbook.md) with your
   values filled in.
5. **Later**, as the lab ages: [docs/replace-mgmt.md](docs/replace-mgmt.md) and
   [docs/replace-dc.md](docs/replace-dc.md). Every script and its switches:
   [docs/scripts.md](docs/scripts.md).

Two files hold everything about a lab. `inventory/lab.yaml` is the **product**: roles,
sizes, names, OUs, groups. It's the same for everyone; you don't edit it.
`inventory/site.yaml` is **your site**: domain, subnet, Proxmox node, storage and the few
other values that differ per installation. You make it from `inventory/site.template.yaml`;
`inventory/site.example.yaml` shows a filled-in one.

## A lab's lifecycle

**1. Prepare (an hour or so, by hand).** Collect your environment's details, fill in
`site.yaml`, and generate the site kit (the checklist at the end).

**2. First build (about half a day, mostly unattended), following the runbook:**
- **Proxmox setup**: a script creates the lab's Proxmox account, pool and permissions, and
  **MGMT-00**, the starter management machine, with Windows installed unattended.
- **MGMT-00**: four scripts install its toolchain (Git, Terraform, Packer, KeePassXC and
  the rest), put the repo in place, create the **vault**, where every lab password and key
  lives, and later join it to the domain.
- **Templates**: Packer builds a Windows Server 2022 and a Windows 11 template.
- **Phase 1**: two domain controllers are cloned from the Server template and set up as a
  new forest:
  - the first DC creates the forest, DNS and the site, the tiered OUs (`Admin/Tier0|1|2`),
    groups, your administrators (`<user>` and `<user>-a`), the service accounts, Windows
    LAPS and the time source;
  - the second joins it as a replica;
  - each is gated on its own validation; then both DCs' DNS settings are finalised and
    everything is validated again.
- **Replace MGMT-00**: MGMT-00 joins the domain, then hands over to a pipeline-built MGMT.
  From then on, every machine in the lab is built from a template by the pipeline.

**3. Run.** Every machine checks itself when it's built and writes a validation report
(see the reference section). The evaluation editions keep the lab moving:
- **Rebuild the templates monthly**, or after important updates. Existing machines keep
  the version they were built from; the next replacement gets the new one.
- **Replace MGMT about every two months** (Windows 11's 90 days):
  [docs/replace-mgmt.md](docs/replace-mgmt.md).
- **Replace each DC before 180 days**, one at a time:
  [docs/replace-dc.md](docs/replace-dc.md).

**4. Update.** New releases (`LAB-<YYMMDD>-<NN>`) are listed under [Releases](https://github.com/MidCoast-Labs/midcoast-labs/releases/latest). Each entry in
[CHANGELOG.md](CHANGELOG.md) starts with what it needs from you: usually nothing beyond
taking the new files, sometimes rebuilding templates or replacing machines, and only for
a new major version a change to `site.yaml`. Take a release on the active MGMT by
replacing everything except `inventory/site.yaml`, `inventory/instances.yaml` and your
vault (or, in a clone, with `git fetch --tags` and `git merge` of the new release's tag); then run
`Test-LabInventory.ps1`, which says if anything new is needed, and regenerate the site kit
if you'll need the runbook again. `lab.yaml` shows the release you're on (`release`) and
its compatibility number (`version`). Don't change `lab.yaml` or anything else outside
your `site.yaml` and ledger for your own site: if something doesn't work for you, it's a
product change, so send it back to the repo's owner and every site gets it.

**5. Start over.** `setup/proxmox/proxmox-teardown.sh` removes a site from Proxmox
(only the lab's own VMs, pool, user and role; your ISOs stay) so it can be built again;
`orchestration/Reset-LabLedger.ps1` then resets the ledger and Terraform state in your
repo, which still describe the old lab. The commands, with your site's values, are at
the end of your `RUNBOOK.md` ("Starting over").

Not built yet: Phase 2 (a Windows 11 end-user workstation) and Phase 3 (Entra Connect).

## Requirements

### Proxmox host hardware

Sizes come from `inventory/lab.yaml` (DC 4 GB / 50 GB, ADES 6 GB / 80 GB, MGMT 8 GB /
100 GB, W11 4 GB / 80 GB). **Steady** is the normal running lab; **peak** is during a
replacement, when the new DC or MGMT runs beside the old one (a template build needs
less: +4 GB RAM for the staging VM).

| | Phase 1 (2 DCs + MGMT): steady / peak | Full lab (+ ADES, W11): steady / peak |
|---|---|---|
| RAM for lab VMs (maximum) | 16 GB / 24 GB | 26 GB / 34 GB |
| RAM floor with ballooning (steady) | 8 GB | 14 GB |
| vCPUs (can be overcommitted) | 12 / 16 | 18 / 22 |
| Disk actually used (linked clones, thin storage; rough) | ~100–150 GB | ~150–250 GB |
| ISO storage | ~12 GB | ~12 GB |

**Memory.** Every VM can use up to its `memory_mb`. With ballooning, Proxmox can take
memory back from idle VMs down to `memory_min_mb` when the host runs short, and KSM
(on by default) merges identical memory pages across the Windows VMs. Both are a
cushion, not capacity: size the host for the maximum.

**Disk.** VMs are linked clones of their template, so each one stores only its changes
from it. The disk figure is a rough estimate (a template version is about 15–25 GB; a new
clone adds a few GB and grows with updates); measure your own with `lvs` or
`zfs list`. Provisioned sizes are much larger (a VM's disk can grow to its `disk_gb`),
and while VMs are still on an older template version, both versions are kept. With
`clone_mode: full` (storage that can't do linked clones), each VM is a full copy:
plan for about twice the figures above.

Recommended host:

- **RAM**: 32 GB for Phase 1, 48 GB for the full lab. The VM figures above don't include
  Proxmox itself (2–4 GB) or the ZFS ARC on ZFS storage.
- **CPU**: 4 physical cores minimum, 8 or more recommended. It needs hardware
  virtualization (VT-x / AMD-V) and the `x86-64-v2-AES` CPU type (AES-NI); any Intel or
  AMD server or desktop CPU from about 2011 on has both.
- **Disk**: SSD or NVMe. **LVM-thin, ZFS or Ceph RBD** for the VM storage (linked
  clones need one of them; ZFS also compresses). 250 GB for Phase 1, 500 GB for the full
  lab leaves room to grow; thin storage must never run out, so watch its usage. On
  node-local storage, linked clones can't be migrated to another node. Backups
  and snapshots need space on top (Proxmox Backup Server deduplicates them well).
- **Network**: one Linux bridge for the lab (no VLAN or SDN setup required).

The figures are per lab, on one node. Proxmox clustering isn't required.

### Software, services and accounts

| Need | Why / notes |
|---|---|
| **Proxmox VE 9.x**, root shell and the web UI | `proxmox-setup.sh` runs as root once; MGMT-00 is installed from the VM console |
| **A router or firewall VM on the lab bridge** | Gateway for the lab subnet; DHCP for the rest of the subnet with `.10`–`.49` excluded; DNS for the DCs to forward to (or set `dns_forwarders`) |
| **Lab subnet → Proxmox API (TCP 8006)** | MGMT runs Terraform, Packer and the pre-flight against `proxmox.endpoint`, so the lab subnet must reach it **directly** through its router, not only over Tailscale or a VPN: a pipeline-built MGMT has to reach it before it joins any tailnet. Test from MGMT with `Test-NetConnection <endpoint host> -Port 8006` |
| **Internet access from the lab subnet** | Windows Update during template builds; MGMT toolchain from each vendor (GitHub, HashiCorp, Microsoft); PowerShell Gallery; NTP pool. The lab can't be built offline |
| **ISOs** | Windows Server 2022 evaluation, Windows 11 Enterprise evaluation, `virtio-win.iso` |
| **A domain you own** | The AD forest is a subdomain of it (`ad.<domain>`); it's also the UPN suffix |
| **Microsoft 365 / Entra tenant** with that domain verified | UPN suffix now; Entra Connect in Phase 3 (E5 developer licences are fine) |
| **Git** (on MGMT) | The repo on MGMT must be a git repository: the pipeline commits the ledger (`instances.yaml`) after every run, and every MGMT replacement hands over the full history. MGMT's toolchain installs Git, and `Initialize-LabRepo.ps1` (runbook step 5) sets the repo up, with your git name and e-mail taken from `site.yaml`'s administrator. Not needed on your workstation, and no remote is needed |
| **A private git remote** (recommended) | GitHub, GitLab, or Gitea/Forgejo on another machine. Without one, the only copies of the ledger and its history live on MGMT. The repo holds no secrets, but keep it private: it maps your lab |
| **A workstation with PowerShell 7 and `powershell-yaml`** | For checking your `site.yaml` and generating the site kit before MGMT-00 exists (Windows, macOS or Linux) |
| **KeePassXC** | Installed on MGMT by the toolchain. Back up the `.kdbx` and its master password **outside the lab**: without them the lab's secrets are gone |
| Tailscale (optional, recommended) | Remote access to the lab. Either a subnet route for the lab subnet, or **MGMT on your tailnet** (since 1.8 the DCs don't join: reach them by Remote Desktop from MGMT): set `tailscale.enabled: true` in `site.yaml` and give `Initialize-LabVault` a **reusable, tagged, non-ephemeral** auth key (MGMT-00 can also join during its unattended install with a separate **one-time** key you type into `proxmox-setup.sh`, so it's reachable before anything else exists) (leave *Ephemeral* off: an ephemeral device drops off the tailnet when it's offline for a while and can't rejoin, since the key is deleted from each machine after setup). It lives in the vault, never in the repo. Each MGMT then joins during its setup with `--accept-routes=false --accept-dns=false`, its Tailscale adapter kept out of DNS, and Remote Desktop allowed on that adapter; use Tailscale's access rules for who may connect. The key is also kept on MGMT as Tailscale's `AuthKey` policy (readable by SYSTEM and Administrators only), and a watchdog task (`MidCoastLab-Tailscale`, every 15 minutes) logs it back in if a restart or update logged it out; scope the tag's access rules to what the lab needs. Retiring a machine logs it out of the tailnet (a DC built before 1.8 too, before it's demoted). Auth keys expire: replace it in the vault (`Set-Secret`) when it does. Not a substitute for the direct route above |

### Licensing and time

- **Evaluation editions only.** Windows Server 2022 evaluation runs 180 days and Windows
  11 Enterprise evaluation 90 days. The lab never extends them: it replaces machines
  before they expire. `EVAL-001` in each validation report shows the days left; rotate
  each DC and MGMT before it runs out.
- **First build**: about half a day of mostly unattended time (MGMT-00's unattended install
  20–40 min, Server 2022 and Windows 11 templates ~1 h each, Phase 1 ~1 h, replacing
  MGMT-00 ~1 h).

## Reference: templates

`./orchestration/Build-LabTemplate.ps1 -Template <key>` (`windows_server_2022` or
`windows_11`: the keys under `templates:` in `lab.yaml`, so a template added later is
built the same way) builds a new **version** (`WIN2022-TEMPLATE-<YYMMDD>-<NN>`) at the
next free VMID of the template's range and makes it current. Existing VMs stay linked clones of the version they were built from; the next
VM of that role (a rotation) gets the new one. A superseded version is deleted
automatically once no VM uses it. Rebuild monthly, or after critical updates, and commit
`inventory/instances.yaml` afterwards (the ledger lists the versions).

## Reference: validation IDs

**DC:** `NET-001/002`, `AD-001/002/003`, `DNS-001…004`, `SYSVOL-001/002`, `FSMO-001`,
`REPL-001/002`, `TIME-001`, `LAPS-001/002`, `RDP-001` (Remote Desktop), `DNS-005` (no Tailscale address in AD's DNS), `TS-001` (tailnet; passes as "not used by this role" since 1.8), `MEM-001` (balloon service), `EVAL-001` (evaluation days left).
**MGMT:** `NET-001/002`, `MGMT-001…007`, `TS-001`, `MEM-001`, `EVAL-001`.
Severity and recovery for each: `platform/validation/catalog.psd1`. Reports:
`C:\ProgramData\MidCoastLab\Logs\Validation\latest.json` on each machine.

## Reference: the vault

Every lab secret lives in the KeePass vault on the active MGMT (`C:\MidCoastLab\MidCoastLab.kdbx`,
registered as the SecretManagement vault `MidCoastLab` for each admin account). Pipeline
scripts ask for its master password when it's locked (a new window, or after a while); to
unlock it ahead of time: `Unlock-SecretVault -Name MidCoastLab`. One entry by hand:
`Get-Secret -Vault MidCoastLab -Name <entry> -AsPlainText`.

## Reference: what's where

```
inventory/
  lab.yaml            the product: roles, sizes, slots, OUs, groups (same at every site)
  site.yaml           this site: domains, subnet, Proxmox node/storage/bridge, VMID base, ISOs
  site.template.yaml  blank site.yaml for a new installation
  instances.yaml      ledger of instances and template versions (pipeline-written; commit it)
  resolved/           lab.yaml + site.yaml merged (generated, gitignored; read by Terraform/Packer)
packer/windows/       WIN2022-TEMPLATE and WIN11-TEMPLATE (-var template_key=…)
terraform/            VMs from the resolved inventory + instances.yaml
platform/             everything pushed into guests
  bootstrap.ps1       state machine: Common → Role:<stage>… → Validate → Complete
  validate.ps1        on-demand validation (runs as SYSTEM)
  modules/Lab.*       runtime modules (Lab.Inventory also resolves lab.yaml + site.yaml)
  roles/dc.ps1        DC role (forest | replica)
  roles/mgmt.ps1      MGMT role (toolchain, Remote Desktop, domain join)
  roles/mgmt-tools.ps1  the MGMT toolchain installer (also used for the hand-build)
  validation/         dc- and mgmt-validation.ps1, catalog.psd1 (ID → severity → recovery)
orchestration/        runs on the active MGMT (PowerShell 7)
  Test-LabInventory.ps1   offline: lab.yaml + site.yaml + ledger
  Test-LabSite.ps1        live: Proxmox, storage, bridge, ISOs, VMID collisions, lab addresses
  Build-LabTemplate.ps1
  Invoke-LabPhase.ps1
  Invoke-LabMgmtRotation.ps1
  Invoke-LabDcRotation.ps1
  Reset-LabLedger.ps1     after a teardown: empties the ledger and removes the Terraform state
  Lab.Orchestration.psm1
setup/
  New-LabSiteKit.ps1                   writes out/site-kit/<site>/ (RUNBOOK.md, proxmox-setup.sh)
  proxmox/proxmox-setup.sh             template; run the site kit's copy, not this one
  proxmox/proxmox-teardown.sh          removes a site from Proxmox (keeps ISOs); run as-is
  mgmt/Install-MgmtTools.ps1           MGMT-00 step 5: toolchain (wraps platform/roles/mgmt-tools.ps1)
  mgmt/Initialize-LabRepo.ps1          MGMT-00 step 5: repo at C:\MidCoastLab\repo, git init, git identity
  mgmt/Initialize-LabVault.ps1         step 6, and once per account/MGMT: create/register the vault, generate secrets
  mgmt/Join-LabTailnet.ps1             step 6: MGMT-00 joins the tailnet (site.yaml tailscale.enabled)
  mgmt/Join-LabDomain.ps1              step 8: MGMT-00 joins the domain, post-join rules, restart
tools/
  Export-LabRelease.ps1                exports a release (no site, no ledger) for the public repo
  New-LabScriptReference.ps1           regenerates docs/scripts.md from the scripts' own help
CHANGELOG.md          releases (LAB-<YYMMDD>-<NN>, tags match) and the compatibility version
docs/
  NEW-SITE.md         what to collect, and how to fill in site.yaml
  runbook.md          first-build runbook (template; the site kit fills it in as RUNBOOK.md)
  replace-mgmt.md     replacing MGMT (about every two months)
  replace-dc.md       replacing a DC (before its 180 days run out)
  scripts.md          every script, its parameters and where it runs (generated)
  architecture.md, decisions.md   the design, and why
```

## Checklist: from nothing to your runbook

Work through these in order, on your **workstation** (Windows, macOS or Linux, with
PowerShell 7). At the end you have your site kit, and the runbook takes it from there.

**1. Check the requirements** above: Proxmox, storage, a router on the lab bridge, a /24
of its own, a domain in your Microsoft 365 tenant, the three ISOs.

**2. Get the repo.** For a tested version, use the **latest release**: it's at the top of
[Releases](https://github.com/MidCoast-Labs/midcoast-labs/releases/latest), and each release is a tag (`LAB-<YYMMDD>-<NN>`). `master` can be ahead
of it. Either way:
- **Download it**: the release's **Source code (zip)**. (**Code → Download ZIP** gets
  `master` instead.)
- **Clone it**, if you have Git, and make a branch of your own at the release, so your
  site's commits (the ledger) have a branch to go on:
  ```
  git clone https://github.com/MidCoast-Labs/midcoast-labs.git
  cd midcoast-labs
  git switch -c my-site LAB-<YYMMDD>-<NN>
  ```
  Take a later release with `git fetch --tags` and `git merge LAB-<YYMMDD>-<NN>`.

Your copy will soon hold your own `site.yaml`, which describes your lab: if you keep it in
a git remote, keep that one **private**.

**3. Windows only: unblock the files.** Windows marks downloaded files "from the
internet", and PowerShell then refuses to run them ("… is not digitally signed").
- **Downloaded a zip:** unblock the zip **before** extracting it, so nothing inside is marked:
  ```powershell
  Unblock-File .\midcoast-labs-*.zip
  Expand-Archive .\midcoast-labs-*.zip -DestinationPath C:\
  ```
- **Already extracted it** (or cloned it): unblock the folder, from inside it:
  ```powershell
  Get-ChildItem -Recurse | Unblock-File
  ```
- If `Get-ExecutionPolicy` says `Restricted` (the Windows client default), also run, once:
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

Only unblock a copy you trust. You'll do the same again on MGMT-00 (the runbook says when).

**4. Install the YAML module** for PowerShell 7, once per workstation:
```powershell
Install-Module powershell-yaml -Scope CurrentUser
```

**5. Make your `site.yaml`**, from the repo's folder:
```powershell
Copy-Item inventory/site.template.yaml inventory/site.yaml
```
Then fill it in, using [docs/NEW-SITE.md](docs/NEW-SITE.md): it lists what to collect
and what goes where.

**6. Check it:**
```powershell
./orchestration/Test-LabInventory.ps1
```
It refuses anything left as a placeholder, `.local` names, a subnet that isn't a /24, a
gateway inside the lab's range, and similar mistakes, and says what to fix. Fix and re-run
until it reports no errors (warnings are worth reading, but don't stop you).

**7. Generate your site kit:**
```powershell
./setup/New-LabSiteKit.ps1
```
It writes `out/site-kit/<your site>/`:
- **`RUNBOOK.md`**: the build, step by step, with every command and value filled in for
  your site;
- **`proxmox-setup.sh`**: the Proxmox setup script, with your site's values built in.

Re-run it whenever you change `site.yaml`.

**8. Open `out/site-kit/<your site>/RUNBOOK.md` and follow it from step 1, in order.**
Its first steps prepare the router and Proxmox and create MGMT-00; from then on you work
on MGMT-00, and the runbook ends with a working lab.
