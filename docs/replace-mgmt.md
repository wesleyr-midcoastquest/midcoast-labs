# Replacing MGMT

MGMT is the lab's management machine: it runs the pipeline and holds the repo, the
Terraform state and the vault. Windows 11 evaluation editions last 90 days, so plan on
replacing MGMT about **every two months** (each validation report's `EVAL-001` shows the
days left). The first replacement is also the last step of the first build: it swaps the
starter machine, MGMT-00, for a pipeline-built one.

Run everything below on MGMT, in **PowerShell 7**, from `C:\MidCoastLab\repo`, with the
vault unlocked (`Unlock-SecretVault -Name MidCoastLab`).

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
git add inventory/instances.yaml; git commit -m "MGMT rotation"; git push
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
