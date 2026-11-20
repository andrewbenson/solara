import SwiftUI

enum AutofillAddressField: String, CaseIterable, Identifiable {
  case name
  case organization
  case line1
  case line2
  case city
  case state
  case postalCode
  case country
  case phone
  case email

  var id: String { rawValue }

  var title: String {
    switch self {
    case .name: "Name"
    case .organization: "Organization"
    case .line1: "Street Address"
    case .line2: "Apt, Suite, etc."
    case .city: "City"
    case .state: "State / Province"
    case .postalCode: "ZIP / Postal Code"
    case .country: "Country / Region"
    case .phone: "Phone"
    case .email: "Email"
    }
  }

  static func values(for saved: SavedAddress?) -> [AutofillAddressField: String] {
    let lines = (saved?.street ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return [
      .name: saved?.name ?? "",
      .organization: saved?.organization ?? "",
      .line1: lines.first ?? "",
      .line2: lines.dropFirst().joined(separator: ", "),
      .city: saved?.city ?? "",
      .state: saved?.state ?? "",
      .postalCode: saved?.postalCode ?? "",
      .country: saved?.country ?? "",
      .phone: saved?.phone ?? "",
      .email: saved?.email ?? "",
    ]
  }

  static func isEmpty(_ values: [AutofillAddressField: String]) -> Bool {
    values.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  static func input(_ values: [AutofillAddressField: String], id: String?) -> AddressInput {
    let street = [values[.line1] ?? "", values[.line2] ?? ""]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    return AddressInput(
      id: id,
      name: values[.name] ?? "",
      organization: values[.organization] ?? "",
      street: street,
      city: values[.city] ?? "",
      state: values[.state] ?? "",
      postalCode: values[.postalCode] ?? "",
      country: values[.country] ?? "",
      phone: values[.phone] ?? "",
      email: values[.email] ?? ""
    )
  }
}

struct AutofillSheetButtons: View {
  @Environment(\.dismiss) private var dismiss
  let canDelete: Bool
  let saveDisabled: Bool
  let onDelete: () -> Void
  let onSave: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if canDelete {
        Button("Delete", role: .destructive, action: onDelete)
          .foregroundStyle(.red)
      }
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save", action: onSave)
        .keyboardShortcut(.defaultAction)
        .disabled(saveDisabled)
    }
    .padding(.top, 18)
  }
}

struct AutofillAddressSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: AutofillPaneModel
  let profile: String
  let saved: SavedAddress?
  @State private var values: [AutofillAddressField: String]
  @State private var confirmingDelete = false
  @FocusState private var focused: AutofillAddressField?

  init(model: AutofillPaneModel, profile: String, saved: SavedAddress?) {
    self.model = model
    self.profile = profile
    self.saved = saved
    _values = State(initialValue: AutofillAddressField.values(for: saved))
  }

  var body: some View {
    let empty = AutofillAddressField.isEmpty(values)
    VStack(alignment: .leading, spacing: 0) {
      Text(saved == nil ? "Add Address" : "Edit Address")
        .font(.system(size: 15, weight: .semibold))
      PasswordsSheetGroup {
        ForEach(Array(AutofillAddressField.allCases.enumerated()), id: \.element) { index, field in
          if index > 0 { Divider() }
          PasswordsSheetRow(title: field.title) {
            TextField("", text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }))
              .textContentType(.solaraPlainText)
              .textFieldStyle(.roundedBorder)
              .frame(width: 250)
              .focused($focused, equals: field)
              .onSubmit { if !AutofillAddressField.isEmpty(values) { Task { await save() } } }
          }
        }
      }
      .padding(.top, 14)
      AutofillSheetButtons(canDelete: saved != nil, saveDisabled: empty, onDelete: { confirmingDelete = true }, onSave: { Task { await save() } })
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { if saved == nil { focused = .name } }
    .alert("Delete this address?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) { Task { await remove() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It won't be offered in forms anymore.")
    }
  }

  private func save() async {
    _ = await model.services.saveAddress(AutofillAddressField.input(values, id: saved?.id), profile: profile)
    await model.reload(profile)
    dismiss()
  }

  private func remove() async {
    guard let saved else { return }
    await model.services.deleteAutofillEntry(saved.id, profile: profile)
    await model.reload(profile)
    dismiss()
  }
}

