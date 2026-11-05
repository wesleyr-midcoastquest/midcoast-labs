# MidCoast Lab

Hybrid identity lab on Proxmox, rebuilt from source: inventory-driven,
automation first, validation first, rebuild over repair. The design is in
[docs/architecture.md](docs/architecture.md); every change from it, and why,
is in [docs/decisions.md](docs/decisions.md).

The repo is portable. `inventory/lab.yaml` is the product and is the same for
everyone; `inventory/site.yaml` holds the few values that differ per installation
(AD domain, tenant domain, subnet, Proxmox node, storage, bridge, VMID base, ISO
names). You make your own `site.yaml` from `inventory/site.template.yaml`;
`inventory/site.example.yaml` shows a filled-in one.

> **A lab, not production.** It builds Windows evaluation editions (Server 2022 180 days,
> Windows 11 90 days) that it replaces rather than renews, uses self-signed certificates,
> and keeps every secret in a KeePass vault on one management machine. Run it on a network
> of its own, never exposed to the internet. MIT licensed ([LICENSE](LICENSE)); security
> reports: [SECURITY.md](SECURITY.md).

**Getting it.** Clone it (recommended, so you can pull updates):
`git clone https://github.com/wesleyr-midcoastquest/midcoast-labs.git`, or download a
release zip from GitHub. Then follow the table below from step 1. Your copy will hold your
own `site.yaml` and ledger, which describe your lab: keep it in a **private** repo.

**Which document, in what order (a new lab):**

| # | Document | What you do there |
|---|---|---|
| 1 | README, **Requirements** (below) | Check hardware, storage, Git, domain, tenant, ISOs |
| 2 | [docs/NEW-SITE.md](docs/NEW-SITE.md) | Make your copy, fill in `site.yaml`, validate it, generate the site kit. Ends by sending you to the runbook |
| 3 | `out/site-kit/<site>/RUNBOOK.md` | The build itself, steps 1–9: router, ISOs, `proxmox-setup.sh` (MGMT-00 installs unattended), toolchain, vault, both templates, Phase 1, domain join, then replacing MGMT-00 with a pipeline-built MGMT. Generated from [docs/mgmt-00.md](docs/mgmt-00.md) with your values filled in; follow it from step 1, in order |
| 4 | README, from **What Phase 1 does** on | Running the lab: templates, replacing MGMT, validation IDs |

**First, if you got the repo as a zip** (or downloaded it), unblock it. Windows marks
downloaded files "from the internet", and PowerShell then refuses to run the scripts
("… is not digitally signed"). Easiest is to unblock the zip *before* extracting, so
nothing inside is marked:

```powershell
Unblock-File .\midcoast-lab-v1.4.zip
Expand-Archive .\midcoast-lab-v1.4.zip -DestinationPath C:\
```

Already extracted? Unblock the folder instead, from inside it:
`Get-ChildItem -Recurse | Unblock-File`. Do the same for every copy you run scripts from
(your workstation, and MGMT-00 in runbook step 5). Only unblock a copy you trust. If
`Get-ExecutionPolicy` says `Restricted` (Windows client default), also run, once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

[docs/decisions.md](docs/decisions.md) and [docs/architecture.md](docs/architecture.md)
explain why; you don't need them to build. The repo's own author skips NEW-SITE
step 1 (keep the history; use your existing `site.yaml`) and starts at step 2, but still
unblocks a fresh zip (above).

```
Git → Inventory validation → Packer → Terraform → Cloudbase-Init → Bootstrap → Role → Validation
```

## Status

