import SwiftUI

struct AIAccountMenu: View {
    let auth: AIAuthController
    @State private var confirmingDeletion = false
    var body: some View {
        Group {
            if let email = auth.email {
                Menu {
                    Text(email)
                    Button("Sign out") { Task { await auth.signOut() } }
                    Button("Delete account…", role: .destructive) { confirmingDeletion = true }
                } label: { Text(email).lineLimit(1).truncationMode(.middle) }
                .menuStyle(.borderlessButton)
                .disabled(auth.isChangingAccount)
            } else {
                Button("Sign in") { auth.showingSignIn = true }
            }
        }
        .alert("Delete your Ask AI account?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) { Task { await auth.deleteAccount() } }
        } message: {
            Text("This permanently deletes your sign-in account. Your books, notes, and conversations on this Mac will remain.")
        }
        .alert("Account", isPresented: Binding(get: { auth.accountError != nil }, set: { if !$0 { auth.accountError = nil } })) {
            Button("OK") { auth.accountError = nil }
        } message: { Text(auth.accountError ?? "") }
    }
}
