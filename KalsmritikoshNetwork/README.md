# KalsmritikoshNetwork — the network helper (O-2)

Online mode's only network process. The main app keeps **no** network entitlement; this
XPC service, bundled inside the app, sends an HTTPS POST to one of three hosts
(`api.anthropic.com`, `api.openai.com`, `generativelanguage.googleapis.com`) and returns
the reply. Private mode never launches it.

## Owner steps in Xcode (the agent cannot edit the project file)

1. **File ▸ New ▸ Target… ▸ macOS ▸ XPC Service.** Product name `KalsmritikoshNetwork`,
   bundle identifier `ecosanskritiinnovation.Kalsmritikosh.KalsmritikoshNetwork`
   (must equal `NetworkHelperClient.serviceName`), language Swift. Embed in: Kalsmritikosh.
2. Delete the template's generated source files, then add to the new target:
   - `KalsmritikoshNetwork/main.swift`
   - `Kalsmritikosh/Routing/Providers/Online/NetworkHelperClient.swift` (for the shared
     `KalsmritikoshNetworkProtocol`) — target membership: **both** Kalsmritikosh and
     KalsmritikoshNetwork
   - `Kalsmritikosh/Routing/Providers/Online/OnlineProviderKind.swift` (for the shared
     request/response types) — target membership: **both**
3. Signing & Capabilities for the helper target: set **Code Signing Entitlements** to
   `KalsmritikoshNetwork/KalsmritikoshNetwork.entitlements` (App Sandbox + Outgoing
   Connections only). Leave the **main app** target exactly as it is: no network.
4. Set the helper's deployment target to **macOS 15.6** (the release guard requires it).
5. Build. The app finds the helper at `Contents/XPCServices/KalsmritikoshNetwork.xpc`,
   and `ConnectivityMode.onlineAvailableInThisBuild` becomes true automatically.

`NetworkHelperClient.swift` references `ConnectivityMode` and `OnlineProviderKind`; if the
helper target complains about `ConnectivityMode`, add `Kalsmritikosh/App/Modules/ConnectivityMode.swift`
to the helper target as well, or move the protocol into its own file.

## What the helper will never do

Store anything, read files, accept another host, use plain HTTP, or listen for incoming
connections (`network.server` is rejected by CI).
