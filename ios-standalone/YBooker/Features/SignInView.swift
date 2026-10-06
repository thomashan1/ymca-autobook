import SwiftUI

struct SignInView: View {
    @Binding var signedIn: Bool
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("YMCA (egym) login")
                } footer: {
                    Text("Stored only in this device's Keychain. Never sent anywhere but egym and the YMCA.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign in")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Y Booker")
        }
    }

    private func signIn() async {
        busy = true
        error = nil
        do {
            _ = try await FisikalClient.shared.signIn(username: email, password: password)
            signedIn = true
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
