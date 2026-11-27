# Validation catalog: every validation ID, its severity and its recovery action.
#
# Severity  Critical = stop deployment, review rollback
#           High     = administrative review
#           Medium   = warning
#           Low      = informational
#
# Recovery actions. The orchestrator reports them with each failure; a person
# runs the matching pipeline command:
#   RebuildDC        replace this DC:   Invoke-LabDcRotation -Stage Add -Replace <name>, then -Stage Retire
#   Rebuild          replace this machine (DC: as RebuildDC; MGMT: Invoke-LabMgmtRotation -Stage Prepare)
#   RerunBootstrap   fix the cause, then re-run with -Retry
#                    (DC: Invoke-LabPhase -Retry or Invoke-LabDcRotation -Stage Add -Retry;
#                     MGMT: Invoke-LabMgmtRotation -Stage Prepare -Retry)
#   Review           a person decides
@{
    # ── Network / identity ─────────────────────────────────────────────
    'NET-001'    = @{ Name = 'Static IPv4 matches inventory';        Category = 'Network';     Severity = 'High';     Recovery = 'RerunBootstrap' }
    'NET-002'    = @{ Name = 'Computer name matches inventory';      Category = 'Network';     Severity = 'Critical'; Recovery = 'Rebuild' }

    # ── Directory services ─────────────────────────────────────────────
    'AD-001'     = @{ Name = 'Directory services running';           Category = 'ActiveDirectory'; Severity = 'Critical'; Recovery = 'RebuildDC' }
    'AD-002'     = @{ Name = 'DC is a global catalog';               Category = 'ActiveDirectory'; Severity = 'High';     Recovery = 'Review' }
    'AD-003'     = @{ Name = 'dcdiag core tests pass';               Category = 'ActiveDirectory'; Severity = 'High';     Recovery = 'Review' }

    # ── DNS ────────────────────────────────────────────────────────────
    'DNS-001'    = @{ Name = 'DNS server answers for the domain';    Category = 'DNS'; Severity = 'Critical'; Recovery = 'RebuildDC' }
    'DNS-002'    = @{ Name = 'DC locator SRV record registered';     Category = 'DNS'; Severity = 'Critical'; Recovery = 'RerunBootstrap' }
    'DNS-003'    = @{ Name = 'Forwarders resolve external names';    Category = 'DNS'; Severity = 'Medium';   Recovery = 'Review' }
    'DNS-004'    = @{ Name = 'DNS client order (partners, loopback last)'; Category = 'DNS'; Severity = 'Medium'; Recovery = 'RerunBootstrap' }

    # ── SYSVOL ─────────────────────────────────────────────────────────
    'SYSVOL-001' = @{ Name = 'SYSVOL and NETLOGON shared';           Category = 'SYSVOL'; Severity = 'Critical'; Recovery = 'RebuildDC' }
    'SYSVOL-002' = @{ Name = 'SYSVOL DFSR state is Normal';          Category = 'SYSVOL'; Severity = 'Critical'; Recovery = 'RebuildDC' }

    # ── FSMO ───────────────────────────────────────────────────────────
    'FSMO-001'   = @{ Name = 'All FSMO holders reachable';           Category = 'FSMO'; Severity = 'Critical'; Recovery = 'Review' }

    # ── Replication ────────────────────────────────────────────────────
    'REPL-001'   = @{ Name = 'No replication failures';              Category = 'Replication'; Severity = 'Critical'; Recovery = 'RebuildDC' }
    'REPL-002'   = @{ Name = 'Inbound replication within 3 hours'; Category = 'Replication'; Severity = 'High';    Recovery = 'Review' }

    # ── Time ───────────────────────────────────────────────────────────
    'TIME-001'   = @{ Name = 'Time source configured';               Category = 'Time'; Severity = 'Medium'; Recovery = 'RerunBootstrap' }

    # ── LAPS ───────────────────────────────────────────────────────────
    'LAPS-001'   = @{ Name = 'Windows LAPS schema present';          Category = 'LAPS'; Severity = 'High';   Recovery = 'RerunBootstrap' }
    'LAPS-002'   = @{ Name = 'LAPS policies configured and linked';                 Category = 'LAPS'; Severity = 'Medium'; Recovery = 'RerunBootstrap' }

    # ── Remote Desktop ─────────────────────────────────────────────────
    'RDP-001'    = @{ Name = 'Remote Desktop on, listening, open to the lab subnet'; Category = 'RemoteDesktop'; Severity = 'High'; Recovery = 'RerunBootstrap' }

    # ── Tailscale (site.yaml tailscale.enabled; per role, lab.yaml) ──
    # TS-001 passes on a role that doesn't join (1.8: every role but MGMT).
    # DNS-005 stays for DCs built before 1.8, which have Tailscale.
    'TS-001'     = @{ Name = 'Joined to the tailnet and connected';  Category = 'Tailscale'; Severity = 'Medium'; Recovery = 'Review' }
    'DNS-005'    = @{ Name = "No Tailscale address in AD's DNS";     Category = 'DNS'; Severity = 'High'; Recovery = 'Review' }

    # ── MGMT ───────────────────────────────────────────────────────────
    'MGMT-001'   = @{ Name = 'Toolchain installed (pwsh, git, terraform, packer, code, keepassxc, oscdimg)'; Category = 'MGMT'; Severity = 'Critical'; Recovery = 'RerunBootstrap' }
    'MGMT-002'   = @{ Name = 'RSAT (AD, DNS, Group Policy) installed';  Category = 'MGMT'; Severity = 'High';     Recovery = 'RerunBootstrap' }
    'MGMT-003'   = @{ Name = 'PowerShell modules (yaml, SecretManagement, KeePass)'; Category = 'MGMT'; Severity = 'Critical'; Recovery = 'RerunBootstrap' }
    'MGMT-004'   = @{ Name = 'Joined to the domain, secure channel healthy'; Category = 'MGMT'; Severity = 'Critical'; Recovery = 'RerunBootstrap' }
    'MGMT-005'   = @{ Name = 'WinRM/HTTPS reaches the DCs (two of the three DC slots)'; Category = 'MGMT'; Severity = 'Critical'; Recovery = 'Review' }
    'MGMT-006'   = @{ Name = 'Proxmox API reachable';                  Category = 'MGMT'; Severity = 'Critical'; Recovery = 'Review' }
    'MGMT-007'   = @{ Name = 'Remote Desktop on, listening, open to the lab subnet'; Category = 'MGMT'; Severity = 'Critical'; Recovery = 'RerunBootstrap' }

    # ── Memory ─────────────────────────────────────────────────────────
    'MEM-001'    = @{ Name = 'Balloon service running (Proxmox can reclaim memory)'; Category = 'Memory'; Severity = 'Low'; Recovery = 'Review' }

    # ── Lifecycle ──────────────────────────────────────────────────────
    'EVAL-001'   = @{ Name = 'Evaluation period has more than 30 days left'; Category = 'Lifecycle'; Severity = 'Medium'; Recovery = 'Rebuild' }
}
