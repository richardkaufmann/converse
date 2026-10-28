import SwiftUI

// Identical admission UI on Mac and iPad; cryptographic code remains tied to
// the joiner's existing Noise connection even when another member reviews.
struct ConverseGroupsView: View {
    @ObservedObject var service = DeviceSyncService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var host = ""
    @State private var port = "48721"
    @State private var confirmDissolve = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Converse Groups").font(.title2.bold())
            Text(service.currentGroup.map { "This device is in “" + $0.name + "”." } ?? "This device is not in a group.").font(.callout)
            Text("Group members can see sessions and control tools on their home devices under the existing logins. Any member can admit another device or dissolve the group.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let prompt = service.pairingPrompt {
                        GroupBox("Your join request") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask any member to open Converse Groups and press Review. Compare EVERY code group, then both press Pair.")
                                code(prompt.code)
                                if prompt.keyChanged || prompt.nameCollision { Text("Device identity or name differs from a remembered device. Verify carefully.").foregroundStyle(.orange) }
                                HStack { Button("Cancel request") { service.rejectPairing() }; Spacer(); Button("Pair") { service.confirmPairing() }.buttonStyle(.borderedProminent) }
                            }.padding(4)
                        }
                    }
                    if let review = service.groupReview {
                        GroupBox("Review “" + review.request.requesterName + "”") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Compare EVERY group below with the requesting device. Pair admits it to this group.")
                                code(review.code)
                                HStack { Button("Back") { service.groupReview = nil }; Spacer(); Button("Pair") { service.approveGroupReview() }.buttonStyle(.borderedProminent) }
                            }.padding(4)
                        }
                    }
                    ForEach(service.groupRequests) { request in
                        HStack {
                            VStack(alignment: .leading) { Text(request.requesterName).bold(); Text(request.approved ? "Approved; waiting for the requester’s Pair." : "Requests to join your group").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Review") { service.reviewGroupRequest(request) }.disabled(request.approved || request.expiresAt <= Date())
                        }
                    }
                    ForEach(service.availableGroups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(group.name).font(.headline); Spacer()
                                    if service.currentGroup?.id == group.id {
                                        Button("Leave") { service.leaveGroup() }
                                        Button("Dissolve", role: .destructive) { confirmDissolve = true }
                                    } else { Button("Join") { service.joinGroup(group) }.disabled(!service.canJoinGroup(group.id)) }
                                }
                                ForEach(service.groupDevices(group.id), id: \.self) { device in Text(device).font(.callout).padding(.leading, 16) }
                                if service.groupDevices(group.id).isEmpty { Text("No member currently discovered nearby.").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                    }
                    if service.availableGroups.isEmpty { Text("No groups available nearby. Create one here, then join it from your other devices.").foregroundStyle(.secondary) }
                    if creating {
                        HStack { TextField("Group name", text: $name).textFieldStyle(.roundedBorder); Button("Create") { service.createGroup(name: name); if service.currentGroup?.name == name.trimmingCharacters(in: .whitespacesAndNewlines) { creating = false; name = "" } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); Button("Cancel") { creating = false } }
                    } else { Button("Create Group") { creating = true } }
                    DisclosureGroup("Join by address (VPN)") {
                        HStack { TextField("Host or IP", text: $host).textFieldStyle(.roundedBorder); TextField("Port", text: $port).frame(width: 70).textFieldStyle(.roundedBorder); Button("Join") { service.joinGroupByAddress(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? -1) }.disabled(host.isEmpty) }
                        Text("Connect to a group member. The same Review and Pair checks apply.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(2)
            }
            if service.localNetworkDenied { Text("Local Network access is disabled. Enable it in system Settings to discover groups.").foregroundStyle(.orange) }
            Text(service.serviceStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !service.lastOutcome.isEmpty { Text(service.lastOutcome).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }.padding(20)
            .alert("Dissolve this group?", isPresented: $confirmDissolve) {
                Button("Cancel", role: .cancel) {}
                Button("Dissolve Group", role: .destructive) { service.dissolveGroup() }
            } message: { Text("Every device will leave the group. Sessions keep running on their home devices. Offline members learn this when they reconnect.") }
    }
    private func code(_ value: String) -> some View {
        Text(value).font(.system(size: 19, weight: .semibold, design: .monospaced)).textSelection(.enabled).padding(8).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}
