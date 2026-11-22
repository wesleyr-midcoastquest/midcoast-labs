#!/usr/bin/env bash
# proxmox-setup.sh: one-time Proxmox setup for a MidCoast Lab site.
#
# DON'T run this repo copy. ./setup/New-LabSiteKit.ps1 writes a filled-in copy
# to out/site-kit/<site>/proxmox-setup.sh with this site's values at the top.
# Copy that one to the lab's Proxmox node and run it there as root:
#
#   bash proxmox-setup.sh check   # pre-flight only, changes nothing
#   bash proxmox-setup.sh         # pre-flight, then set up
#
# Pre-flight (as root it sees every VM on the cluster, so it is the
# authoritative collision check):
#   - running on the lab's node
#   - storages exist and accept disk images / ISO images
#   - the lab bridge exists
#   - every lab VMID is free, or already this lab's (carrying the lab's tag), and the
#     pool and user aren't another site's
#   - the ISOs are uploaded (Windows 11 + VirtIO are required for MGMT-00)
# Setup:
#   - pool, least-privilege role, terraform-prov@pve user, API tokens
#     (secrets printed ONCE: put them in KeePass), ACLs
#   - the MGMT-00 VM, unless it exists or CREATE_MGMT00=0, with an answer CD that
#     installs Windows 11 unattended: disk, VirtIO drivers, a local admin account,
#     no first-run screens, then guest tools, static address, time zone, name and
#     Remote Desktop. The script starts it, waits for the install to finish (about
#     20-40 minutes), ejects the install media and deletes the answer CD.
#   - with site.yaml tailscale.enabled, MGMT-00 can join your tailnet during that
#     install, so you can reach it before anything else exists: the script asks
#     for a ONE-TIME (single-use, tagged, not ephemeral) auth key, or takes it from
#     the TAILSCALE_AUTHKEY environment variable; leave it empty to skip. The key
#     is never written to the site kit; it rides on the answer CD (root-only, shredded
#     after the install) and is used once. Runbook step 6 later switches MGMT-00 to the
#     vault's reusable key, like every other lab machine.
#   - every secret it creates (API tokens, MGMT-00's local password) is printed and
#     kept in a root-only file until you've copied it (shred it afterwards)
#
#   bash proxmox-setup.sh finish-mgmt00   # resume waiting for the MGMT-00 install
#
# Safe to re-run: existing objects are updated, tokens are never re-created.
set -euo pipefail

# ── Site values ───────────────────────────────────────────────────────────
#@@SITE_VALUES@@

: "${SITE_NAME:?This is the template copy. Generate the site kit with ./setup/New-LabSiteKit.ps1 and run out/site-kit/<site>/proxmox-setup.sh instead.}"
for v in NODE POOL USER_ID ROLE TAG TOKENS TEMPLATE_STORAGE VM_STORAGE ISO_STORAGE BRIDGE CLONE_MODE LAB_VMIDS ISO_FILES \
         MGMT00_VMID MGMT00_NAME MGMT00_CORES MGMT00_MEMORY MGMT00_DISK_GB MGMT00_ISO VIRTIO_ISO \
         MGMT00_IP MGMT00_PREFIX MGMT00_GATEWAY MGMT00_DNS MGMT00_TIME_ZONE MGMT00_IMAGE_INDEX MGMT00_DRIVER_OS \
         MGMT00_LOCAL_USER LAB_SUBNET TAILSCALE_ENABLED \
         VAULT_NAME TOKEN_SECRET_NAMES; do
  [[ -n "${!v:-}" ]] || { echo "Missing site value $v; regenerate the site kit." >&2; exit 2; }
done
CREATE_MGMT00="${CREATE_MGMT00:-1}"
MODE="${1:-setup}"
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root." >&2; exit 2; }
SECRETS_FILE="/root/midcoast-$SITE_NAME-secrets.txt"
ANSWER_ISO="midcoast-mgmt00-answer.iso"