struct AutofillCardSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: AutofillPaneModel
  let profile: String
  let saved: SavedCard?
  @State private var number: String?
  @State private var name: String
  @State private var month: String
  @State private var year: String
  @State private var error = ""
  @State private var confirmingDelete = false
  @FocusState private var numberFocused: Bool

  init(model: AutofillPaneModel, profile: String, saved: SavedCard?, number: String? = nil) {
    self.model = model
    self.profile = profile
    self.saved = saved
    _number = State(initialValue: saved == nil ? (number ?? "") : number)
    _name = State(initialValue: saved?.name ?? "")
    _month = State(initialValue: saved?.expMonth.flatMap { $0 == 0 ? nil : String($0) } ?? "")
    _year = State(initialValue: saved?.expYear.flatMap { $0 == 0 ? nil : String($0) } ?? "")
  }

  var body: some View {
    let digits = AutofillText.digits(number ?? "")
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        if let saved { AutofillNetworkBadge(network: saved.network) }
        Text(saved?.title ?? "Add Card")
          .font(.system(size: 15, weight: .semibold))
      }
      PasswordsSheetGroup {
        PasswordsSheetRow(title: "Card Number") {
          if let number {
            HStack(spacing: 4) {
              TextField("1234 5678 9012 3456", text: Binding(get: { number }, set: { typed in
                error = ""
                self.number = AutofillText.formatCardNumber(String(AutofillText.digits(typed).prefix(19)))
              }))
              .textContentType(.solaraPlainText)
              .textFieldStyle(.roundedBorder)
              .frame(width: saved == nil ? 250 : 222)
              .focused($numberFocused)
              if saved != nil {
                PasswordsIconButton(icon: "doc.on.doc", tooltip: "Copy Card Number") { model.services.copy(digits) }
              }
            }
          } else {
            HStack(spacing: 4) {
              Text("•••• •••• •••• \(saved?.last4 ?? "")")
              PasswordsIconButton(icon: "eye", tooltip: "Show Card Number") { Task { await reveal() } }
            }
          }
        }
        Divider()
        PasswordsSheetRow(title: "Name on Card") {
          TextField("", text: $name)
            .textFieldStyle(.roundedBorder)
            .frame(width: 250)
            .textContentType(.solaraPlainText)
        }
        Divider()
        PasswordsSheetRow(title: "Expiration Date") {
          HStack(spacing: 6) {
            SettingPicker(AutofillText.monthOptions, selection: $month)
              .frame(minWidth: 90)
            SettingPicker(AutofillText.yearOptions(current: saved?.expYear, now: model.now()), selection: $year)
              .frame(minWidth: 90)
          }
        }
      }
      .padding(.top, 14)
      if !error.isEmpty {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(Color(red: 1, green: 69 / 255, blue: 58 / 255))
          .padding(.top, 10)
      }
      AutofillSheetButtons(
        canDelete: saved != nil,
        saveDisabled: number != nil && digits.count < 12,
        onDelete: { confirmingDelete = true },
        onSave: { Task { await save() } }
      )
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { if saved == nil { numberFocused = true } }
    .onDisappear { number = nil }
    .alert("Delete this card?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) { Task { await remove() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Its number is removed from your Keychain too.")
    }
  }

  private func reveal() async {
    guard let saved else { return }
    if let full = await model.services.revealCardNumber(saved.id, profile: profile) {
      number = AutofillText.formatCardNumber(full)
    }
  }

  private func save() async {
    let card = CardInput(
      id: saved?.id,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      expMonth: month.isEmpty ? nil : Int(month),
      expYear: year.isEmpty ? nil : Int(year)
    )
    let digits = number.map(AutofillText.digits)
    guard await model.services.saveCard(card, number: digits, profile: profile) != nil else {
      error = "That isn't a valid card number."
      return
    }
    await model.reload(profile)
    dismiss()
  }

  private func remove() async {
    guard let saved else { return }
    await model.services.deleteAutofillEntry(saved.id, profile: profile)
    await model.reload(profile)
    dismiss()
  }
}
