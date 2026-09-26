import ReaderUI
import SwiftUI
import AuthenticationServices

struct AISignInSheet: View {
    let auth: AIAuthController
    var onboarding = false
    var onComplete: (() -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choosingEmail = false
    @State private var email = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var busy = false
    @State private var error: String?
    @State private var resendAt = Date.distantPast
    @FocusState private var codeFocused: Bool

    var body: some View {
        Group {
            if onboarding {
                GeometryReader { geometry in
                    ScrollView {
                        form
                            .frame(maxWidth: 380)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 48)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                }
                .background(model.settings.theme.surface)
            } else {
                form.padding(32).frame(width: 420)
            }
        }
        .foregroundStyle(model.settings.theme.uiForeground)
        .tint(model.settings.theme.accent)
        .interactiveDismissDisabled(busy)
    }

    private var form: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image("KodiLogo")
                    .resizable().scaledToFit().frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text(onboarding ? "Welcome to Kodi Reader" : "Sign in to Kodi Reader")
                    .font(.system(size: onboarding ? 32 : 28, weight: .regular, design: .serif))
                    .multilineTextAlignment(.center)
                Text("Your books. Your thoughts.")
                    .font(.system(size: 16))
                    .foregroundStyle(model.settings.theme.muted)
            }
            VStack(spacing: 12) {
                if !choosingEmail {
                    Button {
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do { try await auth.signInWithGoogle(); complete() }
                            catch ASWebAuthenticationSessionError.canceledLogin { }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        providerLabel("Continue with Google") {
                            Image("GoogleLogo")
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                        }
                    }
                    .buttonStyle(AuthOptionStyle(theme: model.settings.theme))
                    .disabled(busy || !auth.isConfigured || !auth.googleEnabled)
                    .help(auth.googleEnabled ? "Sign in with Google" : "Google sign-in will be available once configured")

                    Button {
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do { try await auth.signInWithApple(); complete() }
                            catch ASWebAuthenticationSessionError.canceledLogin { }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        providerLabel("Continue with Apple") {
                            Image(systemName: "apple.logo")
                        }
                    }
                    .buttonStyle(AuthOptionStyle(theme: model.settings.theme, apple: true))
                    .disabled(busy || !auth.isConfigured || !auth.appleEnabled)
                    .help(auth.appleEnabled ? "Sign in with Apple" : "Apple sign-in will be available once configured")

                    HStack(spacing: 12) {
                        Rectangle().fill(model.settings.theme.border).frame(height: 1)
                        Text("or").font(.caption).foregroundStyle(model.settings.theme.muted)
                        Rectangle().fill(model.settings.theme.border).frame(height: 1)
                    }.padding(.vertical, 4)
                    Button { choosingEmail = true; error = nil } label: {
                        providerLabel("Continue with email") {
                            Image(systemName: "envelope")
                        }
                    }
                    .buttonStyle(AuthOptionStyle(theme: model.settings.theme))
                    .disabled(busy || !auth.isConfigured)
                } else {
                    emailForm
                }
                if !auth.isConfigured {
                    Text("Sign-in is unavailable in this build. You can still continue reading.")
                        .font(.callout).foregroundStyle(model.settings.theme.muted)
                        .multilineTextAlignment(.center)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                        .multilineTextAlignment(.center).accessibilityLabel("Sign-in error: \(error)")
                }
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Signing in") }
            }
            Text("Sign in to use Ask AI.\nYour books and notes stay on this Mac.")
                .font(.system(size: 12)).foregroundStyle(model.settings.theme.muted)
                .multilineTextAlignment(.center).lineSpacing(4)
            Button(onboarding ? "Skip for now" : "Cancel") { complete() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(model.settings.theme.muted)
                .padding(.vertical, 8)
                .disabled(busy)
        }
    }

    private func providerLabel<Icon: View>(_ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            icon().font(.system(size: 18)).frame(width: 22).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 48)
    }

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { choosingEmail = false; error = nil } label: {
                Label("All sign-in options", systemImage: "arrow.left")
            }.buttonStyle(.plain).foregroundStyle(model.settings.theme.muted).disabled(busy)
            if let sentTo {
                Text("Enter the six-digit code sent to \(sentTo).")
                    .font(.callout).foregroundStyle(model.settings.theme.muted)
                TextField("Verification code", text: $code)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .focused($codeFocused).onSubmit { verify() }
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    }
                    .disabled(busy)
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(resendAt.timeIntervalSince(context.date))))
                        Button(remaining > 0 ? "Resend in \(remaining)s" : "Resend code") { send() }
                            .disabled(busy || remaining > 0)
                    }
                    Spacer()
                    Button("Change email") { self.sentTo = nil; code = ""; error = nil; resendAt = .distantPast }
                        .disabled(busy)
                }.font(.caption).buttonStyle(.plain)
            } else {
                Text("Continue with email").font(.system(size: 18, weight: .medium))
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit { send() }.disabled(busy)
            }
            Button { if sentTo == nil { send() } else { verify() } } label: {
                Text(sentTo == nil ? "Send code" : "Sign in")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || (sentTo == nil ? !validEmail : code.count != 6))
        }
    }

    private func complete() {
        if let onComplete { onComplete() } else { dismiss() }
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
                complete()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct AuthOptionStyle: ButtonStyle {
    let theme: ReaderTheme
    var apple = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(apple ? (theme.isDark ? Color.black : Color.white) : theme.uiForeground)
            .background(apple ? (theme.isDark ? Color.white : Color.black) : theme.uiBackground,
                        in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .contentShape(.rect(cornerRadius: 8))
    }
}