# ── MGMT-00 unattended install: wait for it, then tidy up ─────────────────
guest_has_marker() {  # true once MGMT-00's first-logon setup has written its marker
  local out
  out="$(qm guest exec "$MGMT00_VMID" --timeout 30 -- cmd.exe /c "if exist C:\\ProgramData\\MidCoastLab\\mgmt00-setup.done (echo DONE)" 2>/dev/null || true)"
  [[ "$out" == *DONE* ]]
}
finish_mgmt00() {
  echo "==> Waiting for the $MGMT00_NAME install (VM $MGMT00_VMID); watch it on the VM's console if you like"
  local deadline=$(( $(date +%s) + 7200 )) shown=0
  until guest_has_marker; do
    if (( $(date +%s) > deadline )); then
      echo "  Not finished after 2 hours. Check the console; C:\\ProgramData\\MidCoastLab\\mgmt00-setup.log has the details."
      echo "  Re-run when it's done: bash proxmox-setup.sh finish-mgmt00"
      return 1
    fi
    if (( shown == 0 )); then echo "  (Windows setup, then first sign-in setup; the guest agent answers only after that)"; shown=1; fi
    sleep 30
  done
  echo "  install and first-logon setup finished"
  # Eject the Windows ISO and the answer CD (it holds the encoded password); boot from disk only.
  qm set "$MGMT00_VMID" --ide2 none,media=cdrom --ide3 none,media=cdrom --boot order=scsi0 >/dev/null
  local iso_path; iso_path="$(pvesm path "$ISO_STORAGE:iso/$ANSWER_ISO" 2>/dev/null || true)"
  [[ -n "$iso_path" && -f "$iso_path" ]] && shred -u "$iso_path" 2>/dev/null || rm -f "$iso_path" 2>/dev/null || true
  echo "  install media ejected; answer CD deleted"
}
if [[ "$MODE" == "finish-mgmt00" ]]; then
  finish_mgmt00
  [[ -f "$SECRETS_FILE" ]] && { echo; echo "Secrets still in $SECRETS_FILE:"; cat "$SECRETS_FILE"; echo "Copy them, then: shred -u $SECRETS_FILE"; }
  exit 0
fi

# ── Pre-flight ────────────────────────────────────────────────────────────
ERRORS=0
fail() { echo "  ERROR: $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo "  warning: $*"; }
echo "==> Pre-flight for site '$SITE_NAME'"

[[ "$(hostname)" == "$NODE" ]] || fail "this is node '$(hostname)', but the site's node is '$NODE'. Run on '$NODE'."

storage_field() {  # prints a field of a storage's config, or nothing if it doesn't exist
  pvesh get "/storage/$1" --output-format json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true
}
storage_content() { storage_field "$1" content; }
for pair in "$TEMPLATE_STORAGE:images" "$VM_STORAGE:images" "$ISO_STORAGE:iso"; do
  s="${pair%%:*}"; need="${pair##*:}"
  c="$(storage_content "$s")"
  if [[ -z "$c" ]]; then fail "storage '$s' doesn't exist."
  elif [[ ",$c," != *",$need,"* ]]; then fail "storage '$s' doesn't accept '$need' (content: $c)."; fi
done

if [[ "$CLONE_MODE" == "linked" ]]; then
  t="$(storage_field "$TEMPLATE_STORAGE" type)"
  case "$t" in
    lvmthin|zfspool|rbd) ;;
    "") ;;  # missing storage is reported above
    *) fail "storage '$TEMPLATE_STORAGE' is type '$t', which can't hold linked clones of the lab's templates. Use LVM-thin, ZFS or Ceph RBD, or set proxmox.clone_mode: full in site.yaml and regenerate the kit." ;;
  esac
fi

BRIDGE_TYPE="$(pvesh get "/nodes/$NODE/network/$BRIDGE" --output-format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("type",""))' 2>/dev/null || true)"
[[ "$BRIDGE_TYPE" == *bridge* ]] || fail "bridge '$BRIDGE' doesn't exist on node '$NODE' (pvesh get /nodes/$NODE/network/$BRIDGE)."