| Piece | State |
|---|---|
| Inventory (lab.yaml product + site.yaml site) + validation; releases `LAB-<YYMMDD>-<NN>`, compatibility 1.4 | ✅ built |
| Site kit (filled-in runbook + Proxmox setup script) and live site pre-flight | ✅ built |
| WIN2022-TEMPLATE and WIN11-TEMPLATE (one Packer definition, versioned: new VMs clone the current version) | ✅ built |
| Linked clones, memory ballooning, right-sized VMs (v1.3) | ✅ built |
| Terraform (bpg/proxmox, VMs from inventory + ledger) | ✅ built |
| Runtime modules Lab.Logging/Metadata/Inventory/System/Validation/AD | ✅ built |
| Lab.Entra | connectivity check only |
| Phase 1: two DCs, forest, OUs, groups, accounts, delegation, LAPS, DNS, time | ✅ built |
| **MGMT rotation** (replace the pipeline host itself: Prepare / Complete / Abort) | ✅ built |
| Terraform guard (refuses any delete a run didn't name, and damage to an active instance) | ✅ built |
| **DC rotation** (replace a DC from the template: Add / Retire / Abort) | ✅ built (v1.4; first real rotation Nov 2026) |
| Phase 2 (W11 end-user workstation) | later |
| Phase 3 (ADES: Entra Connect) | later |

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
| **Git** | Required. The repo must be a git repository: the pipeline commits the ledger (`instances.yaml`) after every run, and every MGMT replacement hands over the full history. MGMT's toolchain installs Git; you also need it wherever you prepare the site |
| **A private git remote** (recommended) | GitHub, GitLab, or Gitea/Forgejo on another machine. Without one, the only copies of the ledger and its history live on MGMT. The repo holds no secrets, but keep it private: it maps your lab |
| **A workstation with PowerShell 7, `powershell-yaml` and Git** | For `Test-LabInventory.ps1` and `New-LabSiteKit.ps1` before MGMT-00 exists (Windows, macOS or Linux) |
| **KeePassXC** | Installed on MGMT by the toolchain. Back up the `.kdbx` and its master password **outside the lab**: without them the lab's secrets are gone |
| Tailscale (optional, recommended) | Remote access to the lab. Either a subnet route for the lab subnet, or **every lab machine on your tailnet**: set `tailscale.enabled: true` in `site.yaml` and give `Initialize-LabVault` a **reusable, tagged, non-ephemeral** auth key (leave *Ephemeral* off: an ephemeral device drops off the tailnet when it's offline for a while and can't rejoin, since the key is deleted from each machine after setup). It lives in the vault, never in the repo. Each machine then joins during its setup with `--accept-routes=false --accept-dns=false`, its Tailscale adapter kept out of DNS (DCs keep AD and DNS on their lab address), and Remote Desktop allowed on that adapter; use Tailscale's access rules for who may connect. The key is also kept on each machine as Tailscale's `AuthKey` policy (readable by SYSTEM and Administrators only), and a watchdog task (`MidCoastLab-Tailscale`, every 15 minutes) logs it back in if a restart or update logged it out; scope the tag's access rules to what the lab needs. Retiring a machine logs it out of the tailnet. Auth keys expire: replace it in the vault (`Set-Secret`) when it does. Not a substitute for the direct route above |

### Licensing and time

- **Evaluation editions only.** Windows Server 2022 evaluation runs 180 days and Windows
  11 Enterprise evaluation 90 days. The lab never extends them: it replaces machines
  before they expire. `EVAL-001` in each validation report shows the days left; rotate
  each DC and MGMT before it runs out.
- **First build**: about half a day of mostly unattended time (MGMT-00's unattended install
  20–40 min, Server 2022 and Windows 11 templates ~1 h each, Phase 1 ~1 h, replacing
  MGMT-00 ~1 h).

## Layout

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
  Lab.Orchestration.psm1
setup/
  New-LabSiteKit.ps1                   writes out/site-kit/<site>/ (RUNBOOK.md, proxmox-setup.sh)
  proxmox/proxmox-setup.sh             template; run the site kit's copy, not this one
  mgmt/Join-LabTailnet.ps1             MGMT-00 joins the tailnet (site.yaml tailscale.enabled)
  mgmt/Install-MgmtTools.ps1           MGMT toolchain for the hand-build (wraps platform/roles/mgmt-tools.ps1)
  mgmt/Initialize-LabVault.ps1         KeePass vault + generated secrets
tools/
  Export-LabRelease.ps1                exports a release (no site, no ledger) for the public repo
CHANGELOG.md          releases (LAB-<YYMMDD>-<NN>, tags match) and the compatibility version
docs/
  NEW-SITE.md         handing the repo to another engineer / a new installation
  mgmt-00.md          first-build runbook (template; the site kit fills it in)
```

## First build, in order

1. **Fill in `inventory/site.yaml`** (a new site copies `site.template.yaml`; see
   [docs/NEW-SITE.md](docs/NEW-SITE.md)), then on any machine with PowerShell 7 and
   `powershell-yaml`:
   ```powershell
   ./orchestration/Test-LabInventory.ps1   # refuses placeholders, bad subnets, VMID/address mistakes
   ./setup/New-LabSiteKit.ps1              # writes out/site-kit/<site>/
   ```
2. **Follow `out/site-kit/<site>/RUNBOOK.md`.** It is [docs/mgmt-00.md](docs/mgmt-00.md)
   with your site's values filled in, and covers, in order:
   - the router on the lab bridge (the site's gateway), **DHCP excludes the lab range
     `.10`–`.49`** (`network.static_range`), DHCP on for the rest (new VMs use it for
     their first boot), and an optional Tailscale subnet route;
   - uploading the three ISOs with exactly the names in `site.yaml`;
   - `proxmox-setup.sh check`, then `proxmox-setup.sh`, as root on the node: pre-flight
     (node, storage, bridge, ISOs, VMID collisions), then pool, least-privilege role,
     `terraform-prov@pve` and its tokens, and the MGMT-00 VM with Windows installed
     unattended;
   - MGMT-00's updates, the toolchain, the vault;
   - `Test-LabInventory.ps1`, `Test-LabSite.ps1` (live pre-flight), both templates and
     Phase 1;
   - joining MGMT-00 to the domain;
   - replacing MGMT-00 with a pipeline-built MGMT (the first MGMT rotation, below).

After that, every machine in the lab is template-built and pipeline-managed. `Build-LabTemplate`, `Invoke-LabPhase` and `Invoke-LabMgmtRotation`
run `Test-LabSite.ps1` first and stop on any error.

## What Phase 1 does

1. Validates the inventory and the site; allocates `DC-<today>-00` (slot A, host .10,
   forest) and `DC-<today>-01` (slot B, host .11, replica) in the ledger.
2. `terraform apply` creates both as linked clones of the current WIN2022-TEMPLATE version
   (recorded per instance in the ledger as `template_vmid`).
3. For each DC, in order: connects over WinRM/HTTPS (MGMT addresses only), pushes the
   platform, metadata and that DC's secrets, starts bootstrap, and follows it
   through reboots.
   - **Forest DC**: features → `Install-ADDSForest` → DNS forwarders + reverse zone,
     site subnet, the tenant domain as UPN suffix, the tiered OUs (`Admin/Tier0|1|2`), groups
     in their tier (`SG-ROLE-DomainAdmins` → Domain Admins), each administrator from
     `site.yaml` as `<user>` (People) and `<user>-a` (their tier), `svc-labdeploy` and `svc-domainjoin` (Tier 0; join is delegated
     on every computer OU), new computers → `Staging`, Windows LAPS (schema, policy on every
     computer OU, DSRM backup on DCs), PDC → the site's NTP servers.
   - **Replica DC**: waits for the domain → `Install-ADDSDomainController` with
     `svc-labdeploy` → DNS client partner-first.
4. Gates on each DC's validation report: Critical stops the run.
   Each DC is marked active in the ledger as soon as its own validation passes.
5. Sets every DC's DNS client partner-first (loopback last) and re-validates all DCs.

Re-run with `-Retry` after fixing a failure; it resumes from the stage that failed. If
every DC is already active and only step 5 failed, `-Retry` re-runs step 5 alone.

## Replacing MGMT

MGMT runs the pipeline, so it can't destroy itself and start over. Replacing it is a
handover between two machines. Every guest's WinRM firewall allows both MGMT slot
addresses (hosts `.30` and `.31`), so the replacement can manage the lab from the moment
it takes over.

**Before you start:**
- `proxmox.endpoint` must be reachable **from the lab subnet**, not only over Tailscale or
  a VPN: the new MGMT isn't on your tailnet. Validation warns about `*.ts.net` and
  `100.64.0.0/10` endpoints.
- Back up the current MGMT's VM with a Proxmox **backup** (`vzdump <vmid> --storage <s>`) to a
  storage with the `backup` content type and room for it (`pvesm status`); LVM-thin and ZFS
  pools such as `local-lvm` can't hold backups, and a node's `local` is its root disk. Not a snapshot:
  Complete destroys the VM, and its snapshots with it.
- Plan how you'll reach the new MGMT: Remote Desktop is allowed from the lab subnet and
  from any network in `site.yaml` `network.remote_desktop_from` (e.g. your workstation's
  LAN). Otherwise connect from the current MGMT, or use the Proxmox console.

**1. On the current MGMT** (PowerShell 7, vault unlocked):
```powershell
./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Prepare
```
This builds `MGMT-<today>-00` in the spare slot from the current WIN11-TEMPLATE version. Its bootstrap
installs the same toolchain as the hand-build, turns on Remote Desktop (lab subnet plus
`network.remote_desktop_from`, NLA) and joins the domain into `Admin/Tier0/Devices` (MGMT is a Tier 0 admin workstation); LAPS then takes over its local
Administrator. Prepare stops on any Critical result from its validation (`MGMT-001…007`:
toolchain, RSAT, modules, domain trust, WinRM reach to every DC, Proxmox API, Remote
Desktop; RSAT is High, so only reported), then hands over the
repo (with git history), Terraform state and KeePass vault, each hash-verified.
Last, it locks the old MGMT: every pipeline script on it refuses to run, except Abort.

**2. On the new MGMT** (Remote Desktop as `<NETBIOS>\<you>-a`; a normal PowerShell 7 window is fine):
```powershell
cd C:\MidCoastLab\repo
git config --global user.name  "<Your Name>"; git config --global user.email "<you@example.com>"   # new profile
./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath C:\MidCoastLab\MidCoastLab.kdbx   # registers the vault for your account
./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Complete
git add inventory/instances.yaml; git commit -m "MGMT rotation"
```
Complete checks it can reach Proxmox and every DC, and that the handed-over Terraform
state matches the ledger (creates or deletes stop it; in-place updates only warn). Then it
shuts the old MGMT down, destroys its VM and confirms it's gone, and only then removes
its computer object and DNS records. **The first time, add `-KeepOld`** to only shut it down;
run Complete again later to destroy it.

**Rolling back:** until Complete destroys the old MGMT, run
`Invoke-LabMgmtRotation.ps1 -Stage Abort` on it. After the handover this needs
`-Force`, because anything done on the new MGMT since then is discarded.

Slots alternate: the next rotation builds into slot A again (host `.30`, VMID `vmid_base + 20`).

## Replacing a DC

A DC is replaced by a new one from the current WIN2022-TEMPLATE version, never repaired.
The forest stays; only the machines change. Run from the active MGMT, in an **elevated**
PowerShell 7 window (the script also points this machine's DNS at the new set of DCs).

**Safety net (optional):** snapshot **both** DCs first, on the node as root
(`qm snapshot <vmid> pre-rotation` for each). On LVM-thin or ZFS a snapshot lives in the
VM's own storage and only stores changes, so it costs little. If you ever revert, revert
both DCs together: reverting one DC alone puts it behind its partner. Delete the snapshots
(`qm delsnapshot <vmid> pre-rotation`) once Retire is done; the retired DC's goes with its VM.

```powershell
./orchestration/Invoke-LabDcRotation.ps1 -Stage Add      # optional: -Replace <DC name>; default the oldest
git add inventory/instances.yaml; git commit -m "DC rotation: add"
# ...check anything you like...
./orchestration/Invoke-LabDcRotation.ps1 -Stage Retire
git add inventory/instances.yaml; git commit -m "DC rotation: retire"
```

**Add** checks both DCs pass validation, builds `DC-<today>-NN` in the free DC slot as a
replica of the DC that stays, gates on its validation, moves every FSMO role (and with the
PDC emulator, the external time source) from the old DC to the new one, marks the old one
`retiring` and points every DNS client in the lab at the active DCs: DCs partners first and
loopback last, every other lab machine and this MGMT the DCs. The old DC keeps running as a
third DC; nothing depends on it any more.

**Retire** demotes the old DC, removes the DNS records it left behind and its computer
object, and destroys the VM. Terraform may delete exactly that VM and nothing else.

**Abort** (before Retire) undoes Add: the old DC is active again, FSMO roles and DNS
clients move back, and the replacement is demoted and destroyed.

Every stage can be re-run after a failure. `-Force` (Retire/Abort) handles a DC that can't
be reached: its FSMO roles are seized and it's cleaned out of AD (ntdsutil metadata
cleanup) instead of demoted.

The DCs' addresses move: the new DC takes the free slot (`.10`–`.12`), so after a rotation
the lab's DNS servers are different addresses. Anything outside the lab that you pointed at
a DC by hand (a DNS override or forward on the router, Tailscale split DNS, a workstation)
needs updating; Add prints the new addresses. Rotate one DC at a time, and before either
DC's evaluation licence runs out (`EVAL-001`).

## Templates

`./orchestration/Build-LabTemplate.ps1 [-Template windows_11]` builds a new **version**
(`WIN2022-TEMPLATE-<YYMMDD>-<NN>`) at the next free VMID of the template's range and makes
it current. Existing VMs stay linked clones of the version they were built from; the next
VM of that role (a rotation) gets the new one. A superseded version is deleted
automatically once no VM uses it. Rebuild monthly, or after critical updates, and commit
`inventory/instances.yaml` afterwards (the ledger lists the versions).

## Validation IDs

**DC:** `NET-001/002`, `AD-001/002/003`, `DNS-001…004`, `SYSVOL-001/002`, `FSMO-001`,
`REPL-001/002`, `TIME-001`, `LAPS-001/002`, `RDP-001` (Remote Desktop), `DNS-005` (no Tailscale address in AD's DNS), `TS-001` (tailnet), `MEM-001` (balloon service), `EVAL-001` (evaluation days left).
**MGMT:** `NET-001/002`, `MGMT-001…007`, `TS-001`, `MEM-001`, `EVAL-001`.
Severity and recovery for each: `platform/validation/catalog.psd1`. Reports:
`C:\ProgramData\MidCoastLab\Logs\Validation\latest.json` on each machine.
