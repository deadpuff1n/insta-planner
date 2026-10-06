import SwiftUI
import SwiftData

@main
struct FeedPlannerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(for: [Account.self, FeedPost.self])
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage("selectedAccount") private var selectedID = ""
    @State private var showAdd = false

    private var current: Account? {
        accounts.first { $0.id.uuidString == selectedID } ?? accounts.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let account = current {
                    FeedGridView(account: account).id(account.id)
                } else {
                    ContentUnavailableView {
                        Label("Нет профилей", systemImage: "person.crop.square")
                    } description: {
                        Text("Добавь Instagram-аккаунт, чтобы увидеть ленту")
                    } actions: {
                        Button("Добавить профиль") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(current.map { "@\($0.username)" } ?? "Лента")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(accounts) { a in
                            Button {
                                selectedID = a.id.uuidString
                            } label: {
                                Label("@\(a.username)", systemImage: a.id == current?.id ? "checkmark" : "person")
                            }
                        }
                        Divider()
                        Button("Добавить профиль", systemImage: "plus") { showAdd = true }
                        if let c = current {
                            Button("Удалить @\(c.username)", systemImage: "trash", role: .destructive) { remove(c) }
                        }
                    } label: { Image(systemName: "person.2") }
                }
            }
            .sheet(isPresented: $showAdd) { AddAccountView { selectedID = $0.id.uuidString } }
        }
    }

    private func remove(_ a: Account) {
        a.posts.forEach { ImageStore.delete($0.imageFile) }
        Keychain.delete(a.id.uuidString)
        context.delete(a)
    }
}

struct AddAccountView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    var onAdded: (Account) -> Void

    @State private var username = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Никнейм", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Добавить профиль") { addAccount() }
                        .disabled(cleanName.isEmpty)
                } footer: {
                    Text("Вход в Instagram не нужен. Приложение попробует загрузить публикации из открытого профиля по никнейму.")
                }
            }
            .navigationTitle("Новый профиль")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }

    private var cleanName: String {
        username.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "").lowercased()
    }

    private func addAccount() {
        let acc: Account
        if let existing = accounts.first(where: { $0.username == cleanName }) {
            acc = existing
        } else {
            acc = Account(title: cleanName, username: cleanName)
            context.insert(acc)
        }
        onAdded(acc)
        dismiss()
    }
}