# VMIDs: everything the lab can claim must be free, or already the lab's.
pvesh get /cluster/resources --type vm --output-format json > /tmp/midcoast-vms.json
COLLISIONS="$(LAB_VMIDS="$LAB_VMIDS" TAG="$TAG" MGMT00_VMID="$MGMT00_VMID" MGMT00_NAME="$MGMT00_NAME" python3 - <<'PY'
import json, os
vms = {int(v["vmid"]): v for v in json.load(open("/tmp/midcoast-vms.json"))}
out = []
for item in os.environ["LAB_VMIDS"].split():
    vid, what = item.split("=", 1)
    v = vms.get(int(vid))
    if not v:
        continue
    tags = [t for t in str(v.get("tags", "")).replace(",", ";").replace(" ", ";").split(";") if t]
    own = os.environ["TAG"] in tags or (vid == os.environ["MGMT00_VMID"] and v.get("name") == os.environ["MGMT00_NAME"])
    if not own:
        other = [t for t in tags if t.startswith("midcoast-lab") and t != os.environ["TAG"]]
        who = f"another MidCoast lab (tag {other[0]}): its VMID block overlaps this site's" if other else f"'{v.get('name')}' on {v.get('node')}"
        out.append(f"VMID {vid} ({what.replace('_', ' ')}) is used by {who}")
print("\n".join(out))
PY
)"
rm -f /tmp/midcoast-vms.json
if [[ -n "$COLLISIONS" ]]; then
  while IFS= read -r line; do fail "$line"; done <<< "$COLLISIONS"
  echo "  Pick a free 150-ID block and set proxmox.vmid_base in site.yaml, then regenerate the kit."
fi

# The lab's names must not belong to another site (two labs on one cluster each
# need their own pool, role, tag and user; site.yaml sets them, "{site}" helps).
POOL_OWNER="$(pveum pool list --output-format json | python3 -c "
import json,sys,re
for p in json.load(sys.stdin):
    if p['poolid']=='$POOL':
        m=re.search(r'MidCoast Lab site (\S+)', p.get('comment','') or ''); print(m.group(1) if m else '')
" 2>/dev/null || true)"
[[ -z "$POOL_OWNER" || "$POOL_OWNER" == "$SITE_NAME" ]] || fail "pool '$POOL' belongs to site '$POOL_OWNER', not '$SITE_NAME'. Set proxmox.pool (and role, tag, service_account.user) in site.yaml, e.g. with {site}, and regenerate the kit."
USER_OWNER="$(pveum user list --output-format json | python3 -c "
import json,sys,re
for u in json.load(sys.stdin):
    if u['userid']=='$USER_ID':
        m=re.search(r'site (\S+)', u.get('comment','') or ''); print(m.group(1) if m else '')
" 2>/dev/null || true)"
[[ -z "$USER_OWNER" || "$USER_OWNER" == "$SITE_NAME" ]] || fail "user '$USER_ID' belongs to site '$USER_OWNER', not '$SITE_NAME'. Set proxmox.service_account.user in site.yaml and regenerate the kit."

MGMT00_EXISTS=0
qm status "$MGMT00_VMID" >/dev/null 2>&1 && MGMT00_EXISTS=1
ISO_LIST="$(pvesm list "$ISO_STORAGE" --content iso 2>/dev/null | awk 'NR>1 {print $1}' || true)"
for f in $ISO_FILES; do
  if ! grep -qxF "$f" <<< "$ISO_LIST"; then
    if [[ "$CREATE_MGMT00" == "1" && "$MGMT00_EXISTS" == "0" && ( "$f" == "$MGMT00_ISO" || "$f" == "$VIRTIO_ISO" ) ]]; then
      fail "ISO $f isn't uploaded (MGMT-00 needs it)."
    else
      warn "ISO $f isn't uploaded yet (template builds need it)."
    fi
  fi
done

if [[ "$CREATE_MGMT00" == "1" && "$MGMT00_EXISTS" == "0" ]] && ! command -v genisoimage >/dev/null 2>&1; then
  warn "genisoimage isn't installed; setup installs it (apt-get) to build MGMT-00's answer CD."
fi
if (( ERRORS > 0 )); then echo "Pre-flight failed with $ERRORS error(s); nothing was changed."; exit 1; fi
echo "  pre-flight OK"
[[ "$MODE" == "check" ]] && exit 0

