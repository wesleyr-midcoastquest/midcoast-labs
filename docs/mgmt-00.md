# {{site.name}}: first build runbook

<!-- TEMPLATE-NOTE -->
> **This page is a template.** `{{tokens}}` stand for your site's values. Run
> `./setup/New-LabSiteKit.ps1` to get `out/site-kit/<site>/RUNBOOK.md`, a copy with every
> value filled in from `inventory/site.yaml`, plus the matching `proxmox-setup.sh`.
> New site? Start with the [README](../README.md): its checklist leads here.
<!-- /TEMPLATE-NOTE -->

This takes a site from an empty Proxmox node to two validated domain controllers, both
templates, and a pipeline-built MGMT.
MGMT-00 is the only machine not built by the pipeline: `proxmox-setup.sh` installs its
Windows unattended, you install its toolchain, and step 9 replaces it with a pipeline-built
MGMT before the first build is done. 

| | |
|---|---|
| Site | `{{site.name}}` |
| AD domain / NetBIOS | `{{ad.domain}}` / `{{ad.netbios}}` |
| Entra domain (UPN suffix) | `{{tenant.domain}}` |
| Proxmox | node `{{proxmox.node}}`, pool `{{proxmox.pool}}`, bridge `{{proxmox.bridge}}`, storage `{{storage.vm}}` |
| Lab subnet | `{{network.subnet}}`, gateway `{{network.gateway}}`, lab range `{{static.start}}`–`{{static.end}}` |
| MGMT-00 | VMID `{{mgmt00.vmid}}`, `{{mgmt00.ip}}/{{network.prefix}}`, {{mgmt00.cores}} vCPU, {{mgmt00.memory_gb}} GB, {{mgmt00.disk_gb}} GB, Windows 11 Enterprise evaluation |

## 1. Router on the lab bridge

The router (or firewall VM) on `{{proxmox.bridge}}` is the lab's gateway, `{{network.gateway}}`
on `{{network.subnet}}`. Configure its DHCP:

- **Exclude `{{static.start}}`–`{{static.end}}`** from the DHCP pool (or start the pool above
  `{{static.end}}`). Every lab server's static address is in that range, including the
  spare DC and MGMT slots used during replacements.
- Keep DHCP on for the rest of the subnet: new VMs use it for their first boot.
- Make it **authoritative** (dnsmasq/OPNsense: the DHCP "Authoritative" option), so it
  refuses leases it didn't hand out instead of staying silent. Otherwise new clones can
  keep a stale address and collide.

To manage the lab remotely, advertise `{{network.subnet}}` as a Tailscale subnet route
from a device on `{{proxmox.bridge}}`, and approve it in the Tailscale admin console.

## 2. Upload the ISOs

Put three ISOs on storage `{{storage.iso}}` on `{{proxmox.node}}`, with exactly these file
names (from `isos` in `site.yaml`; the setup script and the template builds look for them):

| ISO | File name | Proxmox volume |
|---|---|---|
| Windows Server 2022 evaluation | `{{iso.windows_server_2022.file}}` | `{{iso.windows_server_2022}}` |
| Windows 11 Enterprise evaluation | `{{iso.windows_11.file}}` | `{{iso.windows_11}}` |
| VirtIO drivers | `{{iso.virtio.file}}` | `{{iso.virtio}}` |

The easiest way skips your workstation: in the Proxmox UI, select `{{proxmox.node}}`, then
storage `{{storage.iso}}`, then **ISO Images**, then **Download from URL**. Paste the link,
click **Query URL**, set **File name** to the name in the table, and click **Download**.

- **Server 2022 evaluation** (64-bit, English), from Microsoft's download server:
  `https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso`
