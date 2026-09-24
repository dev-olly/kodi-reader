import SwiftUI

struct AISignInSheet: View {
    let auth: AIAuthController
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var busy = false
    @State private var error: String?
    @State private var resendAt = Date.distantPast
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to Ask AI").font(.title2)
            Text("Your books and notes stay on this Mac.")
                .foregroundStyle(.secondary)
            if !auth.isConfigured {
                Text(AIAuthError.notConfigured.localizedDescription)
            } else if let sentTo {
                Text("Enter the six-digit code sent to \(sentTo).")
                TextField("Verification code", text: $code)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .focused($codeFocused)
                    .onSubmit { verify() }
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    }
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(resendAt.timeIntervalSince(context.date))))
                        Button(remaining > 0 ? "Resend in \(remaining)s" : "Resend code") { send() }
                            .disabled(busy || remaining > 0)
                    }
                    Button("Change email") { self.sentTo = nil; code = ""; error = nil; resendAt = .distantPast }
                        .disabled(busy)
                }
            } else {
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if auth.isConfigured {
                    Button(sentTo == nil ? "Send code" : "Sign in") {
                        if sentTo == nil { send() } else { verify() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (sentTo == nil ? !validEmail : code.count != 6))
                }
            }
        }
        .padding(24)
        .frame(width: 390)
        .interactiveDismissDisabled(busy)
    }

    private var validEmail: Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("@") && !value.contains(where: \.isWhitespace)
    }

    private func send() {
        guard !busy, validEmail, Date() >= resendAt else { return }
        busy = true
        error = nil
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                try await auth.sendCode(to: address)
                sentTo = address
                code = ""
                resendAt = Date().addingTimeInterval(60)
                codeFocused = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func verify() {
        guard !busy, let sentTo, code.count == 6 else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await auth.verifyCode(code, email: sentTo)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
