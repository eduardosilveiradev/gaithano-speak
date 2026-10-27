import SwiftUI
import SpeakCore

/// The stop before a sensitive action: exactly what is proposed, where it lands, and
/// three ways out.
///
/// It shows the call the gate is actually holding rather than a paraphrase of it —
/// the proxy is the approval boundary, and the user has to be judging the same thing
/// the proxy will execute if they say yes.
struct AgentApprovalPrompt: View {
    var request: AgentApprovalRequest
    /// Called with the user's choice. The panel does not resolve the request itself:
    /// the runtime owns the gate, and a decision that only ever reached the UI would
    /// leave the tool call hanging.
    var onDecision: (ApprovalDecision) -> Void

    private var call: AgentToolCall { request.call }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            action
            Text(request.reason)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            buttons
            allowAllWarning
            Text("esc cancels the whole request.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.yellow.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.yellow.opacity(0.55), lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text(request.category.summary)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            // An unrecognised tool reaches the gate because classification failed, not
            // because the action is known to be dangerous. Saying so stops the user
            // reading every unknown call as an attempted purchase.
            if request.category == .unknown {
                Text("unclassified")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.9))
            }
        }
    }

    /// The call itself. Arguments are listed in full rather than summarised: this is
    /// the one place the exact values decide the answer — which contact the message
    /// goes to, which door unlocks.
    private var action: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(call.server.displayName)
                    .foregroundStyle(.white.opacity(0.55))
                Text(call.tool)
                    .foregroundStyle(.white)
                if let target = call.target, !target.isEmpty {
                    Text("→ \(target)")
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            ForEach(AgentStepFormat.arguments(call.arguments, valueLimit: 160), id: \.key) { pair in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(pair.key)
                        .foregroundStyle(.white.opacity(0.4))
                    Text(pair.value)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10, design: .monospaced))
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.black.opacity(0.35))
        )
    }

    /// The keys are drawn on the buttons rather than bound to them.
    ///
    /// `.keyboardShortcut` only fires in a key window, and this panel deliberately
    /// never takes key focus — it floats over whatever the user is working in. `Y`,
    /// `N` and `A` are consumed by the event tap instead, which is also what makes
    /// them work when the pointer is nowhere near the panel.
    private var buttons: some View {
        HStack(spacing: 8) {
            button(title: "Allow", key: "Y", tint: .green) { onDecision(.allow) }
            button(title: "Deny", key: "N", tint: .white.opacity(0.75)) { onDecision(.deny) }
            button(title: "Allow all for this run", key: "A", tint: .orange) { onDecision(.allowAll) }
        }
    }

    /// Deliberately blunt, deliberately not collapsible, and deliberately naming the
    /// categories rather than saying "sensitive actions" — `A` is one keystroke away
    /// from `Y` on the way past, and the only difference the user gets to see is this
    /// paragraph. The last sentence matters too: the allowlist is fixed, so no
    /// approval can widen what the agent is able to do at all.
    private var allowAllWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text("Allow all runs every remaining action for this request without asking again — including purchases, deleting data, changing system settings, and unlocking or disarming security devices. It ends when this request ends and never carries into a follow-up. It can't grant file, shell, or scripting access.")
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func button(title: String, key: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.18)))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(tint.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Approval — purchase") {
    AgentApprovalPrompt(
        request: AgentApprovalRequest(
            id: "ap-1",
            call: AgentToolCall(id: "c-9", server: .chrome, tool: "browser_click",
                                target: "Place your order",
                                arguments: ["ref": "button#placeOrder", "total": "$148.20"]),
            category: .purchase,
            reason: "This completes a checkout on amazon.com for $148.20."),
        onDecision: { _ in })
    .padding(16)
    .frame(width: 420)
    .background(.black)
}

#Preview("Approval — unclassified") {
    AgentApprovalPrompt(
        request: AgentApprovalRequest(
            id: "ap-2",
            call: AgentToolCall(id: "c-10", server: .smartthings, tool: "device_command",
                                target: "Garage Door",
                                arguments: ["capability": "doorControl", "command": "open"]),
            category: .unknown,
            reason: "This tool isn't in the classifier's table, so it needs a decision before it runs."),
        onDecision: { _ in })
    .padding(16)
    .frame(width: 420)
    .background(.black)
}
#endif