# ── Role, user, ACLs, tokens ──────────────────────────────────────────────
# Desired privileges. Names differ between PVE releases (PVE 9 replaced
# VM.Monitor with VM.GuestAgent.*), so the list is intersected with the
# privileges this cluster actually knows.
WANT=(
  Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit
  Pool.Audit
  SDN.Audit SDN.Use
  Sys.Audit
  VM.Allocate VM.Audit VM.Clone VM.Console VM.Migrate VM.PowerMgmt
  VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType
  VM.Config.Memory VM.Config.Network VM.Config.Options
  VM.Monitor VM.GuestAgent.Audit
  # 1.6: CERT snapshots every lab VM (RAM included) before a scenario and rolls
  # them back afterwards, with this token. The vmstate volume is covered by
  # Datastore.AllocateSpace above.
  VM.Snapshot VM.Snapshot.Rollback
)
KNOWN="$(pvesh get /access/roles/Administrator --output-format json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(d.keys())))')"
PRIVS=()
for p in "${WANT[@]}"; do
  if [[ " $KNOWN " == *" $p "* ]]; then PRIVS+=("$p"); else echo "  (skipping $p: not a privilege on this PVE version)"; fi
done
PRIV_LIST="$(IFS=,; echo "${PRIVS[*]}")"

echo "==> Pool $POOL"
pveum pool list --output-format json | python3 -c "import json,sys; sys.exit(0 if any(p['poolid']=='$POOL' for p in json.load(sys.stdin)) else 1)" \
  || pveum pool add "$POOL" --comment "MidCoast Lab site $SITE_NAME (managed by pipeline)"

echo "==> Role $ROLE"
if pveum role list --output-format json | python3 -c "import json,sys; sys.exit(0 if any(r['roleid']=='$ROLE' for r in json.load(sys.stdin)) else 1)"; then
  pveum role modify "$ROLE" --privs "$PRIV_LIST"
else
  pveum role add "$ROLE" --privs "$PRIV_LIST"
fi

echo "==> User $USER_ID"
pveum user list --output-format json | python3 -c "import json,sys; sys.exit(0 if any(u['userid']=='$USER_ID' for u in json.load(sys.stdin)) else 1)" \
  || pveum user add "$USER_ID" --comment "MidCoast Lab provisioning (Terraform/Packer) for site $SITE_NAME. Tokens only."
pveum user modify "$USER_ID" --comment "MidCoast Lab provisioning (Terraform/Packer) for site $SITE_NAME. Tokens only." >/dev/null 2>&1 || true

echo "==> ACLs"
pveum acl modify "/pool/$POOL"                     --users "$USER_ID" --roles "$ROLE"
for s in $(printf '%s\n' "$TEMPLATE_STORAGE" "$VM_STORAGE" "$ISO_STORAGE" | sort -u); do
  pveum acl modify "/storage/$s"                   --users "$USER_ID" --roles "$ROLE"
done
pveum acl modify "/sdn/zones/localnetwork/$BRIDGE" --users "$USER_ID" --roles "$ROLE"
pveum acl modify "/nodes/$NODE"                    --users "$USER_ID" --roles PVEAuditor

echo "==> API tokens"
for t in $TOKENS; do
  if pveum user token list "$USER_ID" --output-format json | python3 -c "import json,sys; sys.exit(0 if any(x['tokenid']=='$t' for x in json.load(sys.stdin)) else 1)"; then
    # Keep the comment consistent, e.g. after a token was re-created by hand.
    pveum user token modify "$USER_ID" "$t" --comment "MidCoast Lab $t" >/dev/null
    echo "  token $USER_ID!$t already exists (secret not shown again; comment set)"
  else
    # privsep 0: the token carries exactly the user's permissions above.
    secret="$(pveum user token add "$USER_ID" "$t" --privsep 0 --comment "MidCoast Lab $t" --output-format json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
    ( umask 077; echo "Proxmox token $USER_ID!$t : $secret" >> "$SECRETS_FILE" )
    echo "  token $USER_ID!$t created (secret shown at the end, and kept in $SECRETS_FILE)"
  fi
done

