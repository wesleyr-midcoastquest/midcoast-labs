# Lab.Entra: Entra synchronization functions (Phase 3).
# Phase 1 ships only the connectivity check; the Entra Connect install,
# connector health and sync validation arrive with the ADES role.

function Test-LabEntraConnectivity {
    [CmdletBinding()]
    param()
    # Endpoints Entra Connect Sync needs outbound on 443.
    $endpoints = 'login.microsoftonline.com', 'adminwebservice.microsoftonline.com', 'graph.microsoft.com'
    foreach ($e in $endpoints) {
        $r = Test-NetConnection -ComputerName $e -Port 443 -WarningAction SilentlyContinue
        [pscustomobject]@{ Endpoint = $e; Reachable = [bool] $r.TcpTestSucceeded }
    }
}

Export-ModuleMember -Function Test-LabEntraConnectivity
