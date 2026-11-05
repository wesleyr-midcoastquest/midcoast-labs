# Replacing a DC

Windows Server 2022 evaluation editions last 180 days, so each DC is replaced well before
then (each validation report's `EVAL-001` shows the days left), one DC at a time. Replacing
a DC is also how a DC picks up a newer template, and how a broken DC is fixed: the lab
replaces, never repairs.

The replacement is a new DC from the current WIN2022-TEMPLATE version. The forest stays; only the machines change. Run from the active MGMT, in an **elevated**
PowerShell 7 window (the script also points this machine's DNS at the new set of DCs).

**Safety net (optional):** snapshot **both** DCs first, on the node as root
(`qm snapshot <vmid> pre-rotation` for each). On LVM-thin or ZFS a snapshot lives in the
VM's own storage and only stores changes, so it costs little. If you ever revert, revert
both DCs together: reverting one DC alone puts it behind its partner. Delete the snapshots
(`qm delsnapshot <vmid> pre-rotation`) once Retire is done; the retired DC's goes with its VM.

```powershell
./orchestration/Invoke-LabDcRotation.ps1 -Stage Add      # optional: -Replace <DC name>; default the oldest
git add inventory/instances.yaml; git commit -m "DC rotation: add"; git push
# ...check anything you like...
./orchestration/Invoke-LabDcRotation.ps1 -Stage Retire
git add inventory/instances.yaml; git commit -m "DC rotation: retire"; git push
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