# ── MGMT-00 ───────────────────────────────────────────────────────────────
echo "==> $MGMT00_NAME (VMID $MGMT00_VMID)"
if qm status "$MGMT00_VMID" >/dev/null 2>&1; then
  echo "  exists; making sure it's in pool $POOL and tagged $TAG"
  qm set "$MGMT00_VMID" --tags "$TAG;mgmt" >/dev/null
  pvesh get "/pools/$POOL" --output-format json | python3 -c "import json,sys; sys.exit(0 if any(int(m.get('vmid',-1))==$MGMT00_VMID for m in json.load(sys.stdin).get('members',[])) else 1)" \
    || pveum pool modify "$POOL" --vms "$MGMT00_VMID"
  # An unattended install an earlier run started and didn't see finish.
  if qm config "$MGMT00_VMID" | grep -qF "$ANSWER_ISO"; then MGMT00_STARTED=1; fi
elif [[ "$CREATE_MGMT00" == "1" ]]; then
  # ── Tailscale: a one-time key, typed now, used once by the install ──
  TS_KEY=""
  if [[ "$TAILSCALE_ENABLED" == "1" ]]; then
    if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
      TS_KEY="$TAILSCALE_AUTHKEY"
    else
      echo "  site.yaml has tailscale.enabled: $MGMT00_NAME can join your tailnet during its install."
      echo "  Make a ONE-TIME auth key (Tailscale admin console > Settings > Keys: reusable OFF, tagged, ephemeral OFF)."
      read -rs -p "  Paste it (or press Enter to skip; runbook step 6 joins later): " TS_KEY; echo
    fi
    if [[ -n "$TS_KEY" && "$TS_KEY" != tskey-auth-* ]]; then echo "  That doesn't look like a Tailscale auth key (tskey-auth-...); skipping." >&2; TS_KEY=""; fi
    [[ -n "$TS_KEY" ]] && echo "  $MGMT00_NAME will join the tailnet as $(tr '[:upper:]' '[:lower:]' <<< "$MGMT00_NAME")"
  fi
  # ── The answer CD ──
  command -v genisoimage >/dev/null 2>&1 || { echo "  installing genisoimage"; apt-get install -y -qq genisoimage >/dev/null; }
  ISO_PATH="$(pvesm path "$ISO_STORAGE:iso/$ANSWER_ISO")"
  WORK="$(mktemp -d)"; chmod 700 "$WORK"
  LOCAL_PW="$(python3 -c '
import secrets
sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz", "23456789", "!#%+-=?@_"]
allc = "".join(sets)
pw = [secrets.choice(s) for s in sets] + [secrets.choice(allc) for _ in range(16)]
secrets.SystemRandom().shuffle(pw)
print("".join(pw))')"
  PW_B64="$(python3 -c 'import base64,sys; print(base64.b64encode((sys.argv[1] + "Password").encode("utf-16-le")).decode())' "$LOCAL_PW")"
  cat > "$WORK/autounattend.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- MidCoast Lab: unattended install of $MGMT00_NAME. Generated by proxmox-setup.sh; deleted after the install. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <!-- VirtIO disk and network drivers from the VirtIO CD (its drive letter varies). -->
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\vioscsi\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\vioscsi\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\vioscsi\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>G:\vioscsi\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>D:\NetKVM\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\NetKVM\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>F:\NetKVM\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>G:\NetKVM\\$MGMT00_DRIVER_OS\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$MGMT00_IMAGE_INDEX</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><Organization>MidCoast Lab</Organization></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg.exe add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg.exe add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE /v DisablePrivacyExperience /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection /v AllowTelemetry /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo /v DisabledByGroupPolicy /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors /v DisableLocation /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>7</Order><Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice /v AllowFindMyDevice /t REG_DWORD /d 0 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>8</Order><Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization /v AllowInputPersonalization /t REG_DWORD /d 0 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>9</Order><Path>reg.exe add HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$MGMT00_NAME</ComputerName>
      <TimeZone>$MGMT00_TIME_ZONE</TimeZone>
      <RegisteredOrganization>MidCoast Lab</RegisteredOrganization>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$MGMT00_LOCAL_USER</Name>
            <DisplayName>$MGMT00_LOCAL_USER</DisplayName>
            <Group>Administrators</Group>
            <Password><Value>$PW_B64</Value><PlainText>false</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$MGMT00_LOCAL_USER</Username>
        <Password><Value>$PW_B64</Value><PlainText>false</PlainText></Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>MidCoast Lab first-logon setup from the answer CD</Description>
          <CommandLine>cmd.exe /c for %d in (D E F G H I) do @if exist %d:\setup-mgmt00.ps1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File %d:\setup-mgmt00.ps1</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XML
  # First-logon setup. Values go in a JSON file next to it, so the script itself is literal.
  # The one-time Tailscale key goes in too (the CD is root-only and shredded after
  # the install; the guest reads it from the CD and never copies it to disk).
  TS_KEY="$TS_KEY" python3 - "$WORK/mgmt00.json" <<PY