- **VirtIO** (Fedora's stable build):
  `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`
- **Windows 11 Enterprise evaluation**: Microsoft changes this link with each release.
  Fill in the form at <https://www.microsoft.com/evalcenter/evaluate-windows-11-enterprise>,
  then right-click "ISO – 64-bit, English (United States)" and copy the link address.
  (The same works for Server 2022 if the link above stops working.)

`proxmox-setup.sh check` in step 3 confirms all three are there under these names.

## 3. Proxmox setup (on {{proxmox.node}}, as root)

Copy the site kit's `proxmox-setup.sh` to `{{proxmox.node}}`, with `scp`, Taildrop
(`tailscale file cp`) or by pasting into the node's Shell in the Proxmox UI. Then:

```bash
bash proxmox-setup.sh check   # pre-flight only: node, storage, bridge, ISOs, VMID collisions
bash proxmox-setup.sh         # pre-flight, then set up
```

It creates the `{{proxmox.pool}}` pool, the least-privilege role, the
`terraform-prov@pve` user and its two API tokens, and the **{{mgmt00.name}} VM** (VMID
`{{mgmt00.vmid}}`, in the pool). Then it **installs Windows 11 on it unattended**, from an
answer CD it builds on the node:

- the disk, and the VirtIO disk and network drivers, during setup;
- no first-run screens: licence accepted, privacy options off, no Microsoft account;
- a local admin account, **`{{mgmt00.local_user}}`**, with a generated password;
- at first sign-in: the VirtIO guest tools (QEMU guest agent), the name `{{mgmt00.name}}`,
  time zone `{{site.time_zone}}`, static address `{{mgmt00.ip}}/{{network.prefix}}` (gateway
  `{{network.gateway}}`, DNS `{{dns.forwarder}}` until step 8), and Remote Desktop from
  `{{network.subnet}}`.

The script waits for all of that (about 20 to 40 minutes; watch the VM's console if you
like), then ejects the install media and deletes the answer CD. If you stop it while it
waits, the install carries on; `bash proxmox-setup.sh finish-mgmt00` picks the wait up
again.

At the end it prints **every secret it created**: the two token secrets and
`{{mgmt00.local_user}}`'s password. They're shown here only, and kept until then in a
root-only file on the node. Copy them (the tokens go into the vault in step 6;
`{{mgmt00.local_user}}`'s password into your own password manager: it's your way back in
after the domain join), then delete the file as the script says (`shred -u ...`).

## 4. First sign-in on {{mgmt00.name}}

1. Sign in as `{{mgmt00.local_user}}` on the VM's console, or with Remote Desktop to
   `{{mgmt00.ip}}` from the lab subnet. Check, in PowerShell:
   ```powershell
   hostname                               # {{mgmt00.name}}
   Test-NetConnection {{network.gateway}}     # TcpTestSucceeded or PingSucceeded: True
   ```
   If something's off, `C:\ProgramData\MidCoastLab\mgmt00-setup.log` says what the
   first-logon setup did.
2. Install Windows updates (Settings, Windows Update) and restart until none are left.

## 5. Toolchain and repo

1. Copy this repo onto {{mgmt00.name}} (including your `inventory/site.yaml`). In an
   **elevated Windows PowerShell**, from that copy:
   ```powershell
   Set-ExecutionPolicy -Scope LocalMachine RemoteSigned
   Get-ChildItem -Recurse | Unblock-File
   .\setup\mgmt\Install-MgmtTools.ps1
   ```
   `Unblock-File` is needed when the copy came from a zip or a download: Windows marks
   those files as from the internet, and `RemoteSigned` refuses to run them ("is not
   digitally signed"). Only unblock a copy you trust.
   This installs PowerShell 7, Git, Terraform, Packer, VS Code, KeePassXC, the ADK
   Deployment Tools (for `oscdimg.exe`), RSAT and the PowerShell modules, straight from
   each vendor (the same installer every pipeline-built MGMT runs). It also creates
   `C:\MidCoastLab` and grants your account access, so the next steps don't need
   elevation.
2. Put the repo at `{{repo.path}}`, with your filled-in `inventory/site.yaml`: either
   `git clone <your repo URL> {{repo.path}}`, or move the copy there. It must be a **git
   repository**: the pipeline commits the ledger and hands the history to every new MGMT.
   A copied folder usually isn't one (the `.git` folder stays behind), so in a new
   **PowerShell 7** window (Git is on the PATH now):
   ```powershell
   cd {{repo.path}}
   git config --global user.name  "<Your Name>"
   git config --global user.email "<you@example.com>"
   if (-not (Test-Path .git)) { git init; git add -A; git commit -m "MidCoast Lab: {{site.name}}" }
   git status --short          # nothing listed; no .kdbx or .tfstate is ever committed (.gitignore)
   ```
   `Test-LabSite.ps1` (step 7) stops if the repo isn't a git repository. Terraform state
   will live in `{{state.path}}`.

## 6. Vault

1. In KeePassXC, create `{{vault.path}}` with a strong master password.
2. In **PowerShell 7**:
   ```powershell
   cd {{repo.path}}
   ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath {{vault.path}}
   ```
   It asks for the two Proxmox token secrets (and, when `site.yaml` has
   `tailscale.enabled: true`, your Tailscale auth key) and generates every other
   password the inventory names. Make the Tailscale key in the admin console (Settings,
   Keys) **reusable**, **tagged** (e.g. `tag:midcoast-lab`) and **not ephemeral** (leave *Ephemeral* off). An ephemeral device is removed from the tailnet once it's offline for a while and can't rejoin by itself; lab machines restart, and the key is deleted from each machine after setup. **Back up the `.kdbx` and its master password.**
3. **Tailscale** (only with `tailscale.enabled: true`). In an **elevated PowerShell 7**:
   ```powershell
   ./setup/mgmt/Join-LabTailnet.ps1
   ```
   {{mgmt00.name}} joins your tailnet and allows Remote Desktop over it. Every
   pipeline-built machine does the same by itself during its setup.

At the start of each session: `Unlock-SecretVault -Name {{vault.name}}`.

## 7. Pre-flight, both templates, Phase 1

In PowerShell 7, from `{{repo.path}}`:

```powershell
./orchestration/Test-LabInventory.ps1        # lab.yaml + site.yaml
./orchestration/Test-LabSite.ps1             # live: Proxmox, VMIDs, lab addresses
./orchestration/Build-LabTemplate.ps1        # WIN2022-TEMPLATE, about an hour
./orchestration/Build-LabTemplate.ps1 -Template windows_11   # WIN11-TEMPLATE, about an hour
git add inventory/instances.yaml; git commit -m "Templates"
./orchestration/Invoke-LabPhase.ps1 -Phase 1 -PlanOnly
./orchestration/Invoke-LabPhase.ps1 -Phase 1 # two DCs, about an hour
git add inventory/instances.yaml; git commit -m "Phase 1"
```

Both templates now: neither needs the domain, and step 9 needs the Windows 11 one. Build
them one after the other (they share the build slot), not at the same time.

## 8. Join {{mgmt00.name}} to the domain

The join uses `svc-domainjoin`, the account Phase 1 created for joining computers. Its
password, like every lab password, was generated into the vault in step 6.

> **Before you start: have a way back in.** The vault lives *on* {{mgmt00.name}}, and Remote
> Desktop asks for the password before you get a desktop. So before joining, make sure you
> can reach these from somewhere else:
> - the password of the local account **`{{mgmt00.local_user}}`** (printed by
>   `proxmox-setup.sh` in step 3; it keeps working after the join: LAPS manages only the
>   built-in Administrator), and
> - the password of **`{{ad.netbios}}\{{admin.account}}`**, your Tier 0 admin account: copy it
>   from the vault now (`Get-Secret -Vault {{vault.name}} -Name {{admin.account}} -AsPlainText`)
>   into your own password manager, or keep a copy of the `.kdbx` where you can open it.
>
> If you're locked out anyway, the VM's console in the Proxmox UI still works.

1. **Point DNS at the DCs.** In an **elevated Windows PowerShell** (Phase 1 builds its
   two DCs in slots A and B):
   ```powershell
   $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
   Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses {{dc.a.ip}}, {{dc.b.ip}}
   Resolve-DnsName {{ad.domain}}      # should return the DC addresses
   ```
2. **Copy the join password.** In **PowerShell 7** (the vault lives there):
   ```powershell
   Unlock-SecretVault -Name {{vault.name}}
   Get-Secret -Vault {{vault.name}} -Name svc-domainjoin -AsPlainText | Set-Clipboard
   ```
3. **Join.** Back in the **elevated Windows PowerShell** (`Add-Computer` isn't in
   PowerShell 7). At the credential prompt, the user name is filled in; paste the
   password with Ctrl+V:
   ```powershell
   Add-Computer -DomainName {{ad.domain}} -OUPath '{{mgmt.ou_dn}}' `
     -Credential {{ad.netbios}}\svc-domainjoin -Restart
   ```
   Then clear the clipboard: `Set-Clipboard -Value ' '`.
4. **After the restart**, still signed in locally, grant the Tier 0 admin group access to
   the lab folder (the same grant every pipeline-built MGMT gets), in an elevated prompt:
   ```powershell
   icacls {{lab.root}} /grant '{{ad.netbios}}\{{tier0.group}}:(OI)(CI)F' /T /C /Q
   git config --system --add safe.directory {{repo.path_fwd}}
   Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-555') -Member '{{ad.netbios}}\{{tier0.group}}'
   ```
   The last line lets the Tier 0 admin group use Remote Desktop (every pipeline-built MGMT
   gets the same grant). Only that group: standard accounts don't sign in to
   {{mgmt00.name}}, which is a Tier 0 admin workstation.
5. **Switch to your admin account.** Copy its password the same way:
   `Get-Secret -Vault {{vault.name}} -Name {{admin.account}} -AsPlainText | Set-Clipboard`.
   Sign out, and sign in as `{{ad.netbios}}\{{admin.account}}`. From now on, work as that
   account. LAPS takes over {{mgmt00.name}}'s local Administrator.

   Your new profile hasn't registered the vault yet. In PowerShell 7, from `{{repo.path}}`:
   `./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath {{vault.path}}`. It registers the
   vault for this account, and every entry should report `exists`.

## 9. Replace {{mgmt00.name}} with a pipeline-built MGMT

{{mgmt00.name}} was only the starter: it isn't built from a template, doesn't follow the
naming convention, and the pipeline can't manage it like the rest. Replace it now, so from
here on every machine in the lab is template-built and pipeline-managed. The rotation
builds `MGMT-<today>-00` at `{{mgmt.b.ip}}` from the WIN11-TEMPLATE, hands over the repo, the
Terraform state and the vault, and then retires {{mgmt00.name}}. About an hour.

1. **On {{mgmt00.name}}**, in PowerShell 7, from `{{repo.path}}`:
   ```powershell
   ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Prepare
   ```
   Check its validation report: `MGMT-007` (Remote Desktop) must pass, and `TS-001`
   too if `tailscale.enabled` is on.
2. **Remote Desktop to `{{mgmt.b.ip}}`** as `{{ad.netbios}}\{{admin.account}}`, from
   {{mgmt00.name}} (or over your tailnet). Open **PowerShell 7**:
   ```powershell
   cd {{repo.path}}
   git config --global user.name  "<Your Name>"
   git config --global user.email "<you@example.com>"
   ./setup/mgmt/Initialize-LabVault.ps1 -DatabasePath {{vault.path}}   # registers the vault for this machine
   ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Complete -KeepOld
   ```
   `-KeepOld` only shuts {{mgmt00.name}} down, so `Invoke-LabMgmtRotation.ps1 -Stage Abort -Force`
   on it still works if the new MGMT turns out wrong.
3. **Once you're happy with the new MGMT**, retire {{mgmt00.name}} for good, still on the new MGMT:
   ```powershell
   ./orchestration/Invoke-LabMgmtRotation.ps1 -Stage Complete
   git add inventory/instances.yaml; git commit -m "MGMT rotation: {{mgmt00.name}} retired"
   ```
   It destroys VM `{{mgmt00.vmid}}` and removes its computer account and DNS records. If
   {{mgmt00.name}} joined your tailnet, remove it in the Tailscale admin console (the pipeline
   can't reach it to log it out). Its local account `{{mgmt00.local_user}}` goes with it.

From here on, MGMT is replaced only by `Invoke-LabMgmtRotation.ps1` and DCs by
`Invoke-LabDcRotation.ps1` (the repo's `docs/replace-mgmt.md` and `docs/replace-dc.md`).
