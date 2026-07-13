@preconcurrency import Contacts
@preconcurrency import ContactsUI
import SwiftUI

struct ContactSelection: Sendable {
    let name: String
    let number: String
}

struct ContactPickerView: UIViewControllerRepresentable {
    let onSelect: (ContactSelection) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == %@", CNContactPhoneNumbersKey)
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, @preconcurrency CNContactPickerDelegate {
        let parent: ContactPickerView
        init(parent: ContactPickerView) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            guard contactProperty.key == CNContactPhoneNumbersKey,
                  let phone = contactProperty.value as? CNPhoneNumber else { return }
            let contact = contactProperty.contact
            let personal = [contact.givenName, contact.middleName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let name = personal.isEmpty ? contact.organizationName : personal
            parent.onSelect(ContactSelection(name: name, number: phone.stringValue))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}