import json, os, sys
json.dump({"name": "$MGMT00_NAME", "user": "$MGMT00_LOCAL_USER", "ip": "$MGMT00_IP", "prefix": int("$MGMT00_PREFIX"),
           "gateway": "$MGMT00_GATEWAY", "dns": "$MGMT00_DNS",
           "rdp_from": [x for x in "$LAB_SUBNET ${RDP_FROM:-}".split() if x],
           "tailscale_authkey": os.environ.get("TS_KEY", "")}, open(sys.argv[1], "w"), indent=2)
PY
  unset TS_KEY
  cat > "$WORK/setup-mgmt00.ps1" <<'PS1'
# MidCoast Lab: first-logon setup of MGMT-00, run once by the answer file.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\MidCoastLab'
New-Item -ItemType Directory -Path $root -Force | Out-Null
Start-Transcript -Path (Join-Path $root 'mgmt00-setup.log') -Append | Out-Null
try {
    $cfg = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'mgmt00.json') | ConvertFrom-Json

    # VirtIO guest tools: remaining drivers, balloon service, QEMU guest agent.
    $tools = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'virtio-win-guest-tools.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($tools) {
        $p = Start-Process -FilePath $tools -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
        "VirtIO guest tools: exit $($p.ExitCode)"
    } else { Write-Warning 'virtio-win-guest-tools.exe not found on any drive.' }

    # Static address (NetKVM came with the install).
    $deadline = (Get-Date).AddMinutes(3)
    do { $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1; if (-not $nic) { Start-Sleep 5 } }
    until ($nic -or (Get-Date) -gt $deadline)
    if (-not $nic) { throw 'No network adapter came up.' }
    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $cfg.ip -PrefixLength $cfg.prefix -DefaultGateway $cfg.gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $cfg.dns
    "Address $($cfg.ip)/$($cfg.prefix), gateway $($cfg.gateway), DNS $($cfg.dns)"

    # The local admin account keeps its password (it's your way back in).
    Set-LocalUser -Name $cfg.user -PasswordNeverExpires $true

    # Remote Desktop, Network Level Authentication on, from the lab subnet (plus
    # site.yaml network.remote_desktop_from).
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
    Set-Service -Name TermService -StartupType Automatic
    Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -Direction Inbound | Where-Object { $_.Name -like 'RemoteDesktop-UserMode-In-*' } |
        Set-NetFirewallRule -RemoteAddress @($cfg.rdp_from) -Profile Any -Enabled True
    "Remote Desktop on, from $(@($cfg.rdp_from) -join ', ')"

    # Tailscale, with the one-time key from the answer CD (never copied to disk).
    # Same flags as every lab machine; the policy and watchdog come with the
    # reusable key in runbook step 6 (Join-LabTailnet.ps1).
    if ($cfg.tailscale_authkey) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
            Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi -UseBasicParsing
            $p = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart TS_UNATTENDEDMODE=always" -Wait -PassThru
            Remove-Item -Path $msi -Force -ErrorAction SilentlyContinue
            if ($p.ExitCode -notin 0, 3010) { throw "Tailscale installer exit $($p.ExitCode)" }
            $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
            $deadline = (Get-Date).AddMinutes(2)
            while (-not (Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
            Set-DnsClient -InterfaceAlias 'Tailscale' -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
            $out = & $exe up "--authkey=$($cfg.tailscale_authkey)" --unattended --accept-routes=false --accept-dns=false "--hostname=$($cfg.name.ToLower())" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "tailscale up exit $LASTEXITCODE`: $out" }
            New-NetFirewallRule -Name 'MidCoastLab-RDP-Tailscale' -DisplayName 'MidCoast Lab Remote Desktop (Tailscale adapter)' `
                -Direction Inbound -Protocol TCP -LocalPort 3389 -InterfaceAlias 'Tailscale' `
                -RemoteAddress '100.64.0.0/10', 'fd7a:115c:a1e0::/48' -Action Allow -Profile Any | Out-Null
            "Tailscale: joined as $($cfg.name.ToLower()); Remote Desktop allowed on the Tailscale adapter"
        } catch { Write-Warning "Tailscale skipped (join later with setup/mgmt/Join-LabTailnet.ps1): $($_.Exception.Message)" }
    }

    # The answer file's copies on disk carry the (encoded) password.
    Remove-Item -Path 'C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\Unattend\unattend.xml', 'C:\Windows\Panther\autounattend.xml' -Force -ErrorAction SilentlyContinue
    Set-Content -Path (Join-Path $root 'mgmt00-setup.done') -Value (Get-Date -Format o)
    'MGMT-00 first-logon setup complete; restarting'
} catch {
    "FAILED: $($_.Exception.Message)"
    throw
} finally { Stop-Transcript | Out-Null }
Restart-Computer -Force
PS1
  rm -f "$ISO_PATH"
  genisoimage -quiet -J -r -V MGMT00ANSWER -o "$ISO_PATH" "$WORK"
  chmod 600 "$ISO_PATH"
  # The work folder held the encoded password and (maybe) the Tailscale key.
  find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$WORK"
  ( umask 077; echo "$MGMT00_NAME local admin $MGMT00_LOCAL_USER : $LOCAL_PW" >> "$SECRETS_FILE" )
  unset LOCAL_PW PW_B64

  qm create "$MGMT00_VMID" \
    --name "$MGMT00_NAME" --pool "$POOL" --tags "$TAG;mgmt" \
    --ostype win11 --machine q35 --bios ovmf \
    --efidisk0 "$VM_STORAGE:1,efitype=4m,pre-enrolled-keys=1" \
    --tpmstate0 "$VM_STORAGE:1,version=v2.0" \
    --cpu x86-64-v2-AES --cores "$MGMT00_CORES" --memory "$MGMT00_MEMORY" --balloon "${MGMT00_MEMORY_MIN:-$MGMT00_MEMORY}" \
    --scsihw virtio-scsi-single --scsi0 "$VM_STORAGE:$MGMT00_DISK_GB,iothread=1,discard=on,ssd=1" \
    --net0 "virtio,bridge=$BRIDGE" \
    --ide2 "$MGMT00_ISO,media=cdrom" --ide0 "$VIRTIO_ISO,media=cdrom" --ide3 "$ISO_STORAGE:iso/$ANSWER_ISO,media=cdrom" \
    --agent enabled=1 --boot 'order=scsi0;ide2'
  echo "  created; starting the unattended install"
  qm start "$MGMT00_VMID"
  # The Windows ISO asks "Press any key to boot from CD or DVD" for a few seconds.
  for _ in $(seq 1 20); do sleep 1; qm sendkey "$MGMT00_VMID" ret >/dev/null 2>&1 || true; done
  MGMT00_STARTED=1
else
  echo "  CREATE_MGMT00=0: create it by hand (RUNBOOK.md): VMID $MGMT00_VMID, name $MGMT00_NAME, pool $POOL; then re-run this script to tag it."
fi

if [[ "${MGMT00_STARTED:-0}" == "1" ]]; then
  finish_mgmt00 || true
fi

cat <<EOF

Done. Next: RUNBOOK.md step 4 (sign in to $MGMT00_NAME). Initialize-LabVault.ps1 (step 6) asks
for both token secrets; they go in vault $VAULT_NAME as:
  $TOKEN_SECRET_NAMES

Granted on /pool/$POOL, the lab storages, /sdn/zones/localnetwork/$BRIDGE:
  ${PRIV_LIST//,/ }
Granted on /nodes/$NODE: PVEAuditor (read-only)
EOF
if [[ -f "$SECRETS_FILE" ]]; then
  echo
  echo "==> Secrets created by this run (shown here only; copy them now):"
  sed 's/^/  /' "$SECRETS_FILE"
  echo "  Put the token secrets in KeePass (RUNBOOK step 6) and $MGMT00_NAME's local password in"
  echo "  your own password manager, then delete the file:  shred -u $SECRETS_FILE"
fi
